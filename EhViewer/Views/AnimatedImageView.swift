import SwiftUI

#if canImport(UIKit)
import UIKit

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
    private var boomerangEnabled: Bool = false
    private var hdrEnabled: Bool = false
    private var currentMaxDim: CGFloat = 0

    /// HDR 適用済み CGImage キャッシュ (key = frame index)。
    /// HDREnhancer.enhanceCG の GPU roundtrip を 1 frame 1 回に抑える。
    private var hdrCache: [Int: CGImage] = [:]
    private let hdrCacheLock = NSLock()
    private var hdrInflight: Set<Int> = []

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
        hdrCacheLock.lock()
        hdrCache.removeAll(keepingCapacity: false)
        hdrInflight.removeAll(keepingCapacity: false)
        hdrCacheLock.unlock()

        let maxDim = computeMaxPixelSize()
        currentMaxDim = maxDim

        let ud = UserDefaults.standard
        let userBoomerang = ud.bool(forKey: "boomerangMode")
        let userHDR = ud.bool(forKey: "hdrEnhancement")
        let maxFramesFromUD = ud.integer(forKey: "boomerangMaxFrames")
        let boomerangMax = maxFramesFromUD > 0 ? maxFramesFromUD : 200
        boomerangEnabled = userBoomerang && source.frameCount >= 3 && source.frameCount <= boomerangMax
        hdrEnabled = userHDR  // per-frame 適用なので frame 数依存の降格は不要

        LogManager.shared.log("Anim", "setSource frames=\(source.frameCount) active=\(isActive) dur=\(String(format: "%.2f", source.totalDuration))s boomerang=\(boomerangEnabled) hdr=\(hdrEnabled) maxDim=\(Int(maxDim))")

        // first frame SYNC (黒画面回避)
        let t0 = CFAbsoluteTimeGetCurrent()
        if let first = source.frame(at: 0, maxPixelSize: maxDim) {
            self.image = UIImage(cgImage: hdrEnabled ? (HDREnhancer.enhanceCG(first) ?? first) : first)
            lastDisplayedIdx = 0
            LogManager.shared.log("Anim", "first frame SYNC (decode=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms size=\(first.width)x\(first.height))")
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

    private func startRollingPrefetch() {
        stopRollingPrefetch()
        guard let source = animSource else { return }
        let sid = ObjectIdentifier(source)
        let maxDim = currentMaxDim
        let q = DispatchQueue(label: "anim.rolling", qos: .userInitiated)

        // 初動: 先頭 30 frame を concurrentPerform で並列 decode
        q.async { [weak self, weak source] in
            guard let self, let source, self.currentSourceID == sid else { return }
            let t = CFAbsoluteTimeGetCurrent()
            let n = min(Self.rollingAheadFrames, source.frameCount)
            DispatchQueue.concurrentPerform(iterations: n) { i in
                _ = source.parallelFrame(at: i, maxPixelSize: maxDim)
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - t) * 1000)
            LogManager.shared.log("Anim", "initial rolling prefetch \(ms)ms frames=\(n)/\(source.frameCount)")
        }

        // 継続: 100ms 毎に keepSet 内 missing frame を並列 decode + 範囲外 evict
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.currentSourceID == sid else { return }
            // **重要**: prefetch 中心は lastDisplayedIdx (cache miss で停止) ではなく
            // elapsed から逆算した "今まさに再生すべき idx"。これで cache miss → lastDisplayedIdx 停止 →
            // prefetch window も停止 のデッドロックを回避。
            let elapsed = CACurrentMediaTime() - self.linkStartTime
            let playingIdx = self.frameIndex(elapsed: elapsed, source: source)
            let count = source.frameCount
            let aheadTarget = min(playingIdx + Self.rollingAheadFrames, count - 1)
            let effectiveCurrent = max(0, playingIdx)
            var keepSet = Set<Int>()
            let lo = max(0, effectiveCurrent - Self.rollingBehindKeep)
            if lo <= aheadTarget { for i in lo...aheadTarget { keepSet.insert(i) } }
            if self.boomerangEnabled {
                let blo = max(0, effectiveCurrent - Self.rollingAheadFrames)
                if blo < effectiveCurrent { for i in blo..<effectiveCurrent { keepSet.insert(i) } }
            }
            if playingIdx > count - Self.rollingAheadFrames / 2 {
                let wrapCount = min(Self.rollingAheadFrames / 2, count)
                for i in 0..<wrapCount { keepSet.insert(i) }
            }
            let missing = keepSet.compactMap { source.cachedFrame(at: $0) == nil ? $0 : nil }
            if !missing.isEmpty {
                DispatchQueue.concurrentPerform(iterations: missing.count) { k in
                    _ = source.parallelFrame(at: missing[k], maxPixelSize: maxDim)
                }
            }
            source.retainOnly(indices: keepSet)
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
        link.add(to: .main, forMode: .common)
        displayLink = link
        LogManager.shared.log("Anim", "displayLink START frames=\(source.frameCount)")
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
        stopRollingPrefetch()
    }

    /// Boomerang: 周期 = totalDuration * 2 - (delays[0] + delays[N-1]) 近似で。
    /// 単純化のため period = 2 * totalDuration として、前半 forward / 後半 reverse。
    private func frameIndex(elapsed: Double, source: AnimatedImageSource) -> Int {
        if boomerangEnabled && source.frameCount >= 3 {
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

        // 30 tick (約 0.5s) ごとに診断ログ
        if tickCount % 30 == 0 {
            LogManager.shared.log("Anim", "tick=\(tickCount) idx=\(idx) last=\(lastDisplayedIdx) miss=\(tickMissCount) elapsed=\(String(format: "%.2f", elapsed))s")
        }

        if idx == lastDisplayedIdx { return }

        // cache hit のみ advance (sync decode を tick で走らせない)
        if let cached = source.cachedFrame(at: idx) {
            lastDisplayedIdx = idx
            if hdrEnabled {
                if let enhanced = readHDR(idx) {
                    self.image = UIImage(cgImage: enhanced)
                } else {
                    self.image = UIImage(cgImage: cached)
                    scheduleHDREnhance(idx: idx, cg: cached)
                }
            } else {
                self.image = UIImage(cgImage: cached)
            }
        } else {
            tickMissCount += 1
            // prefetch 完了待ち。image は前フレームのまま維持
        }
    }

    private func readHDR(_ idx: Int) -> CGImage? {
        hdrCacheLock.lock()
        defer { hdrCacheLock.unlock() }
        return hdrCache[idx]
    }

    private func scheduleHDREnhance(idx: Int, cg: CGImage) {
        hdrCacheLock.lock()
        if hdrCache[idx] != nil || hdrInflight.contains(idx) {
            hdrCacheLock.unlock()
            return
        }
        hdrInflight.insert(idx)
        hdrCacheLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let enhanced = HDREnhancer.enhanceCG(cg)
            self.hdrCacheLock.lock()
            self.hdrInflight.remove(idx)
            if let enhanced {
                self.hdrCache[idx] = enhanced
            }
            self.hdrCacheLock.unlock()
        }
    }

    private func computeMaxPixelSize() -> CGFloat {
        let w = bounds.width
        let h = bounds.height
        let d = max(w, h)
        if d <= 0 {
            return max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        }
        return d
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
/// 200 frame 超の WebP は Boomerang 自動 OFF + 警告ログ (`boomerangMaxFrames` で調整可)。
struct BoomerangWebPView: View {
    enum Input: Equatable {
        case url(URL)
        case data(Data)
    }

    let input: Input
    var isActive: Bool = true
    var staticPlaceholder: UIImage? = nil

    init(sourceURL: URL, isActive: Bool = true, staticPlaceholder: UIImage? = nil) {
        self.input = .url(sourceURL)
        self.isActive = isActive
        self.staticPlaceholder = staticPlaceholder
    }

    init(sourceData: Data, isActive: Bool = true, staticPlaceholder: UIImage? = nil) {
        self.input = .data(sourceData)
        self.isActive = isActive
        self.staticPlaceholder = staticPlaceholder
    }

    @State private var source: AnimatedImageSource?
    @State private var loadFailed: Bool = false

    var body: some View {
        // ポスター下敷き方式: staticPlaceholder を常に描画し、その上に source ready
        // 時だけ AnimatedImageCellView を overlay する。セルの aspect / 高さは
        // staticPlaceholder だけで決まる → 状態遷移で layout 不変 → 黒線完全消滅。
        ZStack {
            if let staticPlaceholder {
                Image(uiImage: staticPlaceholder)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
                    .aspectRatio(contentAspectRatio, contentMode: .fit)
            }
            if isActive, let source {
                AnimatedImageCellView(source: source, isActive: true)
            }
        }
        .task(id: activeTaskID) {
            // スクロール中にセルが一瞬 active になっただけで source build を始めると
            // 5-10 ページ同時 prefetch でデコーダが飽和する。200ms のデバウンス後も
            // active ならロード、それ以前に inactive に戻ったら Task.CancellationError で中断。
            if isActive {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return  // cancelled (isActive flipped before 200ms)
                }
                await loadSource()
            } else {
                if self.source != nil {
                    self.source = nil
                    LogManager.shared.log("Boomerang", "source released (inactive)")
                }
            }
        }
    }

    /// task を active 遷移のみで再実行するための id。input と isActive の組を key にする。
    private var activeTaskID: String {
        switch input {
        case .url(let u): return "u:\(u.absoluteString):\(isActive)"
        case .data(let d): return "d:\(d.count):\(isActive)"
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
        let loaded: AnimatedImageSource? = await Task.detached(priority: .userInitiated) {
            switch input {
            case .url(let url):
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return AnimatedImageSource.make(data: data)
            case .data(let data):
                return AnimatedImageSource.make(data: data)
            }
        }.value
        await MainActor.run {
            guard self.isActive else {
                LogManager.shared.log("Boomerang", "source built but already inactive — discard")
                return
            }
            if let loaded {
                self.source = loaded
                self.loadFailed = false
                LogManager.shared.log("Boomerang", "source ready frames=\(loaded.frameCount) size=\(Int(loaded.pixelSize.width))x\(Int(loaded.pixelSize.height))")
            } else {
                self.loadFailed = true
                let label: String = {
                    switch input {
                    case .url(let u): return u.lastPathComponent
                    case .data(let d): return "data(\(d.count)B)"
                    }
                }()
                LogManager.shared.log("Boomerang", "source build FAILED \(label)")
            }
        }
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
