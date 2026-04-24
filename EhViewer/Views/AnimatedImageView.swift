import SwiftUI

#if canImport(UIKit)
import UIKit

/// 通常モード補正設定スナップショット。per-frame enhance の入力一式。
/// 静画 applyFilterPipeline と同じ排他: enhanceFilter ON 時は HDR 抑止。
/// ファイルスコープ struct (AnimatedSourceImageView の外) にすることで Equatable 適合が
/// nonisolated になり、background queue 内 `!=` 比較が Swift 6 下でも合法になる。
fileprivate struct AnimEnhanceConfig: Hashable {
    let enhanceFilter: Bool
    let denoise: Bool
    let hdr: Bool
    /// NE 人物セグメンテーション。`animatedPersonSegmentation` UserDefaults (default true) で制御。
    /// 「通常モードの NE 人物シャープ化をアニメにも当てる」= 田中本命機能。Vision framework が NE 経路で
    /// マスク生成 → 人物領域のみシャープ+彩度ブースト。静画 applyPersonSegmentation とは異なり
    /// 背景側を触らない (per-frame では denoise / enhanceFilter 段に任せる)。
    let personSeg: Bool
    var hasAny: Bool { enhanceFilter || denoise || hdr || personSeg }
    static func fromDefaults() -> AnimEnhanceConfig {
        let enh = UserDefaults.standard.bool(forKey: "imageEnhanceFilter")
        let den = UserDefaults.standard.bool(forKey: "denoiseEnabled")
        let hdrRaw = UserDefaults.standard.bool(forKey: "hdrEnhancement")
        let seg = UserDefaults.standard.bool(forKey: "animatedPersonSegmentation")
        return AnimEnhanceConfig(enhanceFilter: enh, denoise: den, hdr: hdrRaw && !enh, personSeg: seg)
    }
}

