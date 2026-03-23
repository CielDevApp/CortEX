import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import Accelerate
#if canImport(UIKit)
import UIKit
#endif

protocol ImageUpscaler {
    func upscale(_ image: PlatformImage, scale: CGFloat) -> PlatformImage?
}

final class LanczosUpscaler: ImageUpscaler {
    static let shared = LanczosUpscaler()

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - モード1用: サムネアップスケール

    func upscale(_ image: PlatformImage, scale: CGFloat) -> PlatformImage? {
        #if canImport(UIKit)
        return autoreleasepool {
            guard let cgImage = image.cgImage else { return nil }
            var ciImage = CIImage(cgImage: cgImage)

            guard let scaleFilter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
            scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
            scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
            scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            guard let scaled = scaleFilter.outputImage else { return nil }
            ciImage = scaled

            if let s = CIFilter(name: "CISharpenLuminance") {
                s.setValue(ciImage, forKey: kCIInputImageKey)
                s.setValue(0.4, forKey: kCIInputSharpnessKey)
                s.setValue(1.5, forKey: kCIInputRadiusKey)
                if let out = s.outputImage { ciImage = out }
            }

            guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: cg)
        }
        #else
        return image
        #endif
    }

    // MARK: - モード1用: サムネアップスケール後の画質強化

    func enhanceLowQuality(_ image: PlatformImage) -> PlatformImage? {
        #if canImport(UIKit)
        return autoreleasepool {
            guard let cgImage = image.cgImage else { return nil }
            var ciImage = CIImage(cgImage: cgImage)

            // 1. ノイズ除去（先にノイズを消す）
            if let f = CIFilter(name: "CINoiseReduction") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(0.03, forKey: "inputNoiseLevel")
                f.setValue(0.5, forKey: kCIInputSharpnessKey)
                if let out = f.outputImage { ciImage = out }
            }

            // 2. シャープネス
            if let f = CIFilter(name: "CISharpenLuminance") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(0.5, forKey: kCIInputSharpnessKey)
                f.setValue(1.2, forKey: kCIInputRadiusKey)
                if let out = f.outputImage { ciImage = out }
            }

            // 3. 色補正
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(1.08, forKey: kCIInputContrastKey)
                f.setValue(1.05, forKey: kCIInputSaturationKey)
                if let out = f.outputImage { ciImage = out }
            }

            guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: cg)
        }
        #else
        return image
        #endif
    }

    // MARK: - モード1用: テキスト領域強化アップスケール

    func upscaleWithTextEnhance(_ image: PlatformImage, scale: CGFloat) -> PlatformImage? {
        #if canImport(UIKit)
        return autoreleasepool {
            guard let cgImage = image.cgImage else { return nil }
            let ciOriginal = CIImage(cgImage: cgImage)

            guard let scaleFilter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
            scaleFilter.setValue(ciOriginal, forKey: kCIInputImageKey)
            scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
            scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            guard let scaled = scaleFilter.outputImage,
                  let scaledCG = context.createCGImage(scaled, from: scaled.extent) else { return nil }

            let ciScaled = CIImage(cgImage: scaledCG)
            let textBoxes = detectTextRegions(in: scaledCG)

            guard let strong = CIFilter(name: "CISharpenLuminance") else { return nil }
            strong.setValue(ciScaled, forKey: kCIInputImageKey)
            strong.setValue(1.0, forKey: kCIInputSharpnessKey)
            strong.setValue(2.0, forKey: kCIInputRadiusKey)
            guard let textSharp = strong.outputImage else { return nil }

            guard let light = CIFilter(name: "CISharpenLuminance") else { return nil }
            light.setValue(ciScaled, forKey: kCIInputImageKey)
            light.setValue(0.4, forKey: kCIInputSharpnessKey)
            light.setValue(1.5, forKey: kCIInputRadiusKey)
            guard let bgSharp = light.outputImage else { return nil }

            if !textBoxes.isEmpty, let mask = createTextMask(boxes: textBoxes, width: scaledCG.width, height: scaledCG.height) {
                let ciMask = CIImage(cgImage: mask)
                guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
                blend.setValue(textSharp, forKey: kCIInputImageKey)
                blend.setValue(bgSharp, forKey: kCIInputBackgroundImageKey)
                blend.setValue(ciMask, forKey: kCIInputMaskImageKey)
                if let blended = blend.outputImage,
                   let cgFinal = context.createCGImage(blended, from: blended.extent) {
                    return UIImage(cgImage: cgFinal)
                }
            }

            guard let cg = context.createCGImage(bgSharp, from: bgSharp.extent) else { return nil }
            return UIImage(cgImage: cg)
        }
        #else
        return image
        #endif
    }

    // MARK: - 画像補正フィルタ（独立トグル）

    nonisolated var isEnhanceFilterEnabled: Bool {
        UserDefaults.standard.bool(forKey: "imageEnhanceFilter")
    }

    func enhanceFilter(_ image: PlatformImage) -> PlatformImage? {
        #if canImport(UIKit)
        return autoreleasepool {
            guard let cgImage = image.cgImage else { return nil }
            let isGray = isGrayscaleImage(cgImage)
            var ciImage = CIImage(cgImage: cgImage)

            // 1. CIHighlightShadowAdjust（カラー・グレー共通）
            if let f = CIFilter(name: "CIHighlightShadowAdjust") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(0.9, forKey: "inputHighlightAmount")
                f.setValue(isGray ? 0.15 : 0.3, forKey: "inputShadowAmount")
                if let out = f.outputImage { ciImage = out }
            }

            // 2. CIVibrance（カラーのみ）
            if !isGray {
                if let f = CIFilter(name: "CIVibrance") {
                    f.setValue(ciImage, forKey: kCIInputImageKey)
                    f.setValue(0.15, forKey: "inputAmount")
                    if let out = f.outputImage { ciImage = out }
                }
            }

            // 3. CIToneCurve S字カーブ（カラー・グレー共通、グレーは控えめ）
            if let f = CIFilter(name: "CIToneCurve") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
                if isGray {
                    f.setValue(CIVector(x: 0.2, y: 0.15), forKey: "inputPoint1")
                    f.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
                    f.setValue(CIVector(x: 0.8, y: 0.9), forKey: "inputPoint3")
                } else {
                    f.setValue(CIVector(x: 0.15, y: 0.1), forKey: "inputPoint1")
                    f.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
                    f.setValue(CIVector(x: 0.85, y: 0.95), forKey: "inputPoint3")
                }
                f.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
                if let out = f.outputImage { ciImage = out }
            }

            // 4. CILocalToneMap（カラーのみ、控えめ設定）
            if !isGray {
                ciImage = applyLocalToneMap(ciImage)
            }

            guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: cg)
        }
        #else
        return image
        #endif
    }

    // MARK: - モード3: フル画像シャープネスのみ

    func sharpenOnly(_ image: PlatformImage) -> PlatformImage? {
        #if canImport(UIKit)
        return autoreleasepool {
            guard let cgImage = image.cgImage else { return nil }
            let ciImage = CIImage(cgImage: cgImage)

            guard let f = CIFilter(name: "CISharpenLuminance") else { return nil }
            f.setValue(ciImage, forKey: kCIInputImageKey)
            f.setValue(0.4, forKey: kCIInputSharpnessKey)
            f.setValue(1.0, forKey: kCIInputRadiusKey)
            guard let out = f.outputImage else { return nil }

            guard let cg = context.createCGImage(out, from: out.extent) else { return nil }
            return UIImage(cgImage: cg)
        }
        #else
        return image
        #endif
    }

    // MARK: - モード4: 究極画質

    func enhanceUltimate(_ image: PlatformImage) -> PlatformImage? {
        #if canImport(UIKit)
        return autoreleasepool {
            guard let cgImage = image.cgImage else { return nil }
            var ciImage = CIImage(cgImage: cgImage)

            // 1. ノイズ除去
            if let f = CIFilter(name: "CINoiseReduction") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(0.02, forKey: "inputNoiseLevel")
                f.setValue(0.4, forKey: kCIInputSharpnessKey)
                if let out = f.outputImage { ciImage = out }
            }

            // 2. コントラスト・彩度
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(1.1, forKey: kCIInputContrastKey)
                f.setValue(1.05, forKey: kCIInputSaturationKey)
                if let out = f.outputImage { ciImage = out }
            }

            // 3. シャープネス
            if let f = CIFilter(name: "CISharpenLuminance") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(0.8, forKey: kCIInputSharpnessKey)
                f.setValue(1.5, forKey: kCIInputRadiusKey)
                if let out = f.outputImage { ciImage = out }
            }

            guard let cgMid = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

            // 4. 人物検出+重点補正
            return applyPersonSegmentation(UIImage(cgImage: cgMid)) ?? UIImage(cgImage: cgMid)
        }
        #else
        return image
        #endif
    }

    // MARK: - ローカルトーンマップ

    private func applyLocalToneMap(_ ciImage: CIImage) -> CIImage {
        if #available(iOS 17, macOS 14, *) {
            if let f = CIFilter(name: "CIToneMapHeadroom") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(1.0, forKey: "inputSourceHeadroom")
                f.setValue(1.2, forKey: "inputTargetHeadroom")
                if let out = f.outputImage { return out }
            }
        }
        return ciImage
    }

    // MARK: - ヒストグラム均等化 (vImage)

    #if canImport(UIKit)
    private func applyHistogramEqualization(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        guard let colorSpace = cgImage.colorSpace,
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }

        var src = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var dst = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)

        let error = vImageEqualization_ARGB8888(&src, &dst, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }

        guard let outCG = ctx.makeImage() else { return nil }
        return UIImage(cgImage: outCG)
    }

    // MARK: - 人物検出+重点補正 (Neural Engine)

    /// 人物領域を検出して選択的シャープネス+彩度強化（NE活用）
    func applyPersonSegmentation(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let result = request.results?.first else { return nil }
        let maskBuffer = result.pixelBuffer

        let ciMask = CIImage(cvPixelBuffer: maskBuffer)
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent

        // マスクを画像サイズにリサイズ
        let scaleX = extent.width / ciMask.extent.width
        let scaleY = extent.height / ciMask.extent.height
        let scaledMask = ciMask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // 人物領域: シャープ強め + 彩度アップ
        var personImage = ciImage
        if let f = CIFilter(name: "CISharpenLuminance") {
            f.setValue(personImage, forKey: kCIInputImageKey)
            f.setValue(0.6, forKey: kCIInputSharpnessKey)
            f.setValue(1.5, forKey: kCIInputRadiusKey)
            if let out = f.outputImage { personImage = out }
        }
        if let f = CIFilter(name: "CIVibrance") {
            f.setValue(personImage, forKey: kCIInputImageKey)
            f.setValue(0.2, forKey: "inputAmount")
            if let out = f.outputImage { personImage = out }
        }

        // 背景領域: ノイズ除去強め
        var bgImage = ciImage
        if let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(bgImage, forKey: kCIInputImageKey)
            f.setValue(0.04, forKey: "inputNoiseLevel")
            f.setValue(0.3, forKey: kCIInputSharpnessKey)
            if let out = f.outputImage { bgImage = out }
        }

        // 合成
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(personImage, forKey: kCIInputImageKey)
        blend.setValue(bgImage, forKey: kCIInputBackgroundImageKey)
        blend.setValue(scaledMask, forKey: kCIInputMaskImageKey)

        guard let blended = blend.outputImage,
              let cgOut = context.createCGImage(blended, from: extent) else { return nil }

        return UIImage(cgImage: cgOut)
    }

    // MARK: - テキスト検出

    private func detectTextRegions(in cgImage: CGImage) -> [CGRect] {
        var boxes: [CGRect] = []
        let request = VNRecognizeTextRequest { request, _ in
            guard let results = request.results as? [VNRecognizedTextObservation] else { return }
            boxes = results.map { $0.boundingBox }
        }
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["ja", "en"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return boxes
    }

    private func createTextMask(boxes: [CGRect], width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        for box in boxes {
            let margin: CGFloat = 0.02
            ctx.fill(CGRect(
                x: max(0, box.origin.x - margin) * CGFloat(width),
                y: max(0, box.origin.y - margin) * CGFloat(height),
                width: min(1, box.width + margin * 2) * CGFloat(width),
                height: min(1, box.height + margin * 2) * CGFloat(height)
            ))
        }
        return ctx.makeImage()
    }
    #endif
}
