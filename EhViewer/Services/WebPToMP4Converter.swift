import Foundation
import AVFoundation
import ImageIO
import Darwin
#if canImport(UIKit)
import UIKit

/// 現プロセスのメモリ使用量(MB)
private func memoryFootprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : -1
}

/// アニメ WebP / GIF / APNG を MP4 (H.264) に変換。
/// decode はマルチコア並列、append は sequential、メモリピーク抑制のため縮小 decode。
enum WebPToMP4Converter {
    /// 変換済み MP4 の保存先ディレクトリ（Documents/animated_cache/）
    static var cacheDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("animated_cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func mp4Path(gid: Int, page: Int) -> URL {
        cacheDir.appendingPathComponent("\(gid)_\(String(format: "%04d", page)).mp4")
    }

    static func isConverted(gid: Int, page: Int) -> Bool {
        FileManager.default.fileExists(atPath: mp4Path(gid: gid, page: page).path)
    }

    /// 出力の最大長辺ピクセル数（メモリ優先、画質は妥協）
    static var maxOutputPixelSize: CGFloat = 540

    /// 同時変換数制限（OOM 回避）: 1ページずつ順次
    private static let concurrencyLimit = AsyncSemaphore(limit: 1)

    /// 変換成功マーカー（.ok ファイル存在で成功判定）
    static func okMarkerURL(for mp4URL: URL) -> URL {
        mp4URL.appendingPathExtension("ok")
    }

    /// 完全な変換済み（mp4 + .ok 両方存在）
    static func isFullyConverted(gid: Int, page: Int) -> Bool {
        let mp4 = mp4Path(gid: gid, page: page)
        let ok = okMarkerURL(for: mp4)
        return FileManager.default.fileExists(atPath: mp4.path)
            && FileManager.default.fileExists(atPath: ok.path)
    }

    /// ゴミ掃除: .ok が無ければ mp4 削除
    static func cleanupStaleIfNeeded(gid: Int, page: Int) {
        let mp4 = mp4Path(gid: gid, page: page)
        let ok = okMarkerURL(for: mp4)
        if FileManager.default.fileExists(atPath: mp4.path)
            && !FileManager.default.fileExists(atPath: ok.path) {
            try? FileManager.default.removeItem(at: mp4)
        }
    }

    static func convert(
        data: Data,
        outputURL: URL,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
        // 同時変換1本に絞る: 2ページ目開始時のOOM回避
        await Self.concurrencyLimit.wait()
        defer { Self.concurrencyLimit.signal() }

        LogManager.shared.log("Convert", "start mem=\(memoryFootprintMB())MB dataSize=\(data.count)B → \(outputURL.lastPathComponent)")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            LogManager.shared.log("Convert", "FAILED invalidSource")
            throw ConverterError.invalidSource
        }
        let frameCount = CGImageSourceGetCount(source)
        LogManager.shared.log("Convert", "frameCount=\(frameCount)")
        guard frameCount > 1 else { throw ConverterError.notAnimated }