/// アニメ画像表示用 UIImageView (CADisplayLink 駆動)。
/// UIImage.animatedImage(with:duration:) は 200+ frame で内部 pre-decode が
/// 実質ハングするため採用せず。CADisplayLink で経過時間 → frame index を算出し
/// source.frame(at:) を逐次呼び出す。frame cache は AnimatedImageSource が保持。
final class AnimatedSourceImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    private var animSource: AnimatedImageSource?
    private var currentSourceID: ObjectIdentifier?
    private var isActive: Bool = false

    private var displayLink: CADisplayLink?
    private var linkStartTime: CFTimeInterval = 0
    private var lastDisplayedIdx: Int = -1

    /// 設定
    private var currentMaxDim: CGFloat = 0

    /// 現在 enhancedCache に入っている結果の設定。live config と不一致なら flush + 再 enhance。
    /// 定義は ファイル先頭の AnimEnhanceConfig 参照 (Swift 6 nonisolated 適合のため外出し)。
    private var currentConfig: AnimEnhanceConfig = AnimEnhanceConfig(enhanceFilter: false, denoise: false, hdr: false, personSeg: false)
    /// 補正適用済み CGImage キャッシュ (key = frame index)。
    /// currentConfig の組み合わせで enhance 結果を保持し、HDREnhancer / enhanceFilterCG の
    /// GPU roundtrip を 1 frame 1 回に抑える。設定変化時は flush。
    private var enhancedCache: [Int: CGImage] = [:]
    private let enhancedCacheLock = NSLock()
    private var enhanceInflight: Set<Int> = []
    /// ソース単位のグレースケール判定 (setSource 時 1 回のみ算出)。per-frame コスト回避。
    private var sourceIsGrayscale: Bool = false

    func setSource(_ source: AnimatedImageSource, isActive: Bool) {
        let sid = ObjectIdentifier(source)
        let sourceChanged = currentSourceID != sid

        if !sourceChanged {
            // source 同じ: play/pause のみ切替
            if self.isActive != isActive {
                self.isActive = isActive
                if isActive { startLink() } else { stopLink() }
            }
            return
        }

        // source 変更: リセット
        stopLink()
        self.animSource = source
        self.currentSourceID = sid
        self.isActive = isActive
        self.lastDisplayedIdx = -1
        enhancedCacheLock.lock()
        enhancedCache.removeAll(keepingCapacity: false)
        enhanceInflight.removeAll(keepingCapacity: false)
        enhancedCacheLock.unlock()

        let maxDim = computeMaxPixelSize()
        currentMaxDim = maxDim

        // Boomerang / 通常モード補正 (enhanceFilter / HDR) は tick / rolling prefetch 時に
        // ライブで UserDefaults を読むため、ここでは初回 first frame SYNC 用にのみスナップ。
        currentConfig = AnimEnhanceConfig.fromDefaults()

        LogManager.shared.log("Anim", "setSource frames=\(source.frameCount) active=\(isActive) dur=\(String(format: "%.2f", source.totalDuration))s maxDim=\(Int(maxDim)) config=\(currentConfig)")

        // first frame SYNC (黒画面回避)
        let t0 = CFAbsoluteTimeGetCurrent()
        if let first = source.frame(at: 0, maxPixelSize: maxDim) {
            // sourceIsGrayscale: enhanceFilter の isGrayscale パラメータ用。1 回だけ算出。
            sourceIsGrayscale = LanczosUpscaler.shared.isGrayscaleImage(first)
            let display = Self.applyEnhance(first, config: currentConfig, isGrayscale: sourceIsGrayscale) ?? first
            self.image = UIImage(cgImage: display)
            if currentConfig.hasAny {
                enhancedCacheLock.lock()
                enhancedCache[0] = display
                enhancedCacheLock.unlock()
            }
            lastDisplayedIdx = 0
            LogManager.shared.log("Anim", "first frame SYNC (decode=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms size=\(first.width)x\(first.height) gray=\(sourceIsGrayscale))")
        } else {
            LogManager.shared.log("Anim", "first frame decode FAILED")
        }

        // 全フレーム同時 prefetch は 217 × 6.5MB = 1.4GB メモリ爆発するため廃止。
        // ローリング窓: 現在位置の前方 30 frame のみ decode、後方 5 frame 超は evict。
        // これで同時保持は ~35 frame (~230MB) に抑制、decode 速度にも引きずられず常時滑らかに再生。
        startRollingPrefetch()

        if isActive { startLink() }
    }

    /// ローリング prefetch
    private var rollingTimer: DispatchSourceTimer?
    private static let rollingAheadFrames: Int = 30
    private static let rollingBehindKeep: Int = 5

    /// iPhone 限定: thermalState に応じて rolling 前方フレーム数を動的降格 (案 C)。
    /// - .nominal / .fair (low-mid): 30 frame
    /// - .fair (高負荷気味): 20 frame
    /// - .serious: 15 frame
    /// - .critical: AnimatedPlaybackCoordinator.stopAll 経由で停止
    /// Mac Catalyst は常に 30 frame (熱対策不要)。
    private var currentRollingAhead: Int {
        #if targetEnvironment(macCatalyst)
        return Self.rollingAheadFrames
        #else
        switch ProcessInfo.processInfo.thermalState {
        case .critical, .serious: return 15
        case .fair: return 20
        default: return Self.rollingAheadFrames
        }
        #endif
    }

    /// Boomerang の実効有効性: iPhone で thermalState が serious 以上なら強制 OFF。
    private var effectiveBoomerangEnabled: Bool {
        guard UserDefaults.standard.bool(forKey: "boomerangMode") else { return false }
        #if !targetEnvironment(macCatalyst)
        let st = ProcessInfo.processInfo.thermalState
        if st == .serious || st == .critical { return false }
        #endif
        return true
    }

    private func startRollingPrefetch() {
        stopRollingPrefetch()
        guard let source = animSource else { return }
        let sid = ObjectIdentifier(source)
        let maxDim = currentMaxDim
        let q = DispatchQueue(label: "anim.rolling", qos: .userInitiated)

        // 初動: 先頭 30 frame を concurrentPerform で並列 decode + (HDR ON なら) 並列 enhance。
        // HDR eager enhance を入れないと、最初の 1 秒間だけ tick が非 HDR frame を先に表示 →
        // async enhance 完了で差し替え → 次 frame 非 HDR → 差し替え… の明滅が発生する。
        q.async { [weak self, weak source] in
            guard let self, let source, self.currentSourceID == sid else { return }
            let t = CFAbsoluteTimeGetCurrent()
            // 初動 prefetch も thermal 降格に従う
            let ahead = self.currentRollingAhead
            let n = min(ahead, source.frameCount)
            // 計測: 各 worker の wall time を pointer 経由で集計 → 並列度を算出
            let perFrameBox = UnsafeMutablePointer<Int64>.allocate(capacity: n)
            perFrameBox.initialize(repeating: 0, count: n)
            DispatchQueue.concurrentPerform(iterations: n) { i in
                let wt = CFAbsoluteTimeGetCurrent()
                _ = source.parallelFrame(at: i, maxPixelSize: maxDim)
                perFrameBox[i] = Int64((CFAbsoluteTimeGetCurrent() - wt) * 1_000_000)  // μs
            }
            let wallMs = Int((CFAbsoluteTimeGetCurrent() - t) * 1000)
            let sumMicros = (0..<n).reduce(Int64(0)) { $0 + perFrameBox[$1] }
            let sumMs = Int(sumMicros / 1000)
            let avgMs = n > 0 ? sumMs / n : 0
            let parallelism = wallMs > 0 ? Double(sumMs) / Double(wallMs) : 0
            LogManager.shared.log("Perf", "concurrentPerform wall=\(wallMs)ms sum=\(sumMs)ms avg=\(avgMs)ms/frame parallelism=\(String(format: "%.2f", parallelism))x frames=\(n)")
            perFrameBox.deinitialize(count: n)
            perFrameBox.deallocate()
            let decodeMs = wallMs

            // eager enhance: decode 完了した先頭 frame を per-frame 補正して cache 充填。
            // 補正無しでは tick が非補正 frame を先に表示 → async enhance 完了で差し替え →
            // 次 frame 非補正 → 差し替え… の明滅が発生する (HDR 経路と同じ理屈)。
            let config = self.currentConfig
            let gray = self.sourceIsGrayscale
            var enhanceMs = 0
            if config.hasAny {
                let t2 = CFAbsoluteTimeGetCurrent()
                let enhanceTargets: [(Int, CGImage)] = (0..<n).compactMap { i in
                    guard let cg = source.cachedFrame(at: i) else { return nil }
                    return (i, cg)
                }
                DispatchQueue.concurrentPerform(iterations: enhanceTargets.count) { k in
                    let (i, cg) = enhanceTargets[k]
                    if let enhanced = Self.applyEnhance(cg, config: config, isGrayscale: gray) {
                        self.enhancedCacheLock.lock()
                        self.enhancedCache[i] = enhanced
                        self.enhancedCacheLock.unlock()
                    }
                }
                enhanceMs = Int((CFAbsoluteTimeGetCurrent() - t2) * 1000)
            }
            LogManager.shared.log("Anim", "initial rolling prefetch decode=\(decodeMs)ms enhance=\(enhanceMs)ms config=\(config) frames=\(n)/\(source.frameCount)")
        }

        // 継続: 100ms 毎に keepSet 内 missing frame を並列 decode + 範囲外 evict
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.currentSourceID == sid else { return }
            let elapsed = CACurrentMediaTime() - self.linkStartTime
            let playingIdx = self.frameIndex(elapsed: elapsed, source: source)
            let count = source.frameCount
            // thermal 降格を timer 毎に反映 (fair/serious で窓狭く、critical は coordinator が停止)
            let ahead = self.currentRollingAhead
            let aheadTarget = min(playingIdx + ahead, count - 1)
            let effectiveCurrent = max(0, playingIdx)
            var keepSet = Set<Int>()
            let lo = max(0, effectiveCurrent - Self.rollingBehindKeep)
            if lo <= aheadTarget { for i in lo...aheadTarget { keepSet.insert(i) } }
            if self.effectiveBoomerangEnabled {
                let blo = max(0, effectiveCurrent - ahead)
                if blo < effectiveCurrent { for i in blo..<effectiveCurrent { keepSet.insert(i) } }
            }
            if playingIdx > count - ahead / 2 {
                let wrapCount = min(ahead / 2, count)
                for i in 0..<wrapCount { keepSet.insert(i) }
            }
            let missing = keepSet.compactMap { source.cachedFrame(at: $0) == nil ? $0 : nil }
            if !missing.isEmpty {
                DispatchQueue.concurrentPerform(iterations: missing.count) { k in
                    _ = source.parallelFrame(at: missing[k], maxPixelSize: maxDim)
                }
            }
            // 2026-04-25 計測結果フィードバック: iPhone の decode throughput (~30 frame/s 並列込み)
            // が playback 消費率 (30fps) と同率で、retainOnly が毎 cycle decode 済 frame を
            // 即 evict → cache と playing idx が永遠チェース → last=0 で固定する現象が判明。
            // frameCount ≤ 200 なら evict 停止で蓄積、1 cycle (~6s) 後 全 frame cache 済 → miss ゼロ。
            // メモリ: 179 × 1.3MB (cap 700) = 234MB/source, LRU 3 = 700MB (iPhone 15 Pro Max OK)。
            // Mac Catalyst は従来通り evict (canvas フル decode で memory 圧迫避けるため)。
            //
            // 2026-04-25 追記: preloadPlayback=ON の時は ▶ タップ時点で全 frame 事前 decode 済み
            // なので retainOnly は完全停止 (evict すると preload 作業が無駄になる)。
            // Tanaka 明示指示: 「全 platform 同じロジック」「234MB (iPhone) / 1.26GB (Mac full) は想定内」。
            let preloadOn = UserDefaults.standard.bool(forKey: "preloadPlayback")
            if !preloadOn {
                #if targetEnvironment(macCatalyst)
                source.retainOnly(indices: keepSet)
                #else
                if source.frameCount > 200 {
                    source.retainOnly(indices: keepSet)
                }
                // else: evict スキップ、decode 済 frame は次 cycle でも保持
                #endif
            }

            // 通常モード補正先読み: keepSet 内で frameCache あり & enhancedCache 無し &
            // inflight 無し を並列 enhance。ライブ UserDefaults から config を組み直し、
            // 設定変化時は cache 全破棄 + 現フレーム強制再描画。
            let liveConfig = AnimEnhanceConfig.fromDefaults()
            var configChanged = false
            self.enhancedCacheLock.lock()
            if liveConfig != self.currentConfig {
                self.enhancedCache.removeAll(keepingCapacity: false)
                self.enhanceInflight.removeAll(keepingCapacity: false)
                self.currentConfig = liveConfig
                configChanged = true
            }
            self.enhancedCacheLock.unlock()
            if configChanged {
                DispatchQueue.main.async { [weak self] in
                    self?.lastDisplayedIdx = -1
                }
                LogManager.shared.log("Anim", "enhance config changed (rolling) → \(liveConfig), cache cleared")
            }

            if !liveConfig.hasAny {
                self.enhancedCacheLock.lock()
                if !self.enhancedCache.isEmpty { self.enhancedCache.removeAll(keepingCapacity: false) }
                self.enhancedCacheLock.unlock()
            } else {
                let gray = self.sourceIsGrayscale
                self.enhancedCacheLock.lock()
                let enhanceMissing: [(Int, CGImage)] = keepSet.compactMap { i in
                    if self.enhancedCache[i] != nil || self.enhanceInflight.contains(i) { return nil }
                    guard let cg = source.cachedFrame(at: i) else { return nil }
                    self.enhanceInflight.insert(i)
                    return (i, cg)
                }
                self.enhancedCacheLock.unlock()
                if !enhanceMissing.isEmpty {
                    DispatchQueue.concurrentPerform(iterations: enhanceMissing.count) { k in
                        let (i, cg) = enhanceMissing[k]
                        let enhanced = Self.applyEnhance(cg, config: liveConfig, isGrayscale: gray)
                        self.enhancedCacheLock.lock()
                        self.enhanceInflight.remove(i)
                        if let enhanced { self.enhancedCache[i] = enhanced }
                        self.enhancedCacheLock.unlock()
                    }
                }
                // enhancedCache の evict も同期: keepSet 外を削除
                self.enhancedCacheLock.lock()
                self.enhancedCache = self.enhancedCache.filter { keepSet.contains($0.key) }
                self.enhancedCacheLock.unlock()
            }
        }
        timer.resume()
        rollingTimer = timer
    }

    private func stopRollingPrefetch() {
        rollingTimer?.cancel()
        rollingTimer = nil
    }

    private func startLink() {
        guard displayLink == nil, let source = animSource, source.frameCount > 1, source.totalDuration > 0 else { return }
        linkStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // WebP は典型 24fps、60fps tick は main thread 回転の無駄。30fps 固定で CPU 半減。
        // iPhone ProMotion 120Hz でも同様、display tick を間引いて decode スレッドに譲る。
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
        LogManager.shared.log("Anim", "displayLink START frames=\(source.frameCount) rate=30fps")
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
        stopRollingPrefetch()
    }

    /// Boomerang: 周期 = totalDuration * 2 - (delays[0] + delays[N-1]) 近似で。
    /// 単純化のため period = 2 * totalDuration として、前半 forward / 後半 reverse。
    private func frameIndex(elapsed: Double, source: AnimatedImageSource) -> Int {
        // Boomerang 実効有効判定はライブ (UserDefaults + thermal 降格)
        if effectiveBoomerangEnabled && source.frameCount >= 3 {
            let period = source.totalDuration * 2
            var t = elapsed.truncatingRemainder(dividingBy: period)
            if t < 0 { t += period }
            if t < source.totalDuration {
                return source.frameIndex(at: t)
            } else {
                return source.frameIndex(at: period - t)
            }
        }
        return source.frameIndex(at: elapsed)
    }

    private var tickCount: Int = 0
    private var tickMissCount: Int = 0

    @objc private func tick(_ link: CADisplayLink) {
        guard let source = animSource else { return }
        let elapsed = CACurrentMediaTime() - linkStartTime
        let idx = frameIndex(elapsed: elapsed, source: source)
        tickCount += 1

        if tickCount % 30 == 0 {
            LogManager.shared.log("Anim", "tick=\(tickCount) idx=\(idx) last=\(lastDisplayedIdx) miss=\(tickMissCount) elapsed=\(String(format: "%.2f", elapsed))s")
        }

        // 通常モード補正設定はライブで UserDefaults を読む。
        // setSource 時に固定すると後から toggle しても cached 結果が表示され続ける。
        let liveConfig = AnimEnhanceConfig.fromDefaults()
        enhancedCacheLock.lock()
        let configChanged = liveConfig != currentConfig
        if configChanged {
            enhancedCache.removeAll(keepingCapacity: false)
            enhanceInflight.removeAll(keepingCapacity: false)
            currentConfig = liveConfig
        }
        enhancedCacheLock.unlock()
        if configChanged {
            lastDisplayedIdx = -1
            LogManager.shared.log("Anim", "enhance config live toggle → \(liveConfig), cache cleared")
        }

        if idx == lastDisplayedIdx { return }

        if let cached = source.cachedFrame(at: idx) {
            if !liveConfig.hasAny {
                lastDisplayedIdx = idx
                self.image = UIImage(cgImage: cached)
            } else if let enhanced = readEnhanced(idx) {
                lastDisplayedIdx = idx
                self.image = UIImage(cgImage: enhanced)
            } else {
                // cache miss: 非補正を表示してから差し替えるとチラつくため、
                // enhance 完了までは前フレームを維持。enhance は裏で走らせる。
                scheduleEnhance(idx: idx, cg: cached, config: liveConfig)
                tickMissCount += 1
            }
        } else {
            tickMissCount += 1
        }
    }

    private func readEnhanced(_ idx: Int) -> CGImage? {
        enhancedCacheLock.lock()
        defer { enhancedCacheLock.unlock() }
        return enhancedCache[idx]
    }

    private func scheduleEnhance(idx: Int, cg: CGImage, config: AnimEnhanceConfig) {
        enhancedCacheLock.lock()
        if enhancedCache[idx] != nil || enhanceInflight.contains(idx) {
            enhancedCacheLock.unlock()
            return
        }
        enhanceInflight.insert(idx)
        enhancedCacheLock.unlock()
        let gray = sourceIsGrayscale
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let enhanced = Self.applyEnhance(cg, config: config, isGrayscale: gray)
            self.enhancedCacheLock.lock()
            self.enhanceInflight.remove(idx)
            // 設定が変わっていたらこの enhance 結果は古いので破棄
            let stillCurrent = self.currentConfig == config
            if stillCurrent, let enhanced {
                self.enhancedCache[idx] = enhanced
            }
            self.enhancedCacheLock.unlock()
            // **重要**: enhance 完了時、まだ該当 idx を表示中なら image を差し替える。
            // これをしないと tick の `idx == lastDisplayedIdx` early return で
            // 補正結果が一度も表示されないまま次フレームに進む (HDR 時の元バグ対策)。
            guard stillCurrent, let enhanced else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastDisplayedIdx == idx else { return }
                guard self.currentConfig == config else { return }
                self.image = UIImage(cgImage: enhanced)
            }
        }
    }

    /// 共通 enhance チェーン。静画 applyFilterPipeline と同じ順序・排他を再現。
    /// 順序: denoise → enhanceFilter → (HDR 排他) → personSeg。
    /// - denoise ON: CINoiseReduction (sharpness=0.4 含む) で線を再シャープ化
    /// - enhanceFilter ON: S字トーン + Vibrance + HighlightShadow + LocalToneMap (HDR は抑止)
    /// - enhanceFilter OFF & HDR ON: HDREnhancer.enhanceCG
    /// - personSeg ON: Vision/NE で人物マスク → 人物領域のみシャープ+彩度ブースト。マスク空/失敗時は
    ///   スキップ (検出率の低いアニメ系でもチェーン破壊しない)。チェーン末尾に置くのは、先行段
    ///   (denoise/enhanceFilter/HDR) の効果を人物領域に乗せた上で更にブーストする意図。
    /// - 全 OFF: cg をそのまま返す (hasAny で事前弾きされるので通常は到達しない)
    nonisolated fileprivate static func applyEnhance(_ cg: CGImage, config: AnimEnhanceConfig, isGrayscale: Bool) -> CGImage? {
        var result: CGImage = cg
        if config.denoise {
            result = LanczosUpscaler.denoiseCG(result) ?? result
        }
        if config.enhanceFilter {
            result = LanczosUpscaler.enhanceFilterCG(result, isGrayscale: isGrayscale) ?? result
        } else if config.hdr {
            result = HDREnhancer.enhanceCG(result) ?? result
        }
        if config.personSeg {
            if let segmented = LanczosUpscaler.applyPersonSegmentationCG(result) {
                result = segmented
            }
            // マスク nil 時は result 不変 (元のブースト済画像をそのまま返す)
        }
        return result
    }

    private func computeMaxPixelSize() -> CGFloat {
        let w = bounds.width
        let h = bounds.height
        let d = max(w, h)
        let boundsBased: CGFloat = d > 0 ? d : max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        #if targetEnvironment(macCatalyst)
        return boundsBased
        #else
        // iPhone/iPad 適応的 scaling: canvas が大きいほど target を厳しく絞って
        // decode 負荷を軽減 (案 A)。Mac Catalyst は canvas size 非考慮のまま。
        guard let source = animSource else { return boundsBased }
        let canvasLonger = max(source.pixelSize.width, source.pixelSize.height)
        let cap: CGFloat
        if canvasLonger > 2500 { cap = 700 }
        else if canvasLonger > 2000 { cap = 900 }
        else { cap = 1000 }
        return min(boundsBased, cap)
        #endif
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopLink()
        } else if isActive, displayLink == nil, animSource != nil {
            startLink()
        }
    }

    deinit {
        displayLink?.invalidate()
        // rolling prefetch の DispatchSourceTimer を cancel しないと queue に retain され
        // 続けて永遠に fire する。deinit 時点で確実に止める。
        rollingTimer?.cancel()
        rollingTimer = nil
        LogManager.shared.log("Mem", "AnimatedSourceImageView deinit (displayLink/rollingTimer cleaned)")
    }
}

