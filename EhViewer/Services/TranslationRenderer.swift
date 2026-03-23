import Foundation
import CoreImage
#if canImport(UIKit)
import UIKit
#endif

/// 翻訳テキストの画像焼き込みレンダラー
enum TranslationRenderer {

    #if canImport(UIKit)
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 元画像にOCRブロックの白塗り潰し+翻訳テキストを焼き込んだ画像を生成
    static func render(original: PlatformImage, blocks: [TranslatedBlock]) -> PlatformImage? {
        let size = original.size
        guard size.width > 0, size.height > 0,
              let cgImage = original.cgImage else { return nil }
        let padding: CGFloat = 3

        // Step 1: GPU上で白塗り潰し（CIImage合成）
        var ciImage = CIImage(cgImage: cgImage)
        let white = CIImage(color: .white).cropped(to: ciImage.extent)

        for block in blocks {
            let box = block.boundingBox
            let x = box.origin.x * size.width - padding
            let y = box.origin.y * size.height - padding
            let w = box.width * size.width + padding * 2
            let h = box.height * size.height + padding * 2
            let maskRect = CGRect(x: x, y: y, width: w, height: h)
            let mask = white.cropped(to: maskRect)
            ciImage = mask.composited(over: ciImage)
        }

        guard let filledCG = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        // Step 2: CPU上でテキスト描画
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIImage(cgImage: filledCG).draw(at: .zero)

            for block in blocks {
                let box = block.boundingBox
                let bx = box.origin.x * size.width
                let by = (1 - box.origin.y - box.height) * size.height
                let bw = box.width * size.width
                let bh = box.height * size.height
                let rect = CGRect(x: bx, y: by, width: bw, height: bh)

                let fontSize = max(8, min(bh * 0.7, bw * 0.15))
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                paragraphStyle.lineBreakMode = .byWordWrapping

                let constraintSize = CGSize(width: rect.width, height: rect.height)
                let text = block.translatedText as NSString

                // 二分探索でフィットするフォントサイズを決定
                var lo: CGFloat = 6, hi: CGFloat = fontSize
                var drawFont = UIFont.systemFont(ofSize: hi)
                var textSize = text.boundingRect(
                    with: constraintSize,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: drawFont, .paragraphStyle: paragraphStyle],
                    context: nil
                ).size

                if textSize.height > rect.height {
                    while hi - lo > 1 {
                        let mid = (lo + hi) / 2
                        let midFont = UIFont.systemFont(ofSize: mid)
                        let midSize = text.boundingRect(
                            with: constraintSize,
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            attributes: [.font: midFont, .paragraphStyle: paragraphStyle],
                            context: nil
                        ).size
                        if midSize.height > rect.height { hi = mid } else { lo = mid }
                    }
                    drawFont = UIFont.systemFont(ofSize: lo)
                    textSize = text.boundingRect(
                        with: constraintSize,
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: drawFont, .paragraphStyle: paragraphStyle],
                        context: nil
                    ).size
                }

                let drawAttrs: [NSAttributedString.Key: Any] = [
                    .font: drawFont,
                    .foregroundColor: UIColor.black,
                    .paragraphStyle: paragraphStyle,
                ]
                let drawY = rect.origin.y + (rect.height - textSize.height) / 2
                let drawRect = CGRect(x: rect.origin.x, y: drawY, width: rect.width, height: textSize.height)
                text.draw(in: drawRect, withAttributes: drawAttrs)
            }
        }
    }
    #else
    static func render(original: PlatformImage, blocks: [TranslatedBlock]) -> PlatformImage? { nil }
    #endif
}
