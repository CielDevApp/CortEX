import Foundation
import Metal
import MetalKit
#if canImport(UIKit)
import UIKit
#endif

/// Metal Compute Shaderでの画像処理
final class MetalImageProcessor: @unchecked Sendable {
    static let shared = MetalImageProcessor()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?
    private let textureLoader: MTKTextureLoader?
    let isAvailable: Bool

    /// Metal版を使うかCIFilter版を使うかのフラグ
    static var useMetalPipeline: Bool {
        UserDefaults.standard.bool(forKey: "useMetalPipeline")
    }

    /// FilterParamsのC互換レイアウト
    struct FilterParams {
        var sharpenStrength: Float
        var sharpenRadius: Float
        var toneCurveStrength: Float
        var hdrShadowAmount: Float
        var hdrHighlightAmount: Float
        var vibranceAmount: Float
        var localToneStrength: Float
        var enableSharpen: UInt32
        var enableToneCurve: UInt32
        var enableHDR: UInt32
        var enableVibrance: UInt32
        var enableLocalTone: UInt32
        var isGrayscale: UInt32
        var width: UInt32
        var height: UInt32
    }

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.device = nil; self.commandQueue = nil
            self.pipelineState = nil; self.textureLoader = nil
            self.isAvailable = false
            LogManager.shared.log("Metal", "no GPU device")
            return
        }

        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.textureLoader = MTKTextureLoader(device: device)

        var ps: MTLComputePipelineState?
        if let library = device.makeDefaultLibrary(),
           let function = library.makeFunction(name: "imageEnhance") {
            ps = try? device.makeComputePipelineState(function: function)
            LogManager.shared.log("Metal", "pipeline created: imageEnhance")
        } else {
            LogManager.shared.log("Metal", "failed to create pipeline")
        }
        self.pipelineState = ps
        self.isAvailable = ps != nil

        LogManager.shared.log("Metal", "available: \(ps != nil) device: \(device.name)")
    }

    /// 画像にフィルタチェーンを適用（Metal Compute Shader）
    nonisolated func process(
        _ image: PlatformImage,
        sharpen: Bool = false,
        hdr: Bool = false,
        toneCurve: Bool = false,
        vibrance: Bool = false,
        localTone: Bool = false
    ) -> PlatformImage? {
        #if canImport(UIKit)
        guard let device, let commandQueue, let pipelineState else { return nil }
        guard let cgImage = image.cgImage else { return nil }

        let start = CFAbsoluteTimeGetCurrent()
        let w = cgImage.width
        let h = cgImage.height

        // グレースケール判定
        let isGray = LanczosUpscaler.shared.isGrayscaleImage(cgImage)

        // 入力テクスチャ作成
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false
        )
        textureDesc.usage = [.shaderRead]
        guard let inputTexture = device.makeTexture(descriptor: textureDesc) else { return nil }

        // CGImage → MTLTexture
        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        inputTexture.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: w * 4
        )

        // 出力テクスチャ
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false
        )
        outDesc.usage = [.shaderWrite]
        guard let outputTexture = device.makeTexture(descriptor: outDesc) else { return nil }

        // パラメータ
        var params = FilterParams(
            sharpenStrength: 0.4,
            sharpenRadius: 1.0,
            toneCurveStrength: 0.8,
            hdrShadowAmount: 0.3,
            hdrHighlightAmount: 0.9,
            vibranceAmount: 0.15,
            localToneStrength: 0.5,
            enableSharpen: sharpen ? 1 : 0,
            enableToneCurve: toneCurve ? 1 : 0,
            enableHDR: hdr ? 1 : 0,
            enableVibrance: vibrance ? 1 : 0,
            enableLocalTone: localTone ? 1 : 0,
            isGrayscale: isGray ? 1 : 0,
            width: UInt32(w),
            height: UInt32(h)
        )

        // コマンド発行
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<FilterParams>.size, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (w + 15) / 16,
            height: (h + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // MTLTexture → UIImage（autoreleasepool でメモリ即解放）
        let resultImage: UIImage? = autoreleasepool {
            var outData = [UInt8](repeating: 0, count: w * h * 4)
            outputTexture.getBytes(
                &outData,
                bytesPerRow: w * 4,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )

            guard let outCtx = CGContext(
                data: &outData, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let outCG = outCtx.makeImage() else { return nil }

            return UIImage(cgImage: outCG)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        LogManager.shared.log("Metal", "process: \(w)x\(h) in \(String(format: "%.1f", elapsed * 1000))ms " +
              "sharpen=\(sharpen) hdr=\(hdr) tone=\(toneCurve) vibrance=\(vibrance) gray=\(isGray)")

        return resultImage
        #else
        return nil
        #endif
    }
}

// MARK: - isGrayscaleImage を公開

extension LanczosUpscaler {
    /// グレースケール判定（MetalImageProcessorから呼べるように公開）
    func isGrayscaleImage(_ cgImage: CGImage) -> Bool {
        if let cs = cgImage.colorSpace, cs.model == .monochrome { return true }
        guard let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let bpp = cgImage.bitsPerPixel / 8
        guard bpp >= 3 else { return true }
        let w = cgImage.width, h = cgImage.height
        let rowBytes = cgImage.bytesPerRow
        let step = max(1, min(w, h) / 16)
        var totalDiff = 0, count = 0
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                let offset = y * rowBytes + x * bpp
                let r = Int(ptr[offset]), g = Int(ptr[offset + 1]), b = Int(ptr[offset + 2])
                totalDiff += max(r, g, b) - min(r, g, b)
                count += 1
            }
        }
        guard count > 0 else { return false }
        return totalDiff / count < 10
    }
}
