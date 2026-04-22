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

    /// CGImage を直接受け取る版 (アニメフレーム処理用、UIImage 経由しない)。
    /// 既存 enhance(_:) と同一パイプライン (HighlightShadow → Vibrance → S-curve)。
    nonisolated static func enhanceCG(_ cgImage: CGImage) -> CGImage? {
        autoreleasepool {
            var ciImage = CIImage(cgImage: cgImage)
            if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(0.9, forKey: "inputHighlightAmount")
                filter.setValue(0.3, forKey: "inputShadowAmount")
                if let out = filter.outputImage { ciImage = out }
            }
            if let filter = CIFilter(name: "CIVibrance") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(0.15, forKey: "inputAmount")
                if let out = filter.outputImage { ciImage = out }
            }
            if let filter = CIFilter(name: "CIToneCurve") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
                filter.setValue(CIVector(x: 0.15, y: 0.1), forKey: "inputPoint1")
                filter.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
                filter.setValue(CIVector(x: 0.85, y: 0.95), forKey: "inputPoint3")
                filter.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
                if let out = filter.outputImage { ciImage = out }
            }
            return HDREnhancer.shared.context.createCGImage(ciImage, from: ciImage.extent)
        }
    }

    /// CIImage in/out 版 (AVVideoComposition の applyingCIFiltersWithHandler 用)。
    /// CGImage ラウンドトリップを避けて GPU 上で完結させる。
    ///
    /// 注: 静画 enhance(_:) と同じ値を入れると AVVideoComposition のデフォルト working color space
    /// (linear BT.709) で過補正 → 白飛び (2026-04-22 実測)。色空間固定は outputTransferFunction が
    /// sRGB 強制で別種の白飛びを起こすため、値だけ控えめにして近似する方針。
    nonisolated static func enhanceCI(_ ciImage: CIImage) -> CIImage {
        var img = ciImage
        if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            filter.setValue(img, forKey: kCIInputImageKey)
            filter.setValue(0.55, forKey: "inputHighlightAmount")
            filter.setValue(0.25, forKey: "inputShadowAmount")
            if let out = filter.outputImage { img = out }
        }
        if let filter = CIFilter(name: "CIVibrance") {
            filter.setValue(img, forKey: kCIInputImageKey)
            filter.setValue(0.10, forKey: "inputAmount")
            if let out = filter.outputImage { img = out }
        }
        if let filter = CIFilter(name: "CIToneCurve") {
            filter.setValue(img, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
            filter.setValue(CIVector(x: 0.15, y: 0.1), forKey: "inputPoint1")
            filter.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
            filter.setValue(CIVector(x: 0.85, y: 0.88), forKey: "inputPoint3")
            filter.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
            if let out = filter.outputImage { img = out }
        }
        return img
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
