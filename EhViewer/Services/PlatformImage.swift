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

extension PlatformImage {
    /// cgImageを取得してクロップ。iOS/macOS共通インターフェース
    func croppedImage(rect: CGRect) -> PlatformImage? {
        guard let cg = self.cgImage, let cropped = cg.cropping(to: rect) else { return nil }
        return PlatformImage(cgImage: cropped)
    }

    var pixelWidth: Int { cgImage?.width ?? Int(size.width) }
    var pixelHeight: Int { cgImage?.height ?? Int(size.height) }
}

#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage

extension NSImage {
    convenience init?(contentsOfFile path: String) {
        self.init(contentsOf: URL(fileURLWithPath: path))
    }

    func croppedImage(rect: CGRect) -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
    }

    var pixelWidth: Int {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return Int(size.width) }
        return cg.width
    }

    var pixelHeight: Int {
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
