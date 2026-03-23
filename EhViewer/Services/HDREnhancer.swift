import Foundation
import CoreImage
#if canImport(UIKit)
import UIKit
#endif

/// HDR風画像補正（暗部ディテール+彩度+コントラスト強調）
final class HDREnhancer: @unchecked Sendable {
    static let shared = HDREnhancer()

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    nonisolated var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "hdrEnhancement")
    }

    nonisolated func enhance(_ image: PlatformImage) -> PlatformImage? {
        #if canImport(UIKit)
        return autoreleasepool {
            guard let cgImage = image.cgImage else { return nil }
            var ciImage = CIImage(cgImage: cgImage)

            // 1. ハイライト/シャドウ調整（暗部ディテール引き出し）
            if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(0.9, forKey: "inputHighlightAmount")
                filter.setValue(0.3, forKey: "inputShadowAmount")
                if let out = filter.outputImage { ciImage = out }
            }

            // 2. 彩度アップ（自然な色味強調）
            if let filter = CIFilter(name: "CIVibrance") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(0.15, forKey: "inputAmount")
                if let out = filter.outputImage { ciImage = out }
            }

            // 3. S字トーンカーブ（コントラスト強調）
            if let filter = CIFilter(name: "CIToneCurve") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
                filter.setValue(CIVector(x: 0.15, y: 0.1), forKey: "inputPoint1")
                filter.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
                filter.setValue(CIVector(x: 0.85, y: 0.95), forKey: "inputPoint3")
                filter.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
                if let out = filter.outputImage { ciImage = out }
            }

            guard let cgOutput = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: cgOutput)
        }
        #else
        return image
        #endif
    }
}
