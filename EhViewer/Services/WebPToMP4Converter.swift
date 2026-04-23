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

    /// 完全な変換済み（mp4 + .ok 両方存在 + サイズ 10KB 以上）
    /// サイズ検査は race condition / 過去残骸で残った 0B mp4 を誤認しないため。
    static func isFullyConverted(gid: Int, page: Int) -> Bool {
        let mp4 = mp4Path(gid: gid, page: page)
        let ok = okMarkerURL(for: mp4)
        guard FileManager.default.fileExists(atPath: mp4.path),
              FileManager.default.fileExists(atPath: ok.path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as? Int) ?? 0
        return size >= 10_000
    }

    /// ゴミ掃除: .ok 無し or サイズ 10KB 未満の mp4 を削除（.ok も道連れ）
    static func cleanupStaleIfNeeded(gid: Int, page: Int) {
        let mp4 = mp4Path(gid: gid, page: page)
        let ok = okMarkerURL(for: mp4)
        guard FileManager.default.fileExists(atPath: mp4.path) else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as? Int) ?? 0
        let okExists = FileManager.default.fileExists(atPath: ok.path)
        if !okExists || size < 10_000 {
            LogManager.shared.log("Convert", "cleanup stale mp4 gid=\(gid) page=\(page) size=\(size)B ok=\(okExists)")
            try? FileManager.default.removeItem(at: mp4)
            try? FileManager.default.removeItem(at: ok)
        }
    }

    /// 変換済みMP4キャッシュのサイズ (bytes)
    static func animatedCacheSize() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else {
            return 0
        }
        var total: Int64 = 0
        for name in contents {
            let path = cacheDir.appendingPathComponent(name).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// 変換済みMP4キャッシュを全削除（リーダー初回表示時に再変換が走る）
    static func clearAnimatedCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        // 再作成（以降の cacheDir アクセスでエラー回避）
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// 肥大化防止: 起動時にキャッシュサイズ上限を超えてたら古いものから削除 (LRU)
    /// 判定: contentAccessDate (最終アクセス) 昇順で削除、上限以下まで縮小
    /// 目安値 500MB: アニメ WebP 数十〜100件分のキャッシュ相当
    static func enforceCacheCap(maxBytes: Int64 = 500 * 1024 * 1024) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        ) else { return }
        // mp4 本体だけ計上 (.ok マーカーは本体に追従削除)
        struct Entry {
            let url: URL
            let size: Int64
            let lastAccess: Date
        }
        var entries: [Entry] = []
        var total: Int64 = 0
        for url in urls where url.pathExtension.lowercased() == "mp4" {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey])
            let size = Int64(vals?.fileSize ?? 0)
            let access = vals?.contentAccessDate ?? vals?.contentModificationDate ?? Date.distantPast
            entries.append(Entry(url: url, size: size, lastAccess: access))
            total += size
        }
        guard total > maxBytes else { return }

        let sorted = entries.sorted { $0.lastAccess < $1.lastAccess }
        var removed = 0
        var freed: Int64 = 0
        for e in sorted {
            if total <= maxBytes { break }
            try? fm.removeItem(at: e.url)
            // 道連れの .ok マーカー
            let ok = e.url.appendingPathExtension("ok")
            try? fm.removeItem(at: ok)
            total -= e.size
            freed += e.size
            removed += 1
        }
        LogManager.shared.log(
            "Convert",
            "enforceCacheCap: removed \(removed) files, freed \(freed / 1024 / 1024)MB, now \(total / 1024 / 1024)MB"
        )
    }

    /// ディスク上の WebP/GIF ファイルを直接読んで MP4 変換（メモリに全データ展開しない）
    /// maxPixelSize: nil = 標準画質（720）、大きい値 = オリジナル画質（縮小なし）
    /// libwebp 利用可能 + アニメWebP なら高速 decode 経路へ分岐
    /// frameCallback: ストリーミング再生用。decode 成功ごとにフレームを UI に転送する
    static func convert(
        sourceURL: URL,
        outputURL: URL,
        maxPixelSize: CGFloat? = nil,
        progress: (@MainActor (Double) -> Void)? = nil,
        frameCallback: (@Sendable (CGImage) -> Void)? = nil
    ) async throws {
        // 同時変換1本に絞る: 2ページ目開始時のOOM回避
        await Self.concurrencyLimit.wait()
        defer { Self.concurrencyLimit.signal() }

        // キュー待ち中に表示から消えた（ユーザが素早くスワイプ等）場合は変換を放棄
        // → 100ページの動画作品を一気にスクロールしても queue が詰まらない
        try Task.checkCancellation()

        // 診断: libwebp 利用可否 + WebP 検知結果を明示ログ
        let libwebpAvailable = WebPLibSupport.isAvailable
        let isAnimatedWebP = WebPFileDetector.isAnimatedWebP(url: sourceURL)
        LogManager.shared.log("Convert", "dispatch: libwebpAvailable=\(libwebpAvailable) isAnimatedWebP=\(isAnimatedWebP) file=\(sourceURL.lastPathComponent)")

        // libwebp が利用可能 + アニメWebP → 高速経路
        #if canImport(libwebp)
        if isAnimatedWebP {
            try await convertAnimatedWebPUsingLibWebP(
                sourceURL: sourceURL,
                outputURL: outputURL,
                maxPixelSize: maxPixelSize,
                progress: progress,
                frameCallback: frameCallback
            )
            return
        }
        #endif

        try await convertUsingCGImageSource(
            sourceURL: sourceURL,
            outputURL: outputURL,
            maxPixelSize: maxPixelSize,
            progress: progress
        )
    }

    /// CGImageSource 経由の既存変換経路（GIF/APNG/アニメWebP fallback）
    private static func convertUsingCGImageSource(
        sourceURL: URL,
        outputURL: URL,
        maxPixelSize: CGFloat?,
        progress: (@MainActor (Double) -> Void)?
    ) async throws {
        let effectiveMaxDim = maxPixelSize ?? Self.maxOutputPixelSize
        let isOriginal = (maxPixelSize ?? 0) > 1400

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? 0
        LogManager.shared.log("Convert", "start mem=\(memoryFootprintMB())MB src=\(fileSize)B → \(outputURL.lastPathComponent) original=\(isOriginal) backend=CGImageSource")
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
                if percent != lastProgressReported {
                    lastProgressReported = percent
                    let p = Double(i + 1) / Double(totalForProgress)
                    // await MainActor.run は毎回 suspension + thread hop で重い
                    // fire-and-forget で main queue に投げて即座に次の decode/encode へ
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { progress(p) }
                    }
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

    // MARK: - libwebp 経路

    #if canImport(libwebp)
    /// libwebp の WebPAnimDecoder で高速 decode する変換経路
    /// CGImageSource に比べて WebP アニメの decode が圧倒的に速い（Chromium と同等速度）
    private static func convertAnimatedWebPUsingLibWebP(
        sourceURL: URL,
        outputURL: URL,
        maxPixelSize: CGFloat?,
        progress: (@MainActor (Double) -> Void)?,
        frameCallback: (@Sendable (CGImage) -> Void)? = nil
    ) async throws {
        let effectiveMaxDim = maxPixelSize ?? Self.maxOutputPixelSize
        let isOriginal = (maxPixelSize ?? 0) > 1400

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int) ?? 0
        LogManager.shared.log("Convert", "start mem=\(memoryFootprintMB())MB src=\(fileSize)B → \(outputURL.lastPathComponent) original=\(isOriginal) backend=libwebp")

        // フレームレベル並列 decode の適合判定
        // 全フレームが dispose=NONE / blend=NO_BLEND / full-canvas offset ならフレーム間依存ゼロ
        // → N コア並列で decode 可能（A17 Pro / M系で 4-6倍のスループット期待）
        let parallelDecoder = WebPParallelDecoder(url: sourceURL)
        let useParallel = (parallelDecoder?.isFullyIndependent ?? false)

        // 逐次 fallback 用（並列不適合時のみ init）
        let seqDecoder: WebPAnimatedDecoder?
        let canvasW: Int
        let canvasH: Int
        let frameCount: Int

        if useParallel, let pd = parallelDecoder {
            seqDecoder = nil
            canvasW = pd.canvasWidth
            canvasH = pd.canvasHeight
            frameCount = pd.frameCount
            LogManager.shared.log("Convert", "parallel eligible: frameCount=\(frameCount) canvas=\(canvasW)x\(canvasH) cores=\(ProcessInfo.processInfo.activeProcessorCount)")
        } else {
            guard let d = WebPAnimatedDecoder(url: sourceURL) else {
                LogManager.shared.log("Convert", "FAILED libwebp decoder init")
                throw ConverterError.invalidSource
            }
            seqDecoder = d
            canvasW = d.canvasWidth
            canvasH = d.canvasHeight
            frameCount = d.frameCount
            if parallelDecoder != nil {
                LogManager.shared.log("Convert", "parallel ineligible (non-full-canvas/blend/dispose), seq fallback: frameCount=\(frameCount) canvas=\(canvasW)x\(canvasH)")
            } else {
                LogManager.shared.log("Convert", "seq only (demux failed): frameCount=\(frameCount) canvas=\(canvasW)x\(canvasH)")
            }
        }
        guard frameCount > 1 else { throw ConverterError.notAnimated }

        // mp4 と .ok 両方クリア
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: Self.okMarkerURL(for: outputURL))

        // 出力サイズ決定
        let width: Int
        let height: Int
        if isOriginal {
            width = canvasW
            height = canvasH
        } else {
            let srcW = CGFloat(canvasW)
            let srcH = CGFloat(canvasH)
            let scale = min(effectiveMaxDim / max(srcW, srcH), 1.0)
            width = Int(srcW * scale)
            height = Int(srcH * scale)
        }
        LogManager.shared.log("Convert", "output size=\(width)x\(height)")

        // VTCompressionSession + AVAssetWriter セットアップ（CGImageSource 経路と同じ）
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
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
            throw ConverterError.writerCannotAdd
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDesc)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ConverterError.writerCannotAdd }
        writer.add(input)

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
            throw ConverterError.writerStartFailed("VT session create \(createStatus)")
        }

        var hwAcceleratedCF: CFBoolean?
        VTSessionCopyProperty(vtSession,
                              key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil,
                              valueOut: &hwAcceleratedCF)
        LogManager.shared.log("Convert", "VT session created HW=\(hwAcceleratedCF == kCFBooleanTrue)")

        let bitrate = bitrateFor(width: width, height: height)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 30))
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(vtSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(vtSession)

        // decode → encode ループ
        // 注意: Task.detached でも main に isolation が漏れるケースあり（実測済み isMain=true）
        // → DispatchQueue.global に明示的に逃がして main スレッドを解放する
        // 並列パス: チャンク先読みで N フレーム並列 decode → キャッシュ → 順次 encode
        let t0 = CFAbsoluteTimeGetCurrent()
        let seqDecoderCapture = seqDecoder
        let parallelDecoderCapture = useParallel ? parallelDecoder : nil
        let vtSessionCapture = vtSession
        let vtContextCapture = vtContext
        let widthCapture = width
        let heightCapture = height
        let frameCountCapture = frameCount
        let progressCapture = progress
        let frameCallbackCapture = frameCallback
        let useParallelCapture = useParallel
        let chunkSizeCapture = ProcessInfo.processInfo.activeProcessorCount

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                LogManager.shared.log("Convert", "decode+encode loop start mode=\(useParallelCapture ? "parallel(chunk=\(chunkSizeCapture))" : "sequential") isMain=\(Thread.isMainThread)")
                var accumulatedMs: Int64 = 0
                let timeScale: CMTimeScale = 1000
                var lastProgressReported = 0
                var totalDecodeMs: Double = 0
                var totalEncodeMs: Double = 0

                // 並列 decode キャッシュ（チャンク単位で先読み）
                var decodedChunkStart: Int = -1
                var decodedChunkBGRA: [Data?] = []

                // 1 フレーム取得: 並列なら cache-hit、逐次なら nextFrame()
                func fetchFrame(_ i: Int) -> (image: CGImage, delayMs: Int32, decodeMs: Double)? {
                    if useParallelCapture, let pd = parallelDecoderCapture {
                        // キャッシュ miss なら次チャンクを並列 decode
                        if i < decodedChunkStart || i >= decodedChunkStart + decodedChunkBGRA.count {
                            let start = (i / chunkSizeCapture) * chunkSizeCapture
                            let end = min(start + chunkSizeCapture, frameCountCapture)
                            let cnt = end - start
                            let chunkStart = CFAbsoluteTimeGetCurrent()
                            var outs: [Data?] = Array(repeating: nil, count: cnt)
                            let lock = NSLock()
                            let frames = pd.frames
                            DispatchQueue.concurrentPerform(iterations: cnt) { offset in
                                let d = pd.decodeFrame(frames[start + offset])
                                lock.lock(); outs[offset] = d; lock.unlock()
                            }
                            let chunkMs = (CFAbsoluteTimeGetCurrent() - chunkStart) * 1000
                            LogManager.shared.log("Convert", "parallel chunk[\(start)..<\(end)] decoded in \(Int(chunkMs))ms (\(Int(chunkMs) / max(cnt,1))ms/frame wall, \(cnt) frames / \(chunkSizeCapture) cores)")
                            decodedChunkStart = start
                            decodedChunkBGRA = outs
                            totalDecodeMs += chunkMs
                        }
                        let localIdx = i - decodedChunkStart
                        guard let bgra = decodedChunkBGRA[localIdx],
                              let cg = pd.makeCGImage(from: bgra) else {
                            return nil
                        }
                        // メモリ解放: このフレーム分の BGRA は以降不要
                        decodedChunkBGRA[localIdx] = nil
                        let delay = Int32(max(pd.frames[i].durationMs, 10))
                        return (cg, delay, 0) // 並列 decode の per-frame 計測は chunk 集計に含む
                    } else if let sd = seqDecoderCapture {
                        let t = CFAbsoluteTimeGetCurrent()
                        guard let f = sd.nextFrame() else { return nil }
                        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
                        return (f.image, f.delayMs, ms)
                    }
                    return nil
                }

                for i in 0..<frameCountCapture {
                    do {
                        try autoreleasepool {
                            guard let frame = fetchFrame(i) else {
                                LogManager.shared.log("Convert", "FAILED fetchFrame nil at frame \(i)")
                                throw ConverterError.decodeFailed
                            }
                            if !useParallelCapture { totalDecodeMs += frame.decodeMs }

                            // ストリーミング再生: decode 直後に UI へフレーム転送
                            if let cb = frameCallbackCapture {
                                cb(frame.image)
                            }

                            let pbStart = CFAbsoluteTimeGetCurrent()
                            guard let pb = makeStandalonePixelBuffer(cgImage: frame.image, width: widthCapture, height: heightCapture) else {
                                throw ConverterError.pixelBufferFailed
                            }
                            let pbMs = (CFAbsoluteTimeGetCurrent() - pbStart) * 1000

                            let pts = CMTime(value: accumulatedMs, timescale: timeScale)
                            let dur = CMTime(value: Int64(frame.delayMs), timescale: timeScale)
                            accumulatedMs += Int64(frame.delayMs)

                            let encStart = CFAbsoluteTimeGetCurrent()
                            let encStatus = VTCompressionSessionEncodeFrame(
                                vtSessionCapture,
                                imageBuffer: pb,
                                presentationTimeStamp: pts,
                                duration: dur,
                                frameProperties: nil,
                                sourceFrameRefcon: nil,
                                infoFlagsOut: nil
                            )
                            let encMs = (CFAbsoluteTimeGetCurrent() - encStart) * 1000
                            totalEncodeMs += encMs

                            if i < 3 || i % 10 == 0 || i == frameCountCapture - 1 {
                                LogManager.shared.log("Convert", "frame[\(i)] decode=\(Int(frame.decodeMs))ms pb=\(Int(pbMs))ms enc=\(Int(encMs))ms delay=\(frame.delayMs)ms")
                            }

                            if encStatus != noErr {
                                LogManager.shared.log("Convert", "FAILED libwebp VT encode at frame \(i) status=\(encStatus)")
                                throw ConverterError.appendFailed("VT encode \(encStatus)")
                            }
                            if let err = vtContextCapture.error {
                                throw ConverterError.appendFailed(err)
                            }
                        }
                    } catch {
                        cont.resume(throwing: error)
                        return
                    }

                    // 進捗報告: fire-and-forget で main に投げて即座に次のフレームへ
                    if let progressCB = progressCapture {
                        let percent = Int(Double(i + 1) / Double(frameCountCapture) * 100)
                        if percent != lastProgressReported {
                            lastProgressReported = percent
                            let p = Double(i + 1) / Double(frameCountCapture)
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated { progressCB(p) }
                            }
                        }
                    }
                }
                LogManager.shared.log("Convert", "libwebp totals: decode=\(Int(totalDecodeMs))ms encode=\(Int(totalEncodeMs))ms avgDecodePerFrame=\(Int(totalDecodeMs / Double(frameCountCapture)))ms")
                cont.resume()
            }
        }

        VTCompressionSessionCompleteFrames(vtSession, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(vtSession)
        LogManager.shared.log("Convert", "pipeline done \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConverterError.finishFailed(writer.error?.localizedDescription ?? "unknown")
        }
        let outFileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        if outFileSize < 10_000 {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConverterError.finishFailed("output too small: \(outFileSize)B")
        }
        FileManager.default.createFile(atPath: Self.okMarkerURL(for: outputURL).path, contents: Data())
        LogManager.shared.log("Convert", "DONE total=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms mp4=\(outFileSize)B mem=\(memoryFootprintMB())MB backend=libwebp")

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
    #endif

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
