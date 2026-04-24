import Foundation
import ImageIO
import CoreImage
#if canImport(UIKit)
import UIKit
#endif

/// AnimatedImageSource の LRU 強参照キャッシュ。
/// ▶ タップで毎回 WebP demux + 初動 decode を走らせると 800-1300ms のラグが出るため、
/// 最近 3 source を強参照で保持して再タップ即再生を実現。
///
/// - キー: URL.absoluteString (`.url` 経路のみ対象。`.data` 経路はキャッシュしない)
/// - 容量: 3 件 (各 rawData 10-20MB + frame cache ~75MB = 合計 ~300MB 上限目安)
/// - evict: タップ順の古いものから
/// - メモリ警告時: Registry.dropAllCaches と同時に clear
#if canImport(UIKit)
@MainActor
final class AnimatedImageSourceCache {
    static let shared = AnimatedImageSourceCache()
    private init() {}

    private let capacity: Int = 3
    private var order: [String] = []
    private var items: [String: AnimatedImageSource] = [:]

    func get(urlKey: String) -> AnimatedImageSource? {
        guard let s = items[urlKey] else { return nil }
        // LRU: 先頭に持ち上げ
        if let idx = order.firstIndex(of: urlKey) { order.remove(at: idx) }
        order.insert(urlKey, at: 0)
        return s
    }

    func put(urlKey: String, source: AnimatedImageSource) {
        if items[urlKey] != nil {
            items[urlKey] = source
            if let idx = order.firstIndex(of: urlKey) { order.remove(at: idx) }
            order.insert(urlKey, at: 0)
            return
        }
        items[urlKey] = source
        order.insert(urlKey, at: 0)
        while order.count > capacity {
            let evicted = order.removeLast()
            items.removeValue(forKey: evicted)
            LogManager.shared.log("Anim", "source cache evict \((evicted as NSString).lastPathComponent)")
        }
    }

    func clear() {
        if !items.isEmpty {
            LogManager.shared.log("Anim", "source cache clear count=\(items.count)")
            items.removeAll()
            order.removeAll()
        }
    }
}

/// 現在生存中の AnimatedImageSource インスタンスを弱参照で束ね、
/// UIApplication.didReceiveMemoryWarning 通知で一斉に frameCache を解放する。
/// 個別インスタンスが NotificationCenter observer を持つと deinit 順で解放されない
/// 危険があるため、中央ハブ方式で集中管理する。
final class AnimatedImageSourceRegistry {
    static let shared = AnimatedImageSourceRegistry()
    private let lock = NSLock()
    private var sources: [ObjectIdentifier: Weak<AnimatedImageSource>] = [:]
    private var observerInstalled = false

    private struct Weak<T: AnyObject> {
        weak var value: T?
    }

    func register(_ source: AnimatedImageSource) {
        lock.lock()
        sources[ObjectIdentifier(source)] = Weak(value: source)
        if !observerInstalled {
            observerInstalled = true
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { _ in
                // 多重可視降格フラグを立てる: 以降は currentIndex 中央 1 枚のみ再生。
                // cache (強参照 LRU / 弱参照 registry) も全破棄する。
                BoomerangWebPView.systemDowngraded = true
                AnimatedImageSourceRegistry.shared.dropAllCaches()
                Task { @MainActor in AnimatedImageSourceCache.shared.clear() }
                LogManager.shared.log("Mem", "MemoryWarning → systemDowngraded=true (多重可視停止)")
            }
            // 熱状態通知: .fair/.serious は AnimatedSourceImageView が live で読んで
            // rolling 窓と Boomerang を動的降格。.critical のみ Coordinator.stopAll で
            // アニメ全停止させる (静止画ポスターだけ残る)。
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                let st = ProcessInfo.processInfo.thermalState
                let name: String = {
                    switch st {
                    case .nominal: return "nominal"
                    case .fair: return "fair"
                    case .serious: return "serious"
                    case .critical: return "critical"
                    @unknown default: return "unknown"
                    }
                }()
                LogManager.shared.log("Mem", "thermalState=\(name)")
                if st == .critical {
                    Task { @MainActor in
                        AnimatedPlaybackCoordinator.shared.stopAll()
                    }
                }
            }
        }
        lock.unlock()
    }

    func unregister(_ source: AnimatedImageSource) {
        lock.lock()
        sources.removeValue(forKey: ObjectIdentifier(source))
        lock.unlock()
    }

    private func dropAllCaches() {
        lock.lock()
        let snapshot = sources.values.compactMap { $0.value }
        lock.unlock()
        LogManager.shared.log("Mem", "MemoryWarning → dropAllCaches alive=\(snapshot.count)")
        for s in snapshot { s.dropFrameCache() }
    }
}
#endif

