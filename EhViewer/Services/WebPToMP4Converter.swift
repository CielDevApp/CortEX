import Foundation
import AVFoundation
import VideoToolbox
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

    /// ディスク上の WebP/GIF ファイルを直接読んで MP4 変換（メモリに全データ展開しない）
    /// maxPixelSize: nil = 標準画質（720）、大きい値 = オリジナル画質（縮小なし）
    static func convert(
        sourceURL: URL,
        outputURL: URL,
        maxPixelSize: CGFloat? = nil,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
        // 同時変換1本に絞る: 2ページ目開始時のOOM回避
        await Self.concurrencyLimit.wait()
        defer { Self.concurrencyLimit.signal() }

        let effectiveMaxDim = maxPixelSize ?? Self.maxOutputPixelSize
        let isOriginal = (maxPixelSize ?? 0) > 1400

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? 0
        LogManager.shared.log("Convert", "start mem=\(memoryFootprintMB())MB src=\(fileSize)B → \(outputURL.lastPathComponent) original=\(isOriginal)")
        // URL ベースで CGImageSource 作成 → ImageIO が必要時だけディスク読み
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
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

        // 1枚目 decode して出力サイズ決定
        let t0 = CFAbsoluteTimeGetCurrent()
        let firstDecoded: CGImage? = isOriginal
            ? CGImageSourceCreateImageAtIndex(source, 0, nil)
            : decodeThumb(source: source, index: 0, maxPixelSize: effectiveMaxDim)
        guard let first = firstDecoded else {
            LogManager.shared.log("Convert", "FAILED first frame decode")
            throw ConverterError.decodeFailed
        }
        let width = first.width
        let height = first.height
        guard width > 0, height > 0 else { throw ConverterError.decodeFailed }
        LogManager.shared.log("Convert", "first decode \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms size=\(width)x\(height)")

        // VTCompressionSession: HW encoder 強制（HEVC）
        // AVAssetWriter は mp4 コンテナ書き出しにのみ使用（encoding は VT 側）
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // passthrough 入力には sourceFormatHint が必要（仮の HEVC format を事前作成）
        var formatDescOpt: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDescOpt
        )
        guard fdStatus == noErr, let formatDesc = formatDescOpt else {
            LogManager.shared.log("Convert", "FAILED formatDesc create status=\(fdStatus)")
            throw ConverterError.writerCannotAdd
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDesc)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ConverterError.writerCannotAdd }
        writer.add(input)

        // VT callback context（Unmanaged 経由で refCon に持たせる）
        final class VTContext {
            let input: AVAssetWriterInput
            let writer: AVAssetWriter
            var firstBufferHandled: Bool = false
            var error: String?
            init(input: AVAssetWriterInput, writer: AVAssetWriter) {
                self.input = input
                self.writer = writer
            }
        }
        let vtContext = VTContext(input: input, writer: writer)
        let refCon = Unmanaged.passUnretained(vtContext).toOpaque()

        let vtCallback: VTCompressionOutputCallback = { (outRefCon, _, status, _, sampleBuffer) in
            guard status == noErr, let sampleBuffer, let outRefCon else {
                if let outRefCon {
                    let ctx = Unmanaged<VTContext>.fromOpaque(outRefCon).takeUnretainedValue()
                    ctx.error = "VT status=\(status)"
                }
                return
            }
            let ctx = Unmanaged<VTContext>.fromOpaque(outRefCon).takeUnretainedValue()
            // 最初の sampleBuffer が来たタイミングで writer startSession
            if !ctx.firstBufferHandled {
                ctx.firstBufferHandled = true
                if ctx.writer.status == .unknown {
                    if !ctx.writer.startWriting() {
                        ctx.error = "writer.startWriting failed"
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    ctx.writer.startSession(atSourceTime: pts)
                }
            }
            // 同期wait（expectsMediaDataInRealTime=false なのでブロック可）
            while !ctx.input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            if !ctx.input.append(sampleBuffer) {
                ctx.error = ctx.writer.error?.localizedDescription ?? "append failed"
            }
        }

        var vtSessionOut: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: vtCallback,
            refcon: refCon,
            compressionSessionOut: &vtSessionOut
        )
        guard createStatus == noErr, let vtSession = vtSessionOut else {
            LogManager.shared.log("Convert", "FAILED VT session create status=\(createStatus)")
            throw ConverterError.writerStartFailed("VT session create \(createStatus)")
        }

        // HW 確認ログ
        var hwAcceleratedCF: CFBoolean?
        VTSessionCopyProperty(vtSession,
                              key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil,
                              valueOut: &hwAcceleratedCF)
        let hwOK = (hwAcceleratedCF == kCFBooleanTrue)
        LogManager.shared.log("Convert", "VT session created HW=\(hwOK)")

        // プロパティ設定
        let bitrate = bitrateFor(width: width, height: height)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 30))
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(vtSession)

        // --- Pipeline: bounded decode + 並行append ---
        // 同時保持 8 frame → 540x790x4 * 8 ≈ 14MB + overhead でメモリピーク抑制
        let lock = NSLock()
        nonisolated(unsafe) var frames = [CGImage?](repeating: nil, count: frameCount)
        frames[0] = first
        // オリジナル画質時は buffer 減らしてメモリ抑制
        let bufferLimit = isOriginal ? 4 : 8
        let bufferSem = DispatchSemaphore(value: bufferLimit - 1)

        let maxDim = effectiveMaxDim
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
                let capturedURL = sourceURL
                decodeQueue.async {
                    defer { decodeGroup.leave() }
                    autoreleasepool {
                        // 各ワーカー独立 URL source（mmap + 内部lock回避）
                        guard let workerSrc = CGImageSourceCreateWithURL(capturedURL as CFURL, nil) else { return }
                        let img = decodeThumb(source: workerSrc, index: i, maxPixelSize: maxDim)
                        lock.lock()
                        frames[i] = img
                        lock.unlock()
                    }
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

            let delayMs = Int64(delays[i] * 1000)
            let pts = CMTime(value: accumulatedMs, timescale: timeScale)
            let dur = CMTime(value: max(delayMs, 10), timescale: timeScale)
            accumulatedMs += max(delayMs, 10)

            guard let cgImage = cg, let pb = makeStandalonePixelBuffer(cgImage: cgImage, width: width, height: height) else {
                VTCompressionSessionInvalidate(vtSession)
                input.markAsFinished()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                LogManager.shared.log("Convert", "FAILED pixelBuffer at frame \(i)")
                throw ConverterError.pixelBufferFailed
            }
            let encStatus = VTCompressionSessionEncodeFrame(
                vtSession,
                imageBuffer: pb,
                presentationTimeStamp: pts,
                duration: dur,
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            if encStatus != noErr {
                VTCompressionSessionInvalidate(vtSession)
                input.markAsFinished()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                LogManager.shared.log("Convert", "FAILED VT encode at frame \(i) status=\(encStatus)")
                throw ConverterError.appendFailed("VT encode \(encStatus)")
            }
            if let err = vtContext.error {
                VTCompressionSessionInvalidate(vtSession)
                input.markAsFinished()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                LogManager.shared.log("Convert", "FAILED callback \(err)")
                throw ConverterError.appendFailed(err)
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
        // VT 残りフレームを flush
        VTCompressionSessionCompleteFrames(vtSession, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(vtSession)
        LogManager.shared.log("Convert", "pipeline done \(Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000))ms")

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            LogManager.shared.log("Convert", "FAILED finish: \(writer.error?.localizedDescription ?? "unknown")")
            try? FileManager.default.removeItem(at: outputURL)  // ゴミファイル削除
            throw ConverterError.finishFailed(writer.error?.localizedDescription ?? "unknown")
        }
        let outFileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        // 出力サイズ検証: 10KB 未満は破損扱い → .ok 作らずエラー
        if outFileSize < 10_000 {
            try? FileManager.default.removeItem(at: outputURL)
            LogManager.shared.log("Convert", "FAILED output too small: \(outFileSize)B")
            throw ConverterError.finishFailed("output too small: \(outFileSize)B")
        }
        FileManager.default.createFile(atPath: Self.okMarkerURL(for: outputURL).path, contents: Data())
        LogManager.shared.log("Convert", "DONE total=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms mp4=\(outFileSize)B mem=\(memoryFootprintMB())MB")

        // 完了後のメモリ推移を記録（落ちる前に捕獲）
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            LogManager.shared.log("Mem", "convert+500ms: \(memoryFootprintMB())MB")
            try? await Task.sleep(nanoseconds: 500_000_000)
            LogManager.shared.log("Mem", "convert+1s: \(memoryFootprintMB())MB")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            LogManager.shared.log("Mem", "convert+3s: \(memoryFootprintMB())MB")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            LogManager.shared.log("Mem", "convert+5s: \(memoryFootprintMB())MB")
        }
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

    /// pool なしで CVPixelBuffer 作成（VTCompressionSession 用）
    private static func makeStandalonePixelBuffer(cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return nil }
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
