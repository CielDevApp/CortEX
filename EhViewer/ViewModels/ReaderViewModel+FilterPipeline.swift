import Foundation
import SwiftUI

// MARK: - フィルタパイプライン
extension ReaderViewModel {

    /// rawImageにフィルタチェーンを適用してholderに表示
    func applyFilterPipeline(index: Int, raw: PlatformImage) {
        if processedPages.contains(index) { return }

        // ECOモード: フィルタ全スキップ
        if EcoMode.shared.isEnabled {
            holder(for: index).setLoaded(raw)
            processedPages.insert(index)
            return
        }

        let enhanceFilterOn = LanczosUpscaler.shared.isEnhanceFilterEnabled
        let hdrOn = HDREnhancer.shared.isEnabled
        let mode = qualityMode
        let useAI = UserDefaults.standard.bool(forKey: "aiImageProcessing")
            && CoreMLImageProcessor.shared.modelAvailable
        let denoiseOn = UserDefaults.standard.bool(forKey: "denoiseEnabled")
        let noFilter = UserDefaults.standard.bool(forKey: "noFilterMode")
        let capturedIndex = index

        // 無補正モード
        if noFilter {
            holder(for: capturedIndex).setLoaded(raw)
            processedPages.insert(capturedIndex)
            return
        }

        // 標準画質モード: NE人物セグメンテーション
        let usePersonSeg = (mode == 2) && !enhanceFilterOn && !hdrOn && !useAI && !denoiseOn

        // フィルタ不要ならそのまま表示
        if !enhanceFilterOn && !hdrOn && !useAI && !denoiseOn && !usePersonSeg {
            holder(for: capturedIndex).setLoaded(raw)
            processedPages.insert(capturedIndex)
            return
        }

        // 即表示（フィルタ完了まで仮表示）
        if holder(for: capturedIndex).image == nil {
            holder(for: capturedIndex).setLoaded(raw)
        }

        Task.detached(priority: .userInitiated) {
            let original = raw
            var result = raw

            // CoreML 4x超解像
            if useAI {
                LogManager.shared.log("Pipeline", "page \(capturedIndex): starting CoreML (input \(raw.pixelWidth)x\(raw.pixelHeight))")
                let upscaled = await CoreMLImageProcessor.shared.process(result)
                if let upscaled {
                    LogManager.shared.log("Pipeline", "page \(capturedIndex): CoreML success (\(upscaled.pixelWidth)x\(upscaled.pixelHeight))")
                    result = upscaled
                } else {
                    LogManager.shared.log("Pipeline", "page \(capturedIndex): CoreML returned nil, keeping original")
                }
            }

            // ノイズ除去
            if denoiseOn {
                result = Self.applyDenoiseStatic(result) ?? result
            }

            // 画像補正フィルタ
            if enhanceFilterOn {
                result = LanczosUpscaler.shared.enhanceFilter(result) ?? result
            }
            // HDR排他
            if hdrOn && !enhanceFilterOn {
                result = HDREnhancer.shared.enhance(result) ?? result
            }

            // NE人物セグメンテーション
            #if canImport(UIKit)
            if usePersonSeg || mode == 2 {
                if let enhanced = LanczosUpscaler.shared.applyPersonSegmentation(result) {
                    result = enhanced
                }
            }
            #endif

            // 安全チェック
            if result.cgImage == nil { result = original }

            await MainActor.run {
                self.holder(for: capturedIndex).setLoaded(result)
                self.processedPages.insert(capturedIndex)
            }
        }
    }
}
