import Foundation
import CoreGraphics

#if canImport(libwebp)
import libwebp

/// フレーム単位で完全独立な animated WebP の並列デコーダ
/// 前提: 全フレームが dispose=NONE, blend=NO_BLEND, offset=0,0, size=canvas
/// これに該当すれば各フレームは他フレームに非依存 → 並列 decode 可能
/// 不適合な場合は WebPAnimatedDecoder にフォールバックする呼び出し側責任
final class WebPParallelDecoder: @unchecked Sendable {
    struct FrameInfo {
        /// 生の VP8 / VP8L チャンク（WebPDecodeBGRAInto に渡す）
        let data: Data
        /// 表示 duration (ms)
        let durationMs: Int
    }

    let canvasWidth: Int
    let canvasHeight: Int
    let frameCount: Int
    let loopCount: Int
    let frames: [FrameInfo]
    /// 全フレームが full-canvas 独立か。false なら並列 decode 不可（呼び出し側で fallback）
    let isFullyIndependent: Bool

    convenience init?(url: URL) {
        guard let fileData = try? Data(contentsOf: url), !fileData.isEmpty else { return nil }
        self.init(data: fileData)
    }

    init?(data fileData: Data) {
        guard !fileData.isEmpty else { return nil }

        let parsed: ParsedAnimation? = fileData.withUnsafeBytes { rawBuf -> ParsedAnimation? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var webpData = WebPData()
            WebPDataInit(&webpData)
            webpData.bytes = base
            webpData.size = fileData.count

            guard let dmux = WebPDemux(&webpData) else { return nil }
            defer { WebPDemuxDelete(dmux) }

            let cw = Int(WebPDemuxGetI(dmux, WEBP_FF_CANVAS_WIDTH))
            let ch = Int(WebPDemuxGetI(dmux, WEBP_FF_CANVAS_HEIGHT))
            let nframes = Int(WebPDemuxGetI(dmux, WEBP_FF_FRAME_COUNT))
            let loop = Int(WebPDemuxGetI(dmux, WEBP_FF_LOOP_COUNT))
            guard cw > 0, ch > 0, nframes > 0 else { return nil }

            var iter = WebPIterator()
            guard WebPDemuxGetFrame(dmux, 1, &iter) != 0 else { return nil }
            defer { WebPDemuxReleaseIterator(&iter) }

            var frames: [FrameInfo] = []
            frames.reserveCapacity(nframes)
            var allIndependent = true

            repeat {
                // 並列decode可能性の判定:
                // 1. full-canvas (offset=0,0 かつ size=canvas) が必須
                // 2-a. 完全不透明 (has_alpha=0) ならば blend/dispose は視覚的にno-op
                //      → 前フレーム状態無関係 → 並列OK
                // 2-b. 透明ありの場合は blend=NO_BLEND & dispose=NONE の厳密条件のみ可
                let isFullCanvas =
                    iter.x_offset == 0 && iter.y_offset == 0 &&
                    Int(iter.width) == cw && Int(iter.height) == ch
                let isOpaque = iter.has_alpha == 0
                let hasStrictIndepFlags =
                    iter.dispose_method == WEBP_MUX_DISPOSE_NONE &&
                    iter.blend_method == WEBP_MUX_NO_BLEND
                let indep = isFullCanvas && (isOpaque || hasStrictIndepFlags)
                if !indep { allIndependent = false }

                let frag = iter.fragment
                guard let ptr = frag.bytes else { return nil }
                // fragment は demuxer 所有メモリ → 独立 Data にコピー（worker threadで安全利用）
                let chunk = Data(bytes: ptr, count: frag.size)
                frames.append(FrameInfo(data: chunk, durationMs: Int(iter.duration)))
            } while WebPDemuxNextFrame(&iter) != 0

            return ParsedAnimation(
                canvasWidth: cw, canvasHeight: ch,
                frameCount: nframes, loopCount: loop,
                frames: frames, isFullyIndependent: allIndependent
            )
        }

        guard let p = parsed else { return nil }
        self.canvasWidth = p.canvasWidth
        self.canvasHeight = p.canvasHeight
        self.frameCount = p.frameCount
        self.loopCount = p.loopCount
        self.frames = p.frames
        self.isFullyIndependent = p.isFullyIndependent
    }

