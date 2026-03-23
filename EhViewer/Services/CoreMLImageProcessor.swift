import Foundation
import CoreML
import CoreImage
import CoreVideo
#if canImport(UIKit)
import UIKit
#endif

/// 画像処理プロトコル
nonisolated protocol ImageProcessor: Sendable {
    func process(_ image: PlatformImage) async -> PlatformImage?
}

/// CoreMLモデルによる超解像（タイリング方式、メモリ安全、クラッシュガード付き）
final class CoreMLImageProcessor: @unchecked Sendable, ImageProcessor {
    static let shared = CoreMLImageProcessor()

    /// モデルは遅延ロード（アプリ起動時にCoreML推論を走らせない）
    private var model: MLModel?
    private var modelLoaded = false
    private(set) var modelAvailable: Bool = false

    /// タイル入力サイズ（Real-ESRGAN固定）
    private let tileSize = 128
    /// モデルの出力スケール
    private let modelScale = 4
    /// タイルオーバーラップ（境界つなぎ目対策）
    private let overlap = 8

    /// 出力長辺上限
    private let maxOutputEdge = 4096
    /// メモリ上限（バイト）
    private let maxOutputBytes = 200 * 1024 * 1024
    /// 入力長辺がこれ以上なら超解像をスキップ
    private let skipThreshold = 3000
    /// 最大タイル数（これを超えたらLanczosフォールバック）
    private let maxTileCount = 20
    /// 空きメモリ下限（バイト）
    private let minFreeMemory = 100 * 1024 * 1024

    /// アプリがアクティブかどうか（FaceIDロック中は処理しない）
    /// デフォルトtrue（onChange初期値問題の回避）、background遷移時にfalseにする
    var isAppActive: Bool = true

    nonisolated private init() {
        // モデルの存在だけチェック（ロードはしない）
        let names = ["ImageEnhance", "SuperResolution", "Upscaler"]
        let extensions = ["mlmodelc", "mlpackage"]
        var found = false
        for name in names {
            for ext in extensions {
                if Bundle.main.url(forResource: name, withExtension: ext) != nil {
                    found = true
                    break
                }
            }
            if found { break }
        }
        self.modelAvailable = found
        LogManager.shared.log("CoreML", "model file found: \(found) (lazy load)")
    }