/// アニメGIF/WebP/APNG用のフレームオンデマンド供給源。
/// 全フレームを事前に decode せず、CGImageSource を保持して必要時に1フレームずつ取得する。
/// これによりメモリ消費を frame data 1枚分に抑える。
final class AnimatedImageSource {
    let source: CGImageSource
    let frameCount: Int
    let frameDelays: [Double]  // 各フレーム遅延（秒）
    let totalDuration: Double
    let pixelSize: CGSize      // 1枚目のピクセルサイズ
    let rawData: Data          // 原データ（MP4 変換時に使用）

    /// libwebp 並列デコーダ。WebP かつ全フレーム独立の場合のみ non-nil。
    /// 利用可能なら CGImageSource (内部ロックでシリアライズ) ではなくこちらで並列 decode。
    #if canImport(libwebp)
    let libwebpDecoder: WebPParallelDecoder?
    #endif

    /// フレームキャッシュ（自前Dictionary管理でiOSメモリ圧迫でのevictを回避）
    private var frameCache: [Int: CGImage] = [:]
    private let cacheLock = NSLock()
    /// プリフェッチ済み判定
    private var prefetchedMaxPixelSize: CGFloat = 0
    private(set) var isPrefetching: Bool = false
    private(set) var prefetchCompleted: Bool = false

