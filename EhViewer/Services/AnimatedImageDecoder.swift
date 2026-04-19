import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
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
    }

    /// データからソース構築。非アニメまたは失敗時は nil
    static func make(data: Data) -> AnimatedImageSource? {
        AnimatedImageSource(data: data)
    }

    deinit {
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
    func buildAnimatedImage(maxPixelSize: CGFloat) -> UIImage? {
        var frames: [UIImage] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            if let cg = frame(at: i, maxPixelSize: maxPixelSize) {
                frames.append(UIImage(cgImage: cg))
            }
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: totalDuration)
    }
    #endif

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