    private struct ParsedAnimation {
        let canvasWidth: Int
        let canvasHeight: Int
        let frameCount: Int
        let loopCount: Int
        let frames: [FrameInfo]
        let isFullyIndependent: Bool
    }

    /// 1 フレームを BGRA premultiplied Data へデコード（スレッドセーフ、canvas フル解像度）
    func decodeFrame(_ info: FrameInfo) -> Data? {
        let bytesPerRow = canvasWidth * 4
        let totalBytes = bytesPerRow * canvasHeight
        var output = Data(count: totalBytes)
        let ok: Bool = info.data.withUnsafeBytes { inBuf -> Bool in
            guard let inBase = inBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return output.withUnsafeMutableBytes { outBuf -> Bool in
                guard let outBase = outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                let ret = WebPDecodeBGRAInto(
                    inBase, info.data.count,
                    outBase, totalBytes, Int32(bytesPerRow)
                )
                return ret != nil
            }
        }
        return ok ? output : nil
    }

    /// libwebp native scaling で target サイズに縮小デコード（スレッドセーフ）。
    /// WebPDecoderConfig の use_scaling を使うと libwebp が decode 中にダウンスケールする。
    /// post-scale (CGContext / CIContext) 不要 → CPU コスト激減 + 出力 Data が小さい →
    /// allocator contention も減る。戻り値は (bgra Data, 実幅, 実高)。
    func decodeFrameScaled(_ info: FrameInfo, maxPixelSize: Int) -> (Data, Int, Int)? {
        // 縮小が不要な場合は通常 decode と同じ (canvas そのまま)
        let longer = max(canvasWidth, canvasHeight)
        guard longer > maxPixelSize else {
            guard let d = decodeFrame(info) else { return nil }
            return (d, canvasWidth, canvasHeight)
        }
        let scale = Double(maxPixelSize) / Double(longer)
        let targetW = Int((Double(canvasWidth) * scale).rounded())
        let targetH = Int((Double(canvasHeight) * scale).rounded())
        guard targetW > 0, targetH > 0 else { return nil }

        var config = WebPDecoderConfig()
        guard WebPInitDecoderConfig(&config) != 0 else { return nil }
        config.options.use_scaling = 1
        config.options.scaled_width = Int32(targetW)
        config.options.scaled_height = Int32(targetH)
        config.output.colorspace = MODE_bgrA  // BGRA premultiplied

        let status: VP8StatusCode = info.data.withUnsafeBytes { buf -> VP8StatusCode in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return VP8_STATUS_INVALID_PARAM }
            return WebPDecode(base, info.data.count, &config)
        }
        guard status == VP8_STATUS_OK else {
            WebPFreeDecBuffer(&config.output)
            return nil
        }
        let w = Int(config.output.width)
        let h = Int(config.output.height)
        let stride = Int(config.output.u.RGBA.stride)
        let size = stride * h
        guard let rgba = config.output.u.RGBA.rgba else {
            WebPFreeDecBuffer(&config.output)
            return nil
        }
        // config.output.u.RGBA.rgba は libwebp 所有メモリ。Swift Data にコピーしてから解放。
        let data = Data(bytes: UnsafeRawPointer(rgba), count: size)
        WebPFreeDecBuffer(&config.output)
        return (data, w, h)
    }

    /// BGRA Data から CGImage を生成（canvas フル解像度版）
    func makeCGImage(from bgra: Data) -> CGImage? {
        makeCGImage(from: bgra, width: canvasWidth, height: canvasHeight)
    }

    /// BGRA Data + 任意サイズから CGImage 生成 (scaled decode 用)
    func makeCGImage(from bgra: Data, width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: bgra as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
#endif