/// WebP ファイル URL から直接再生する三位一体経路の View。
/// MP4 変換を介さず CGImageSource で原本 WebP を読む。AnimatedSourceImageView.setSource
/// が UserDefaults から `boomerangMode` / `hdrEnhancement` を拾って per-frame で
/// Boomerang (ping-pong) + HDR (CIFilter パイプライン) を同時適用する。
///
/// **再生制御**: ▶ タップ再生方式 (2026-04-25 設計変更)。
/// - デフォルト: ポスター + ▶ 表示 (再生しない)
/// - ▶ タップ: AnimatedPlaybackCoordinator に登録 → そのセルで再生開始
/// - 再度タップ: 停止 (coordinator から除外)
/// - 最大同時再生 3 セル、4 セル目で LRU 排出
/// - 他ページへスクロールしても coordinator に残っていれば再生継続
struct BoomerangWebPView: View {
    enum Input: Equatable {
        case url(URL)
        case data(Data)
    }

    let input: Input
    /// reader 識別子 (例: "gallery-3898101", "local-3898101", "nh-3898101")
    let readerID: String
    /// ページ index (readerID と組み合わせて coordinator キーに)
    let pageIndex: Int
    var staticPlaceholder: UIImage? = nil

    init(sourceURL: URL, readerID: String, pageIndex: Int, staticPlaceholder: UIImage? = nil) {
        self.input = .url(sourceURL)
        self.readerID = readerID
        self.pageIndex = pageIndex
        self.staticPlaceholder = staticPlaceholder
    }