    /// モデルを遅延ロード（初回process呼び出し時）
    private func ensureModelLoaded() {
        guard !modelLoaded else { return }
        modelLoaded = true

        let names = ["ImageEnhance", "SuperResolution", "Upscaler"]
        let extensions = ["mlmodelc", "mlpackage"]
        for name in names {
            for ext in extensions {
                if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                    do {
                        let compiled: URL
                        if ext == "mlpackage" {
                            compiled = try MLModel.compileModel(at: url)
                        } else {
                            compiled = url
                        }
                        let config = MLModelConfiguration()
                        config.computeUnits = .all
                        self.model = try MLModel(contentsOf: compiled, configuration: config)
                        LogManager.shared.log("CoreML", "loaded model: \(name).\(ext)")

                        let desc = self.model!.modelDescription
                        LogManager.shared.log("CoreML", "input keys: \(desc.inputDescriptionsByName.keys.sorted())")
                        LogManager.shared.log("CoreML", "output keys: \(desc.outputDescriptionsByName.keys.sorted())")
                        return
                    } catch {
                        LogManager.shared.log("CoreML", "failed to load \(name).\(ext): \(error)")
                    }
                }
            }
        }
        LogManager.shared.log("CoreML", "no model could be loaded")
        self.modelAvailable = false
    }

    /// 超解像処理（全エラーをキャッチ、クラッシュしない）
    nonisolated func process(_ image: PlatformImage) async -> PlatformImage? {
        #if canImport(UIKit)
        // クラッシュガード: アプリ非アクティブ時はスキップ
        guard isAppActive else {
            LogManager.shared.log("CoreML", "process: skipped — app not active")
            return nil
        }

        // 空きメモリチェック
        let freeMem = Self.availableMemory()
        if freeMem > 0 && freeMem < minFreeMemory {
            LogManager.shared.log("CoreML", "process: skipped — free memory \(freeMem / 1_048_576)MB < \(minFreeMemory / 1_048_576)MB")
            Self.autoDisableAI()
            return nil
        }

        // モデル遅延ロード
        ensureModelLoaded()
        guard let model else {
            LogManager.shared.log("CoreML", "process: no model loaded")
            return nil
        }

        guard let cgImage = image.cgImage else {
            LogManager.shared.log("CoreML", "process: failed to get cgImage")
            return nil
        }

        let srcW = cgImage.width
        let srcH = cgImage.height
        let longEdge = max(srcW, srcH)

        // 高解像度入力はスキップ
        if longEdge >= skipThreshold {
            LogManager.shared.log("CoreML", "process: skipped — input \(srcW)x\(srcH) already high-res")
            return fallbackEnhance(image)
        }

        // 出力サイズチェック
        let outW = srcW * modelScale
        let outH = srcH * modelScale
        if max(outW, outH) > maxOutputEdge {
            LogManager.shared.log("CoreML", "process: skipped — output \(outW)x\(outH) exceeds \(maxOutputEdge)px")
            return fallbackEnhance(image)
        }

        // メモリ見積もり
        let estimatedBytes = outW * outH * 4
        LogManager.shared.log("CoreML", "process: input=\(srcW)x\(srcH) → output=\(outW)x\(outH) estimated=\(estimatedBytes / 1_048_576)MB free=\(freeMem / 1_048_576)MB")

        if estimatedBytes > maxOutputBytes {
            LogManager.shared.log("CoreML", "process: skipped — estimated \(estimatedBytes / 1_048_576)MB exceeds limit")
            return fallbackEnhance(image)
        }

        // 空きメモリの50%を超える場合もスキップ
        if freeMem > 0 && estimatedBytes > freeMem / 2 {
            LogManager.shared.log("CoreML", "process: skipped — estimated \(estimatedBytes / 1_048_576)MB > 50% of free \(freeMem / 1_048_576)MB")
            Self.autoDisableAI()
            return fallbackEnhance(image)
        }

        // 小さすぎる画像はLanczosフォールバック
        if srcW < 64 || srcH < 64 {
            LogManager.shared.log("CoreML", "process: input \(srcW)x\(srcH) too small, using Lanczos")
            return lanczosUpscale(image, scale: CGFloat(modelScale))
        }

        // 画像がタイルサイズ未満 → パディングして1タイル処理
        let tile = tileSize
        if srcW <= tile && srcH <= tile {
            LogManager.shared.log("CoreML", "process: input \(srcW)x\(srcH) <= tile \(tile), using single padded tile")
            do {
                return try processSinglePaddedTile(model: model, cgImage: cgImage, srcW: srcW, srcH: srcH, image: image)
            } catch {
                LogManager.shared.log("CoreML", "process: padded tile failed: \(error)")
                return lanczosUpscale(image, scale: CGFloat(modelScale)) ?? image
            }
        }

        // タイル数見積もり
        let step = tile - overlap * 2
        guard step > 0 else { return nil }
        let tilesX = max(1, (srcW + step - 1) / step)
        let tilesY = max(1, (srcH + step - 1) / step)
        let totalTiles = tilesX * tilesY

        if totalTiles > maxTileCount {
            LogManager.shared.log("CoreML", "process: \(totalTiles) tiles exceeds limit \(maxTileCount), using Lanczos fallback")
            return lanczosUpscale(image, scale: CGFloat(modelScale))
        }

        LogManager.shared.log("CoreML", "process: \(totalTiles) tiles (\(tilesX)x\(tilesY)) to process")

        // タイリング処理（全体をdo-catchで囲む）
        do {
            return try processWithTiling(model: model, cgImage: cgImage, srcW: srcW, srcH: srcH, outW: outW, outH: outH, image: image)
        } catch {
            LogManager.shared.log("CoreML", "process: fatal error: \(error)")
            Self.autoDisableAI()
            return image
        }
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    /// タイリング処理本体（throwsで囲んでクラッシュ防止）
    nonisolated private func processWithTiling(
        model: MLModel, cgImage: CGImage,
        srcW: Int, srcH: Int, outW: Int, outH: Int,
        image: PlatformImage
    ) throws -> PlatformImage {
        let tile = tileSize
        let ovlp = overlap
        let step = tile - ovlp * 2

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let outputCtx = CGContext(
                data: nil, width: outW, height: outH,
                bitsPerComponent: 8, bytesPerRow: outW * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            LogManager.shared.log("CoreML", "process: failed to create output context")
            return image
        }

        let inputKey = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])

        var tileCount = 0
        var failCount = 0
        var y = 0

        while y < srcH {
            // タイルごとにメモリチェック
            let freeMem = Self.availableMemory()
            if freeMem > 0 && freeMem < minFreeMemory {
                LogManager.shared.log("CoreML", "process: aborting at tile \(tileCount) — low memory \(freeMem / 1_048_576)MB")
                Self.autoDisableAI()
                return image
            }

            var tileY = y
            if tileY + tile > srcH { tileY = max(0, srcH - tile) }

            var x = 0
            while x < srcW {
                var tileX = x
                if tileX + tile > srcW { tileX = max(0, srcW - tile) }

                tileCount += 1

                let success = autoreleasepool { () -> Bool in
                    // crop範囲を画像境界にクランプ
                    let cropX = min(tileX, max(0, srcW - tile))
                    let cropY = min(tileY, max(0, srcH - tile))
                    let cropW = min(tile, srcW - cropX)
                    let cropH = min(tile, srcH - cropY)

                    if tileCount <= 2 {
                        LogManager.shared.log("CoreML", "tile \(tileCount): crop=(\(cropX),\(cropY),\(cropW)x\(cropH)) src=\(srcW)x\(srcH)")
                    }

                    // crop範囲がタイルサイズ未満なら拡張パディング
                    let tileCG: CGImage?
                    if cropW < tile || cropH < tile {
                        // パディングが必要
                        guard let partialCG = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) else {
                            LogManager.shared.log("CoreML", "tile \(tileCount): cropping failed")
                            return false
                        }
                        guard let padCtx = CGContext(
                            data: nil, width: tile, height: tile,
                            bitsPerComponent: 8, bytesPerRow: tile * 4,
                            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        ) else { return false }
                        padCtx.draw(partialCG, in: CGRect(x: 0, y: tile - cropH, width: cropW, height: cropH))
                        tileCG = padCtx.makeImage()
                    } else {
                        tileCG = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: tile, height: tile))
                    }

                    guard let tileCG,
                          let inputBuffer = Self.cgImageToPixelBuffer(tileCG, width: tile, height: tile) else {
                        LogManager.shared.log("CoreML", "tile \(tileCount): pixel buffer creation failed")
                        return false
                    }

                    do {
                        let input = try MLDictionaryFeatureProvider(dictionary: [inputKey: MLFeatureValue(pixelBuffer: inputBuffer)])
                        let output = try model.prediction(from: input)

                        var outputBuffer: CVPixelBuffer?
                        for name in output.featureNames {
                            if let buf = output.featureValue(for: name)?.imageBufferValue {
                                outputBuffer = buf
                                if tileCount == 1 {
                                    LogManager.shared.log("CoreML", "output '\(name)': \(CVPixelBufferGetWidth(buf))x\(CVPixelBufferGetHeight(buf))")
                                }
                                break
                            }
                        }

                        guard let outBuf = outputBuffer else {
                            if tileCount == 1 {
                                LogManager.shared.log("CoreML", "process: no image output, keys: \(Array(output.featureNames))")
                            }
                            return false
                        }

                        let outTileW = CVPixelBufferGetWidth(outBuf)
                        let outTileH = CVPixelBufferGetHeight(outBuf)
                        let actualScale = outTileW / tile
                        guard actualScale > 0 else { return false }

                        let outOvlp = ovlp * actualScale
                        // パディングされたタイルの場合、有効領域のみ使う
                        let effectiveCropW = cropW * actualScale
                        let effectiveCropH = cropH * actualScale

                        let cX = (cropX == 0) ? 0 : outOvlp
                        let cY = (cropY == 0) ? 0 : outOvlp
                        let cRight: Int
                        if cropW < tile {
                            // パディングされた辺: 有効ピクセルのみ
                            cRight = effectiveCropW
                        } else {
                            cRight = (cropX + tile >= srcW) ? outTileW : outTileW - outOvlp
                        }
                        let cBottom: Int
                        if cropH < tile {
                            cBottom = effectiveCropH
                        } else {
                            cBottom = (cropY + tile >= srcH) ? outTileH : outTileH - outOvlp
                        }
                        let cW = max(1, cRight - cX)
                        let cH = max(1, cBottom - cY)

                        let ciOut = CIImage(cvPixelBuffer: outBuf)
                        let ciCropRect = CGRect(x: cX, y: outTileH - cY - cH, width: cW, height: cH)
                        guard let croppedCG = ciCtx.createCGImage(ciOut, from: ciCropRect) else {
                            LogManager.shared.log("CoreML", "tile \(tileCount): ciCtx.createCGImage failed for rect \(ciCropRect)")
                            return false
                        }

                        let dstX = cropX * actualScale + cX
                        let dstY = cropY * actualScale + cY
                        let drawRect = CGRect(
                            x: dstX,
                            y: outH - dstY - cH,
                            width: cW,
                            height: cH
                        )
                        outputCtx.draw(croppedCG, in: drawRect)
                        return true
                    } catch {
                        if tileCount <= 3 {
                            LogManager.shared.log("CoreML", "process: tile \(tileCount) failed: \(error)")
                        }
                        return false
                    }
                }

                if !success { failCount += 1 }

                if tileX + tile >= srcW { break }
                x += step
            }
            if tileY + tile >= srcH { break }
            y += step
        }

        LogManager.shared.log("CoreML", "process: \(tileCount) tiles, \(failCount) failed")

        if failCount == tileCount {
            LogManager.shared.log("CoreML", "process: all tiles failed, returning original")
            Self.autoDisableAI()
            return image
        }

        guard let finalCG = outputCtx.makeImage() else {
            LogManager.shared.log("CoreML", "process: failed to create final image")
            return image
        }

        LogManager.shared.log("CoreML", "process: success \(srcW)x\(srcH) → \(finalCG.width)x\(finalCG.height)")
        return UIImage(cgImage: finalCG)
    }

    /// 画像がタイルサイズ以下の場合: パディング→1タイル推論→クロップ
    nonisolated private func processSinglePaddedTile(
        model: MLModel, cgImage: CGImage,
        srcW: Int, srcH: Int,
        image: PlatformImage
    ) throws -> PlatformImage {
        let tile = tileSize
        let scale = modelScale

        // 128x128にパディング（黒で埋める）
        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let padCtx = CGContext(
                data: nil, width: tile, height: tile,
                bitsPerComponent: 8, bytesPerRow: tile * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            LogManager.shared.log("CoreML", "padded: failed to create pad context")
            return image
        }
        // 左上に描画（CGContextはY軸下→上なので下寄せ）
        padCtx.draw(cgImage, in: CGRect(x: 0, y: tile - srcH, width: srcW, height: srcH))
        guard let paddedCG = padCtx.makeImage() else { return image }

        guard let inputBuffer = Self.cgImageToPixelBuffer(paddedCG, width: tile, height: tile) else {
            LogManager.shared.log("CoreML", "padded: failed to create pixel buffer")
            return image
        }

        let inputKey = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        let input = try MLDictionaryFeatureProvider(dictionary: [inputKey: MLFeatureValue(pixelBuffer: inputBuffer)])
        let output = try model.prediction(from: input)

        var outputBuffer: CVPixelBuffer?
        for name in output.featureNames {
            if let buf = output.featureValue(for: name)?.imageBufferValue {
                outputBuffer = buf
                LogManager.shared.log("CoreML", "padded output '\(name)': \(CVPixelBufferGetWidth(buf))x\(CVPixelBufferGetHeight(buf))")
                break
            }
        }

        guard let outBuf = outputBuffer else {
            LogManager.shared.log("CoreML", "padded: no image output, keys: \(Array(output.featureNames))")
            return image
        }

        let outTileW = CVPixelBufferGetWidth(outBuf)
        let outTileH = CVPixelBufferGetHeight(outBuf)
        let actualScale = outTileW / tile
        guard actualScale > 0 else { return image }

        // 出力から元画像サイズ分をクロップ
        let cropW = srcW * actualScale
        let cropH = srcH * actualScale
        let ciOut = CIImage(cvPixelBuffer: outBuf)
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
        // CIImageはY軸下→上: 元画像は上寄せ（CGContextで下寄せ描画したので出力でも上部に位置）
        let cropRect = CGRect(x: 0, y: outTileH - cropH, width: cropW, height: cropH)
        guard let croppedCG = ciCtx.createCGImage(ciOut, from: cropRect) else {
            LogManager.shared.log("CoreML", "padded: failed to crop output")
            return image
        }

        LogManager.shared.log("CoreML", "padded: success \(srcW)x\(srcH) → \(croppedCG.width)x\(croppedCG.height)")
        return UIImage(cgImage: croppedCG)
    }

    /// Lanczosアップスケールフォールバック（タイル数超過時）
    nonisolated private func lanczosUpscale(_ image: PlatformImage, scale: CGFloat) -> PlatformImage? {
        return LanczosUpscaler.shared.upscale(image, scale: scale)
    }

    /// 高解像度入力のフォールバック: CIFilterでシャープネス+ノイズ除去のみ
    nonisolated private func fallbackEnhance(_ image: PlatformImage) -> PlatformImage? {
        return autoreleasepool {
            guard let cgImage = image.cgImage else { return nil }
            var ciImage = CIImage(cgImage: cgImage)
            let ctx = CIContext(options: [.useSoftwareRenderer: false])

            if let f = CIFilter(name: "CINoiseReduction") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(0.02, forKey: "inputNoiseLevel")
                f.setValue(0.4, forKey: kCIInputSharpnessKey)
                if let out = f.outputImage { ciImage = out }
            }

            if let f = CIFilter(name: "CISharpenLuminance") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(0.5, forKey: kCIInputSharpnessKey)
                f.setValue(1.5, forKey: kCIInputRadiusKey)
                if let out = f.outputImage { ciImage = out }
            }

            guard let cg = ctx.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: cg)
        }
    }

    /// 空きメモリ取得
    nonisolated private static func availableMemory() -> Int {
        return Int(os_proc_available_memory())
    }

    /// エラー時にAI超解像を自動OFF
    nonisolated private static func autoDisableAI() {
        LogManager.shared.log("CoreML", "AUTO-DISABLE: turning off AI super resolution due to error/memory")
        DispatchQueue.main.async {
            UserDefaults.standard.set(false, forKey: "aiImageProcessing")
        }
    }

    nonisolated private static func cgImageToPixelBuffer(_ cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
    #endif
}
