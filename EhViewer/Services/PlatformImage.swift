import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

/// nonisolated: プロジェクトの Default Actor Isolation = @MainActor 設定により、
/// 無注釈の extension メンバーは Task.detached 内から呼んでも main へホップしてしまう。
/// CGImage クロップ / 強制デコードは重い処理なので nonisolated 化して呼び出し元の
/// スレッドで実行させる (EhClient / HDREnhancer と同じ対策の横展開)。
extension PlatformImage {
    /// cgImageを取得してクロップ。iOS/macOS共通インターフェース
    nonisolated func croppedImage(rect: CGRect) -> PlatformImage? {
        guard let cg = self.cgImage, let cropped = cg.cropping(to: rect) else { return nil }
        return PlatformImage(cgImage: cropped)
    }

    nonisolated var pixelWidth: Int { cgImage?.width ?? Int(size.width) }
    nonisolated var pixelHeight: Int { cgImage?.height ?? Int(size.height) }

    /// ピクセルを強制デコード（SwiftUI render時の遅延デコードを回避）
    /// maxDim指定で縮小も同時に行う
    /// nonisolated なので background (Task.detached 等) から呼べばそのスレッドで実行される
    /// (旧コメント「Task.detached内で呼ぶこと」は暗黙 @MainActor 時代の誤解:
    ///  当時は detached 内から呼んでも main へホップしていた)
    nonisolated func preDecoded(maxDim: CGFloat? = nil) -> PlatformImage {
        guard let cg = self.cgImage else { return self }
        let origW = cg.width
        let origH = cg.height
        let (newW, newH): (Int, Int)
        if let maxDim, CGFloat(max(origW, origH)) > maxDim {
            let scale = maxDim / CGFloat(max(origW, origH))
            newW = Int(CGFloat(origW) * scale)
            newH = Int(CGFloat(origH) * scale)
        } else {
            newW = origW
            newH = origH
        }
        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: newW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return self }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let decoded = ctx.makeImage() else { return self }
        return PlatformImage(cgImage: decoded, scale: self.scale, orientation: self.imageOrientation)
    }
}

#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage

/// nonisolated: UIKit 側 extension と同じ理由 (暗黙 @MainActor 化の回避)。
extension NSImage {
    nonisolated convenience init?(contentsOfFile path: String) {
        self.init(contentsOf: URL(fileURLWithPath: path))
    }

    nonisolated func croppedImage(rect: CGRect) -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
    }

    nonisolated var pixelWidth: Int {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return Int(size.width) }
        return cg.width
    }

    nonisolated var pixelHeight: Int {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return Int(size.height) }
        return cg.height
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}
#endif