    init(sourceData: Data, readerID: String, pageIndex: Int, staticPlaceholder: UIImage? = nil) {
        self.input = .data(sourceData)
        self.readerID = readerID
        self.pageIndex = pageIndex
        self.staticPlaceholder = staticPlaceholder
    }

    @State private var source: AnimatedImageSource?
    @State private var loadFailed: Bool = false
    @State private var isPreloading: Bool = false
    @State private var preloadProgress: Double = 0
    @ObservedObject private var coordinator = AnimatedPlaybackCoordinator.shared
    /// PSP PMDVis 方式プリロード: ▶ タップ → 全 frame 並列 decode → 完了後に再生開始。
    /// 初動チェース (~5s) を完全除去する代償に、再生開始まで待機時間 (iPhone 3-4s / Mac 1-2s)。
    @AppStorage("preloadPlayback") private var preloadPlayback = true

    /// システム逼迫時の共有フラグ (熱 or メモリ警告)。registry から書き換えられる。現状は retained for 将来。
    static var systemDowngraded: Bool = false

    private var pageKey: AnimatedPlaybackCoordinator.PageKey {
        .init(readerID: readerID, index: pageIndex)
    }
    private var isPlaying: Bool { coordinator.isPlaying(pageKey) }

    var body: some View {
        ZStack {
            if let staticPlaceholder {
                Image(uiImage: staticPlaceholder)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
                    .aspectRatio(contentAspectRatio, contentMode: .fit)
            }
            // 再生セル: source が ready かつプリロード中でない時のみ表示。
            // プリロード中は静止画 placeholder を残し、裏で全 frame decode を走らせる。
            if isPlaying, let source, !isPreloading {
                AnimatedImageCellView(source: source, isActive: true)
            }
            // ▶ オーバーレイ: 停止中 (再生もプリロードもしてない) のみ表示。
            if !isPlaying && !isPreloading {
                Button {
                    coordinator.toggle(pageKey)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 64, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("再生")
            }
            // プリロード中オーバーレイ: プログレスバー + パーセント + キャンセル。
            // キャンセル = coordinator.toggle で isPlaying 外す → task 再実行で Task.isCancelled → 終了。
            if isPreloading {
                VStack(spacing: 12) {
                    ProgressView(value: preloadProgress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(maxWidth: 220)
                    Text("プリロード中 \(Int(preloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.white)
                    Button {
                        coordinator.toggle(pageKey)
                    } label: {
                        Text("キャンセル")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        // 再生中に全体タップ → 停止 (▶ ボタンが非表示になっても "Tap to stop" できるよう)
        .contentShape(Rectangle())
        .onTapGesture {
            if isPlaying { coordinator.toggle(pageKey) }
        }
        .task(id: activeTaskID) {
            if isPlaying {
                // 200ms デバウンス (誤タップ / 連打対策)
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
                // 再生状態が変わってなければ source をロード
                guard coordinator.isPlaying(pageKey) else { return }
                await loadSource()
            } else {
                if self.source != nil {
                    self.source = nil
                    LogManager.shared.log("Boomerang", "source released (not playing) key=\(readerID)#\(pageIndex)")
                }
            }
        }
    }

    /// task は isPlaying 遷移のみで再実行。
    private var activeTaskID: String {
        switch input {
        case .url(let u): return "u:\(u.absoluteString):\(isPlaying)"
        case .data(let d): return "d:\(d.count):\(isPlaying)"
        }
    }

    /// 縦レイアウトで AnimatedImageCellView が 0-height に潰れないよう、
    /// 既知の aspect を返す。優先順位: source.pixelSize > staticPlaceholder.size > 0.6667 (portrait WebP)
    private var contentAspectRatio: CGFloat {
        if let source, source.pixelSize.height > 0 {
            return source.pixelSize.width / source.pixelSize.height
        }
        if let sp = staticPlaceholder, sp.size.height > 0 {
            return sp.size.width / sp.size.height
        }
        return 2.0 / 3.0
    }

    private func loadSource() async {
        let input = self.input
        // URL 経路なら AnimatedImageSourceCache (LRU 強参照、最近 3 source 保持) を先にチェック。
        // ヒットすると demux + 初動 decode 全てスキップ → 同作品再タップが 800-1300ms → 即時に。
        let cacheKey: String? = {
            if case .url(let u) = input { return u.absoluteString }
            return nil
        }()
        if let cacheKey, let cached = AnimatedImageSourceCache.shared.get(urlKey: cacheKey) {
            guard coordinator.isPlaying(pageKey) else { return }
            LogManager.shared.log("Boomerang", "source CACHE HIT frames=\(cached.frameCount)")
            if preloadPlayback && shouldPreload(cached) {
                await runPreload(cached)
                guard coordinator.isPlaying(pageKey), !Task.isCancelled else { return }
            }
            self.source = cached
            self.loadFailed = false
            return
        }

        let loaded: AnimatedImageSource? = await Task.detached(priority: .userInitiated) {
            switch input {
            case .url(let url):
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return AnimatedImageSource.make(data: data)
            case .data(let data):
                return AnimatedImageSource.make(data: data)
            }
        }.value
        guard coordinator.isPlaying(pageKey) else {
            LogManager.shared.log("Boomerang", "source built but no longer playing — discard")
            return
        }
        guard let loaded else {
            self.loadFailed = true
            let label: String = {
                switch input {
                case .url(let u): return u.lastPathComponent
                case .data(let d): return "data(\(d.count)B)"
                }
            }()
            LogManager.shared.log("Boomerang", "source build FAILED \(label)")
            return
        }
        if let cacheKey {
            AnimatedImageSourceCache.shared.put(urlKey: cacheKey, source: loaded)
        }
        LogManager.shared.log("Boomerang", "source ready frames=\(loaded.frameCount) size=\(Int(loaded.pixelSize.width))x\(Int(loaded.pixelSize.height))")
        if preloadPlayback && shouldPreload(loaded) {
            await runPreload(loaded)
            guard coordinator.isPlaying(pageKey), !Task.isCancelled else { return }
        }
        self.source = loaded
        self.loadFailed = false
    }

    /// プリロード級の分類。frameCount × canvas で「追いつき負荷」を 3 段階に格付け。
    /// 各級で `targetSeconds` を変えて、重量作品ほど予算を引き延ばす。
    ///
    /// 基準 (2026-04-25 田中命名):
    /// - `.none`: canvas < 2000px or frames < 150 → rolling だけで追いつく、preload スキップ
    /// - `.fugen`: 2000px ≤ canvas && 150 ≤ frames < 200 (例: 179f × 2080x3104)
    /// - `.ultraFugen`: 2000px ≤ canvas && 200 ≤ frames (例: 208f × 2080x3104、14ページ帯)
    ///
    /// 実例:
    /// - 208 frames × 2080x3104 (超フゲン): frames >= 200 → ultraFugen, target 3.0s
    /// - 179 frames × 2080x3104 (フゲン): → fugen, target 1.8s
    /// - 100 frames × 2080x3104: frames < 150 → none (rolling で完了)
    /// - 179 frames × 1500x2200: canvas < 2000 → none (1 frame ~15ms で追いつく)
    fileprivate enum PreloadClass: CustomStringConvertible {
        case none
        case fugen
        case ultraFugen

        /// プリロード予算 (decode のみ、rolling で残りを追いかける)。
        /// ultraFugen は 208f × ~250ms/frame の iPhone 実測で 1.8s → 14% しか preload できず
        /// 再生側が後半到達前に rolling 追いつき失敗 → drops=160+ を記録。3.0s に緩和して
        /// 先頭 ~25% まで preload + rolling で稼ぐ構成。
        var targetSeconds: Double {
            switch self {
            case .none: return 0
            case .fugen: return 1.8
            case .ultraFugen: return 3.0
            }
        }

        var shouldPreload: Bool { self != .none }

        var description: String {
            switch self {
            case .none: return "none"
            case .fugen: return "fugen"
            case .ultraFugen: return "ultraFugen"
            }
        }
    }

    private func classifyPreload(_ source: AnimatedImageSource) -> PreloadClass {
        let canvasLonger = max(source.pixelSize.width, source.pixelSize.height)
        let frames = source.frameCount
        if canvasLonger >= 2000 && frames >= 200 { return .ultraFugen }
        if canvasLonger >= 2000 && frames >= 150 { return .fugen }
        return .none
    }

    /// プリロード要否の判定 + ログ出力。`classifyPreload` の薄いラッパ。
    /// Mac Catalyst は CPU/メモリ共に余裕があり decode が充分速いため、プリロード待機
    /// (ポスター → ▶ → プリロード中オーバーレイ → 再生) の UX コストのほうが上回る。
    /// → Mac では常に SKIP、rolling prefetch に任せる (田中指示 2026-04-25)。
    private func shouldPreload(_ source: AnimatedImageSource) -> Bool {
        #if targetEnvironment(macCatalyst)
        LogManager.shared.log("Anim", "preload SKIP (Mac Catalyst: rolling で充分)")
        return false
        #else
        let cls = classifyPreload(source)
        let dim = "\(source.frameCount)f × \(Int(source.pixelSize.width))x\(Int(source.pixelSize.height))"
        if cls == .none {
            LogManager.shared.log("Anim", "preload SKIP (not Fugen-class: \(dim))")
        } else {
            LogManager.shared.log("Anim", "preload class=\(cls) target=\(cls.targetSeconds)s \(dim)")
        }
        return cls.shouldPreload
        #endif
    }

    private func runPreload(_ src: AnimatedImageSource) async {
        isPreloading = true
        preloadProgress = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        let frameCount = src.frameCount
        let maxDim = preloadMaxDim(for: src)
        let target = classifyPreload(src).targetSeconds
        LogManager.shared.log("Anim", "preload start frames=\(frameCount) target=\(target)s maxDim=\(Int(maxDim))")
        let batchSize = 10
        var batchStart = 0
        while batchStart < frameCount {
            if Task.isCancelled { break }
            if !coordinator.isPlaying(pageKey) { break }
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            if elapsed >= target { break }
            let batchEnd = min(batchStart + batchSize, frameCount)
            let n = batchEnd - batchStart
            let start = batchStart
            await Task.detached(priority: .userInitiated) { [src] in
                DispatchQueue.concurrentPerform(iterations: n) { k in
                    _ = src.parallelFrame(at: start + k, maxPixelSize: maxDim)
                }
            }.value
            batchStart = batchEnd
            let now = CFAbsoluteTimeGetCurrent() - t0
            preloadProgress = min(now / target, 1.0)
            if batchEnd % 30 == 0 {
                LogManager.shared.log("Anim", "preload progress \(batchEnd)/\(frameCount) elapsed=\(String(format: "%.2f", now))s")
            }
        }
        let dur = CFAbsoluteTimeGetCurrent() - t0
        let cancelled = Task.isCancelled || !coordinator.isPlaying(pageKey)
        if cancelled {
            LogManager.shared.log("Anim", "preload CANCELLED at \(batchStart)/\(frameCount) dur=\(String(format: "%.2f", dur))s")
        } else {
            LogManager.shared.log("Anim", "preload DONE duration=\(String(format: "%.2f", dur))s preloaded=\(batchStart)/\(frameCount) (rolling decodes rest)")
        }
        isPreloading = false
        preloadProgress = 0
    }

    /// setSource 時の computeMaxPixelSize と同じ基準 (screen bounds + canvas 別 cap) で
    /// preload も decode するため、cache hit の一致率を最大化。
    private func preloadMaxDim(for source: AnimatedImageSource) -> CGFloat {
        let screen = UIScreen.main.bounds
        let boundsBased = max(screen.width, screen.height)
        #if targetEnvironment(macCatalyst)
        return boundsBased
        #else
        let canvasLonger = max(source.pixelSize.width, source.pixelSize.height)
        let cap: CGFloat
        if canvasLonger > 2500 { cap = 700 }
        else if canvasLonger > 2000 { cap = 900 }
        else { cap = 1000 }
        return min(boundsBased, cap)
        #endif
    }
}

/// リーダーセル用の軽量アニメビュー（ズーム無し）
struct AnimatedImageCellView: UIViewRepresentable {
    let source: AnimatedImageSource
    var isActive: Bool = true

    func makeUIView(context: Context) -> AnimatedSourceImageView {
        let iv = AnimatedSourceImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.setSource(source, isActive: isActive)
        return iv
    }

    func updateUIView(_ uiView: AnimatedSourceImageView, context: Context) {
        uiView.setSource(source, isActive: isActive)
    }
}

/// layoutSubviewsでconfigureForSizeをトリガーできるUIScrollViewサブクラス
final class LayoutNotifyingScrollView: UIScrollView {
    var onLayout: ((CGSize) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size.width > 0 && bounds.size.height > 0 {
            onLayout?(bounds.size)
        }
    }
}

/// アニメ再生用のズーム対応ビュー
struct AnimatedPageZoomableScrollView: UIViewRepresentable {
    let source: AnimatedImageSource
    @Binding var isAtMinZoom: Bool
    let onTapRegion: (TapRegion) -> Void

    func makeUIView(context: Context) -> LayoutNotifyingScrollView {
        let scrollView = LayoutNotifyingScrollView()
        scrollView.maximumZoomScale = 4.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear

        let imageView = AnimatedSourceImageView()
        imageView.frame = CGRect(origin: .zero, size: source.pixelSize)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        imageView.setSource(source, isActive: true)
        scrollView.addSubview(imageView)
        scrollView.contentSize = source.pixelSize

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.isAtMinZoomBinding = $isAtMinZoom
        context.coordinator.onTapRegion = onTapRegion

        let pixelSize = source.pixelSize
        scrollView.onLayout = { [weak coord = context.coordinator] _ in
            coord?.configureForSize(pixelSize)
        }

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: LayoutNotifyingScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        imageView.setSource(source, isActive: true)
        context.coordinator.isAtMinZoomBinding = $isAtMinZoom
        context.coordinator.onTapRegion = onTapRegion
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: AnimatedSourceImageView?
        weak var scrollView: UIScrollView?
        var isAtMinZoomBinding: Binding<Bool>?
        var onTapRegion: ((TapRegion) -> Void)?
        private var lastConfiguredSize: CGSize = .zero

        func configureForSize(_ pixelSize: CGSize) {
            guard let scrollView, let imageView else { return }
            let svSize = scrollView.bounds.size
            guard svSize.width > 0, svSize.height > 0 else { return }
            if lastConfiguredSize == svSize { return }
            lastConfiguredSize = svSize
            guard pixelSize.width > 0, pixelSize.height > 0 else { return }

            imageView.frame = CGRect(origin: .zero, size: pixelSize)
            scrollView.contentSize = pixelSize

            let scaleW = svSize.width / pixelSize.width
            let scaleH = svSize.height / pixelSize.height
            let minScale = min(scaleW, scaleH)

            scrollView.minimumZoomScale = minScale
            scrollView.maximumZoomScale = max(minScale * 4, 4.0)
            scrollView.zoomScale = minScale

            centerImage()
            isAtMinZoomBinding?.wrappedValue = true
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
            let atMin = scrollView.zoomScale <= scrollView.minimumZoomScale * 1.05
            isAtMinZoomBinding?.wrappedValue = atMin
        }

        private func centerImage() {
            guard let scrollView, let imageView else { return }
            let svSize = scrollView.bounds.size
            let contentSize = scrollView.contentSize
            let insetX = max(0, (svSize.width - contentSize.width) / 2)
            let insetY = max(0, (svSize.height - contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
            imageView.frame.size = contentSize
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let atMin = scrollView.zoomScale <= scrollView.minimumZoomScale * 1.05
            guard atMin else { return }

            let location = gesture.location(in: scrollView)
            let width = scrollView.bounds.width
            let region: TapRegion
            if location.x < width * 0.33 {
                region = .left
            } else if location.x > width * 0.67 {
                region = .right
            } else {
                region = .center
            }
            onTapRegion?(region)
        }
    }
}
#endif
