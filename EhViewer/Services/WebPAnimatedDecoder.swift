import Foundation
import CoreGraphics

#if canImport(libwebp)
import libwebp

/// libwebp の WebPAnimDecoder を Swift で薄くラップ
/// 目的: Apple ImageIO (CGImageSource) より高速な WebP アニメーション decode
/// 制約: 順次アクセス専用（frame i へのランダムアクセス不可、reset で巻き戻し）
final class WebPAnimatedDecoder: @unchecked Sendable {
    private var decoder: OpaquePointer?
    private var webpData = WebPData()
    private let fileBytes: UnsafeMutablePointer<UInt8>
    private let fileSize: Int

    let canvasWidth: Int
    let canvasHeight: Int
    let frameCount: Int
    let loopCount: Int

    /// 前回 getNext の timestamp（累積 ms）。delay 計算用
    private var lastTimestampMs: Int32 = 0

    init?(url: URL) {
        // ファイル全体をメモリへ読み込む（libwebp は連続メモリ参照が必要）
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let size = data.count
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        data.copyBytes(to: buf, count: size)
        self.fileBytes = buf
        self.fileSize = size

        WebPDataInit(&webpData)
        webpData.bytes = UnsafePointer<UInt8>(buf)
        webpData.size = size

        var options = WebPAnimDecoderOptions()
        guard WebPAnimDecoderOptionsInit(&options) != 0 else {
            buf.deallocate()
            return nil
        }
        // BGRA premultiplied: CVPixelBuffer の kCVPixelFormatType_32BGRA と直接互換
        options.color_mode = MODE_bgrA
        options.use_threads = 1

        guard let dec = WebPAnimDecoderNew(&webpData, &options) else {
            buf.deallocate()
            return nil
        }

        var info = WebPAnimInfo()
        guard WebPAnimDecoderGetInfo(dec, &info) != 0 else {
            WebPAnimDecoderDelete(dec)
            buf.deallocate()
            return nil
        }

        self.decoder = dec
        self.canvasWidth = Int(info.canvas_width)
        self.canvasHeight = Int(info.canvas_height)
        self.frameCount = Int(info.frame_count)
        self.loopCount = Int(info.loop_count)
    }

    /// 次フレームを BGRA CGImage として返す
    /// - Returns: (cgImage, フレーム終了時刻 ms, 当該フレーム delay ms)
    func nextFrame() -> (image: CGImage, endTimestampMs: Int32, delayMs: Int32)? {
        guard let dec = decoder else { return nil }
        guard WebPAnimDecoderHasMoreFrames(dec) != 0 else { return nil }

        var bufPtr: UnsafeMutablePointer<UInt8>?
        var timestamp: Int32 = 0
        guard WebPAnimDecoderGetNext(dec, &bufPtr, &timestamp) != 0,
              let buf = bufPtr else {
            return nil
        }

        let bytesPerRow = canvasWidth * 4
        let totalBytes = bytesPerRow * canvasHeight

        // libwebp の buf は decoder 所有（次の getNext / reset / delete で無効化）
        // → CFData にコピーして CGImage にラップ（所有権を CGImage 側へ）
        guard let cfData = CFDataCreate(nil, buf, totalBytes),
              let provider = CGDataProvider(data: cfData) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // BGRA in memory → little-endian 32bit word で alpha first と解釈
        // = premultipliedFirst + byteOrder32Little
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)

        guard let cg = CGImage(
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        let delay = max(timestamp - lastTimestampMs, 10)
        lastTimestampMs = timestamp
        return (cg, timestamp, delay)
    }

    func reset() {
        if let dec = decoder {
            WebPAnimDecoderReset(dec)
        }
        lastTimestampMs = 0
    }

    deinit {
        if let dec = decoder {
            WebPAnimDecoderDelete(dec)
        }
        fileBytes.deallocate()
    }
}
#endif

/// libwebp モジュールが利用可能か
enum WebPLibSupport {
    static var isAvailable: Bool {
        #if canImport(libwebp)
        return true
        #else
        return false
        #endif
    }
}

/// WebP ファイル検知（libwebp 不要、マジックバイトのみ）
enum WebPFileDetector {
    /// アニメ WebP ファイルか（RIFF...WEBP + ANIM chunk を含む）
    static func isAnimatedWebP(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // RIFF header + 最初の数chunk を読む（ANIM chunk は通常 file head 数百B内）
        guard let head = try? handle.read(upToCount: 256), head.count >= 12 else {
            return false
        }
        let bytes = [UInt8](head)
        // "RIFF" (52 49 46 46) + (file size) + "WEBP" (57 45 42 50)
        guard bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
              bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 else {
            return false
        }
        // "ANIM" chunk (41 4E 49 4D) を検索
        let anim: [UInt8] = [0x41, 0x4E, 0x49, 0x4D]
        return head.range(of: Data(anim)) != nil
    }

    /// WebPのキャンバスサイズを同期取得（VP8Xチャンクから。アニメWebP専用）
    /// libwebp不要 → View生成時の即時アスペクト比確定に利用
    /// - VP8X payload: flags(1) + reserved(3) + canvas_w-1(3LE) + canvas_h-1(3LE)
    /// - VP8X chunk は RIFFヘッダ直後 (offset 12)、payload は offset 20 から始まる
    static func readCanvasSize(url: URL) -> CGSize? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 30), head.count >= 30 else { return nil }
        let bytes = [UInt8](head)
        // RIFF...WEBPVP8X 判定
        guard bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
              bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50,
              bytes[12] == 0x56, bytes[13] == 0x50, bytes[14] == 0x38, bytes[15] == 0x58
        else { return nil }
        let w = Int(bytes[24]) | (Int(bytes[25]) << 8) | (Int(bytes[26]) << 16)
        let h = Int(bytes[27]) | (Int(bytes[28]) << 8) | (Int(bytes[29]) << 16)
        return CGSize(width: w + 1, height: h + 1)
    }
}