    private init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return nil }

        var delays: [Double] = []
        delays.reserveCapacity(count)
        var total: Double = 0
        for i in 0..<count {
            let d = Self.frameDelay(source: src, index: i)
            delays.append(d)
            total += d
        }
        if total <= 0 {
            delays = Array(repeating: 0.1, count: count)
            total = Double(count) * 0.1
        }

        guard let firstCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        self.source = src
        self.frameCount = count
        self.frameDelays = delays
        self.totalDuration = total
        self.pixelSize = CGSize(width: firstCG.width, height: firstCG.height)
        self.rawData = data

        #if canImport(libwebp)
        // libwebp 並列デコーダを同時構築 (WebP かつ全 frame 独立時のみ有効)
        if let decoder = WebPParallelDecoder(data: data), decoder.isFullyIndependent {
            self.libwebpDecoder = decoder
            LogManager.shared.log("Anim", "libwebp parallel decoder ready frames=\(decoder.frameCount) canvas=\(decoder.canvasWidth)x\(decoder.canvasHeight)")
        } else {
            self.libwebpDecoder = nil
        }
        #endif
    }

    /// データからソース構築。非アニメまたは失敗時は nil
    static func make(data: Data) -> AnimatedImageSource? {
        guard let s = AnimatedImageSource(data: data) else { return nil }
        #if canImport(UIKit)
        AnimatedImageSourceRegistry.shared.register(s)
        #endif
        return s
    }

    deinit {
        #if canImport(UIKit)
        AnimatedImageSourceRegistry.shared.unregister(self)
        #endif
        LogManager.shared.log("Mem", "AnimatedImageSource deinit (rawData=\(rawData.count)B)")
    }

    /// 経過時間からフレーム index を決定
    func frameIndex(at elapsed: Double) -> Int {
        guard totalDuration > 0 else { return 0 }
        var t = elapsed.truncatingRemainder(dividingBy: totalDuration)
        if t < 0 { t += totalDuration }
        var acc: Double = 0
        for i in 0..<frameCount {
            acc += frameDelays[i]
            if t < acc { return i }
        }
        return frameCount - 1
    }

    #if canImport(UIKit)
    /// 全フレームを UIImage.animatedImage として生成（UIImageView.startAnimating で再生可能）
    /// 呼び出しは background queue で。
    /// - boomerang: true なら ping-pong 順 (f0..fN-1, fN-2..f1)。ただし frameCount > maxFramesForBoomerang
    ///   のときはメモリ爆発回避のため自動で false に降格しログ。
    /// - hdrEnabled: true なら各フレームに HDREnhancer.enhanceCG を通す (MP4 経路の HDR 補正を per-frame で代替)。
    /// - maxFramesForBoomerang: Boomerang 拡張を許す上限フレーム数 (デフォルト 200)。
    func buildAnimatedImage(maxPixelSize: CGFloat,
                            boomerang: Bool = false,
                            hdrEnabled: Bool = false,
                            maxFramesForBoomerang: Int = 200) -> UIImage? {
        // 安全装置: 巨大 frameCount の boomerang は pingpong で ~2x UIImage を抱えるため降格
        var effectiveBoomerang = boomerang
        if boomerang && frameCount > maxFramesForBoomerang {
            effectiveBoomerang = false
            LogManager.shared.log("Anim", "boomerang降格 frameCount=\(frameCount) > cap=\(maxFramesForBoomerang)")
        }

        var frames: [UIImage] = []
        if effectiveBoomerang && frameCount >= 3 {
            frames.reserveCapacity(frameCount * 2 - 2)
        } else {
            frames.reserveCapacity(frameCount)
        }

        @inline(__always)
        func processed(_ cg: CGImage) -> UIImage {
            if hdrEnabled, let enhanced = HDREnhancer.enhanceCG(cg) {
                return UIImage(cgImage: enhanced)
            }
            return UIImage(cgImage: cg)
        }

        // 順方向
        for i in 0..<frameCount {
            if let cg = frame(at: i, maxPixelSize: maxPixelSize) {
                frames.append(processed(cg))
            }
        }
        var duration = totalDuration
        // 逆方向 (ping-pong 末尾): 最終と先頭を除外して重複フレームを避ける
        if effectiveBoomerang && frameCount >= 3 {
            for i in stride(from: frameCount - 2, through: 1, by: -1) {
                if let cg = frame(at: i, maxPixelSize: maxPixelSize) {
                    frames.append(processed(cg))
                    duration += frameDelays[i]
                }
            }
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
    #endif

    /// メモリ警告時にフレームキャッシュを解放。次回フレーム要求時に再 decode される。
    func dropFrameCache() {
        cacheLock.lock()
        let n = frameCache.count
        frameCache.removeAll()
        prefetchedMaxPixelSize = 0
        prefetchCompleted = false
        cacheLock.unlock()
        LogManager.shared.log("Mem", "AnimatedImageSource dropFrameCache dropped=\(n)")
    }

    /// 全フレームを指定サイズで事前 decode してキャッシュ構築。
    /// concurrentPerform で CPU core 並列 decode
    /// 呼び出しは background queue で。同じ maxPixelSize で複数回呼ばれても2回目以降スキップ。
    func prefetchAllFrames(maxPixelSize: CGFloat) {
        cacheLock.lock()
        if prefetchedMaxPixelSize == maxPixelSize { cacheLock.unlock(); return }
        prefetchedMaxPixelSize = maxPixelSize
        isPrefetching = true
        prefetchCompleted = false
        frameCache.removeAll()
        cacheLock.unlock()

        let count = frameCount
        DispatchQueue.concurrentPerform(iterations: count) { i in
            guard let cg = decodeFrame(index: i, maxPixelSize: maxPixelSize) else { return }
            cacheLock.lock()
            frameCache[i] = cg
            cacheLock.unlock()
        }

        cacheLock.lock()
        isPrefetching = false
        prefetchCompleted = true
        cacheLock.unlock()
    }

    /// CGImage を GPU (CIContext + Metal Lanczos) でダウンスケールする。
    /// CGContext.draw + .medium は CPU 単スレッドで ~30ms/frame のボトルネックだったため、
    /// Metal GPU にオフロードして ~5ms/frame へ短縮。concurrentPerform の並列性も活きる。
    private static let scaleContext: CIContext = {
        let options: [CIContextOption: Any] = [.useSoftwareRenderer: false]
        return CIContext(options: options)
    }()

    private static func scaleCGImage(_ cg: CGImage, maxPixelSize: CGFloat) -> CGImage? {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let longer = max(w, h)
        guard longer > maxPixelSize else { return cg }
        let scale = maxPixelSize / longer

        let ciImage = CIImage(cgImage: cg)
        // Lanczos: 高画質 downscale。filter を毎回生成しても CIContext は共有なので軽い。
        let filter = CIFilter(name: "CILanczosScaleTransform")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(scale, forKey: kCIInputScaleKey)
        filter?.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter?.outputImage else { return nil }
        return scaleContext.createCGImage(output, from: output.extent)
    }

    /// 指定 index 集合だけ残して他を evict (ローリング窓 prefetch 用)。
    func retainOnly(indices: Set<Int>) {
        cacheLock.lock()
        let before = frameCache.count
        frameCache = frameCache.filter { indices.contains($0.key) }
        let after = frameCache.count
        cacheLock.unlock()
        if before - after > 0 {
            // evict があった時だけログ (スパム防止)
            LogManager.shared.log("Mem", "retainOnly evicted=\(before - after) kept=\(after)")
        }
    }

    /// 並列デコード用の per-thread CGImageSource プール。
    /// CGImageSource は内部ロックでシリアライズされるため、スレッド毎に
    /// 独立したインスタンスを持つことで真の並列デコードを実現する。
    private var sourcePool: [CGImageSource] = []
    private let sourcePoolLock = NSLock()

    /// 並列デコード用に source を 1 本貸し出す。
    /// 使用後は returnSource で戻す。pool 空なら新規作成。
    private func borrowSource() -> CGImageSource {
        sourcePoolLock.lock()
        if let last = sourcePool.popLast() {
            sourcePoolLock.unlock()
            return last
        }
        sourcePoolLock.unlock()
        // 新規に raw Data から CGImageSource を作る (同じ data を参照するだけなので軽い)
        return CGImageSourceCreateWithData(rawData as CFData, nil) ?? source
    }

    private func returnSource(_ src: CGImageSource) {
        sourcePoolLock.lock()
        // pool に最大 16 本までプールする (過剰確保を避ける)
        if sourcePool.count < 16 {
            sourcePool.append(src)
        }
        sourcePoolLock.unlock()
    }

    /// 並列デコード用。cache miss なら以下の優先順で decode:
    /// 1. libwebp 並列デコーダ (真の並列、フル解像度)
    /// 2. borrowSource で独立 CGImageSource (フォールバック)
    /// cache hit ならロックなしで即返す。
    func parallelFrame(at index: Int, maxPixelSize: CGFloat?) -> CGImage? {
        let clamped = max(0, min(index, frameCount - 1))
        cacheLock.lock()
        if let cg = frameCache[clamped] { cacheLock.unlock(); return cg }
        cacheLock.unlock()

        var decoded: CGImage?
        #if canImport(libwebp)
        // libwebp 経路: スレッド安全、内部ロックなし、真の並列 decode。
        // platform 分岐:
        // - Mac Catalyst: フル canvas decode (GPU が aspect fit で描画時縮小、CPU 負荷最小)
        // - iPhone / iPad: WebPDecoderConfig.use_scaling で libwebp 内でダウンスケール
        //   (post-scale 不要、出力 Data 小さく、allocator pressure 軽減)。
        // この分岐がないと Mac で libwebp スケーリング CPU コスト増 + Data copy 増で
        // CPU 使用率が逆に上がる。
        if let decoder = libwebpDecoder, clamped < decoder.frames.count {
            let info = decoder.frames[clamped]
            #if targetEnvironment(macCatalyst)
            // 2026-04-25 改訂: Mac Catalyst で canvas > 1800 の大型 WebP は per-frame 25MB 超の
            // BGRA が memory bandwidth を飽和させて decode + HDR が予算超過。libwebp native scaling
            // で 1200 にダウンスケール → per-frame ~8.6MB, 3x memory bandwidth 削減。
            // 以前 CGContext scale で試して失敗 (CPU 重い) したが、libwebp 内スケーリングは別経路。
            // 中小 canvas (≤ 1800) は従来通りフル decode で GPU aspect fit に任せる。
            let canvasLonger = max(decoder.canvasWidth, decoder.canvasHeight)
            if canvasLonger > 1800 {
                if let (bgra, w, h) = decoder.decodeFrameScaled(info, maxPixelSize: 1200),
                   let cg = decoder.makeCGImage(from: bgra, width: w, height: h) {
                    decoded = cg
                }
            } else {
                if let bgra = decoder.decodeFrame(info),
                   let cg = decoder.makeCGImage(from: bgra) {
                    decoded = cg
                }
            }
            #else
            let cap = maxPixelSize.map { Int($0) } ?? max(decoder.canvasWidth, decoder.canvasHeight)
            if let (bgra, w, h) = decoder.decodeFrameScaled(info, maxPixelSize: cap),
               let cg = decoder.makeCGImage(from: bgra, width: w, height: h) {
                decoded = cg
            }
            #endif
        }
        #endif
        if decoded == nil {
            // CGImageSource フォールバック
            let src = borrowSource()
            if let maxPixelSize, maxPixelSize > 0 {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ]
                decoded = CGImageSourceCreateThumbnailAtIndex(src, clamped, opts as CFDictionary)
            } else {
                decoded = CGImageSourceCreateImageAtIndex(src, clamped, nil)
            }
            returnSource(src)
        }
        guard let decoded else { return nil }
        cacheLock.lock()
        frameCache[clamped] = decoded
        cacheLock.unlock()
        return decoded
    }

    /// キャッシュ済みフレームのみ返す（decodeしない）。tick再生用。
    func cachedFrame(at index: Int) -> CGImage? {
        let clamped = max(0, min(index, frameCount - 1))
        cacheLock.lock()
        let cg = frameCache[clamped]
        cacheLock.unlock()
        return cg
    }

    /// 指定 index のフレームを decode（キャッシュあり、cache更新あり）
    func frame(at index: Int, maxPixelSize: CGFloat? = nil) -> CGImage? {
        let clamped = max(0, min(index, frameCount - 1))
        cacheLock.lock()
        if let cg = frameCache[clamped] { cacheLock.unlock(); return cg }
        cacheLock.unlock()

        guard let decoded = decodeFrame(index: clamped, maxPixelSize: maxPixelSize) else { return nil }
        cacheLock.lock()
        frameCache[clamped] = decoded
        cacheLock.unlock()
        return decoded
    }

    private func decodeFrame(index: Int, maxPixelSize: CGFloat?) -> CGImage? {
        if let maxPixelSize, maxPixelSize > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, index, opts as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        if let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let d = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, d > 0 { return d }
            if let d = gif[kCGImagePropertyGIFDelayTime] as? Double, d > 0 { return d }
        }
        if let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let d = webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double, d > 0 { return d }
            if let d = webp[kCGImagePropertyWebPDelayTime] as? Double, d > 0 { return d }
        }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let d = png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double, d > 0 { return d }
            if let d = png[kCGImagePropertyAPNGDelayTime] as? Double, d > 0 { return d }
        }
        return 0.1
    }
}

/// アニメ画像の判定ユーティリティ
enum AnimatedImageDecoder {
    /// CGImageSourceで2フレーム以上ならアニメ扱い
    static func isAnimated(data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// URL 版（ディスク mmap 経由、メモリ負荷軽い）
    static func isAnimatedFile(url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }
}
