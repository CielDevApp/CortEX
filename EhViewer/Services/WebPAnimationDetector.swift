import Foundation

/// WebP RIFF コンテナ先頭 21 バイトを読み VP8X chunk の ANIM flag (bit1, 0x02) を判定。
/// ImageIO 全フレームデコードより軽量。静止 WebP (VP8 / VP8L) は即 false。
enum WebPAnimationDetector {
    static func isAnimatedWebP(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32), data.count >= 21 else { return false }
        return checkHeader(Array(data))
    }

    static func isAnimatedWebP(data: Data) -> Bool {
        guard data.count >= 21 else { return false }
        return checkHeader(Array(data.prefix(32)))
    }

    private static func checkHeader(_ b: [UInt8]) -> Bool {
        // "RIFF" ... "WEBP"
        guard b.count >= 21 else { return false }
        guard b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 else { return false }
        guard b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 else { return false }
        // chunk FourCC at 12..<16
        guard b[12] == 0x56, b[13] == 0x50, b[14] == 0x38, b[15] == 0x58 else {
            // VP8 (static) or VP8L (static lossless) → not animated
            return false
        }
        // VP8X flags at byte 20: ANIM = bit 1 (0x02)
        return (b[20] & 0x02) != 0
    }

    /// ディレクトリ内に 1 枚でもアニメ WebP があれば true (JPEG/PNG/GIF 等は skip)。
    static func directoryContainsAnimated(_ dir: URL, fileManager: FileManager = .default) -> Bool {
        guard let it = fileManager.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return false
        }
        for case let url as URL in it {
            if isAnimatedWebP(url: url) { return true }
        }
        return false
    }
}