        // mp4 と .ok 両方クリア
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: Self.okMarkerURL(for: outputURL))

        let delays = extractDelays(source: source, frameCount: frameCount)

        // 1枚目を縮小 decode して出力サイズ決定
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let first = decodeThumb(source: source, index: 0, maxPixelSize: Self.maxOutputPixelSize) else {
            LogManager.shared.log("Convert", "FAILED first frame decode")
            throw ConverterError.decodeFailed
        }
        let width = first.width
        let height = first.height
        guard width > 0, height > 0 else { throw ConverterError.decodeFailed }
        LogManager.shared.log("Convert", "first decode \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms size=\(width)x\(height)")

        // AVAssetWriter セットアップ
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrateFor(width: width, height: height),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttrs
        )
        guard writer.canAdd(input) else { throw ConverterError.writerCannotAdd }
        writer.add(input)

        guard writer.startWriting() else {
            throw ConverterError.writerStartFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        // --- Pipeline: bounded decode + 並行append ---
        // 同時保持 8 frame → 540x790x4 * 8 ≈ 14MB + overhead でメモリピーク抑制
        let lock = NSLock()
        nonisolated(unsafe) var frames = [CGImage?](repeating: nil, count: frameCount)
        frames[0] = first
        let bufferLimit = 8
        let bufferSem = DispatchSemaphore(value: bufferLimit - 1)  // first 使用済み

        let maxDim = Self.maxOutputPixelSize
        let totalForProgress = frameCount
        let decodeStart = CFAbsoluteTimeGetCurrent()
        LogManager.shared.log("Convert", "decode+append pipeline start (buffer=\(bufferLimit))")

        // decode dispatcher: buffer 空きを待って decode 起動
        let decodeQueue = DispatchQueue(label: "webp.decode", qos: .userInitiated, attributes: .concurrent)
        let decodeGroup = DispatchGroup()
        let decodeTask = Task.detached(priority: .userInitiated) {
            for i in 1..<frameCount {
                bufferSem.wait()  // slot 空くまで待つ
                decodeGroup.enter()
                decodeQueue.async {
                    defer { decodeGroup.leave() }
                    guard let workerSrc = CGImageSourceCreateWithData(data as CFData, nil) else { return }
                    let img = decodeThumb(source: workerSrc, index: i, maxPixelSize: maxDim)
                    lock.lock()
                    frames[i] = img
                    lock.unlock()
                }
            }
            decodeGroup.wait()
        }

        // append ループ: frames[i] 埋まり次第処理、nil にしたら bufferSem.signal
        var accumulatedMs: Int64 = 0
        let timeScale: CMTimeScale = 1000
        var lastProgressReported = 0

        for i in 0..<frameCount {
            var cg: CGImage? = nil
            while cg == nil {
                lock.lock()
                cg = frames[i]
                if cg != nil { frames[i] = nil }
                lock.unlock()
                if cg == nil {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            // i=0 は first なので signal しない（事前に slot 1つ使用済み扱いにした）
            if i > 0 { bufferSem.signal() }

            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }

            let delayMs = Int64(delays[i] * 1000)
            let pts = CMTime(value: accumulatedMs, timescale: timeScale)
            accumulatedMs += max(delayMs, 10)

            guard let cgImage = cg,
                  let pool = adaptor.pixelBufferPool,
                  let pb = makePixelBuffer(cgImage: cgImage, pool: pool, width: width, height: height) else {
                input.markAsFinished()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                LogManager.shared.log("Convert", "FAILED pixelBuffer at frame \(i)")
                throw ConverterError.pixelBufferFailed
            }
            if !adaptor.append(pb, withPresentationTime: pts) {
                input.markAsFinished()
                let msg = writer.error?.localizedDescription ?? "unknown"
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                LogManager.shared.log("Convert", "FAILED append at frame \(i): \(msg)")
                throw ConverterError.appendFailed(msg)
            }

            if let progress {
                let percent = Int(Double(i + 1) / Double(totalForProgress) * 100)
                if percent / 10 != lastProgressReported / 10 {
                    lastProgressReported = percent
                    let p = Double(i + 1) / Double(totalForProgress)
                    await MainActor.run { progress(p) }
                }
            }
        }

        await decodeTask.value
        LogManager.shared.log("Convert", "pipeline done \(Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000))ms")

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            LogManager.shared.log("Convert", "FAILED finish: \(writer.error?.localizedDescription ?? "unknown")")
            try? FileManager.default.removeItem(at: outputURL)  // ゴミファイル削除
            throw ConverterError.finishFailed(writer.error?.localizedDescription ?? "unknown")
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        // 成功マーカー作成
        FileManager.default.createFile(atPath: Self.okMarkerURL(for: outputURL).path, contents: Data())
        LogManager.shared.log("Convert", "DONE total=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms mp4=\(fileSize)B mem=\(memoryFootprintMB())MB")
    }

    // MARK: - Helpers

    private static func bitrateFor(width: Int, height: Int) -> Int {
        let pixels = width * height
        if pixels > 1_500_000 { return 6_000_000 }
        if pixels > 800_000 { return 4_000_000 }
        return 2_500_000
    }

    private static func extractDelays(source: CGImageSource, frameCount: Int) -> [Double] {
        var delays: [Double] = []
        delays.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            delays.append(frameDelay(source: source, index: i))
        }
        return delays
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.04
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
        return 0.04
    }

    /// ImageIO の thumbnail decoder で縮小 decode
    private static func decodeThumb(source: CGImageSource, index: Int, maxPixelSize: CGFloat) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, opts as CFDictionary)
    }

    private static func makePixelBuffer(cgImage: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pixelBuffer = pb else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: baseAddr,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    enum ConverterError: Error {
        case invalidSource
        case notAnimated
        case decodeFailed
        case writerCannotAdd
        case writerStartFailed(String)
        case pixelBufferFailed
        case appendFailed(String)
        case finishFailed(String)
    }
}
#endif
