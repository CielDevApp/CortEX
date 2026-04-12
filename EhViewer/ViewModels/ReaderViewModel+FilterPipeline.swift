import Foundation
import SwiftUI

// MARK: - フィルタパイプライン
extension ReaderViewModel {

    /// rawImageにフィルタチェーンを適用してholderに表示
    /// すべてのholderへの変更はMain thread上で行う（@Publishedの正しい伝播保証）
    func applyFilterPipeline(index: Int, raw: PlatformImage) {
        let capturedIndex = index

        Task { @MainActor in
            if self.processedPages.contains(capturedIndex) { return }

            // ECOモード: フィルタ全スキップ
            if EcoMode.shared.isEnabled {
                self.holder(for: capturedIndex).setLoaded(raw)
                self.processedPages.insert(capturedIndex)
                return
            }

            let enhanceFilterOn = LanczosUpscaler.shared.isEnhanceFilterEnabled
            let hdrOn = HDREnhancer.shared.isEnabled
            let mode = self.qualityMode
            let useAI = UserDefaults.standard.bool(forKey: "aiImageProcessing")
                && CoreMLImageProcessor.shared.modelAvailable
            let denoiseOn = UserDefaults.standard.bool(forKey: "denoiseEnabled")
            let noFilter = UserDefaults.standard.bool(forKey: "noFilterMode")

            // 無補正モード
            if noFilter {
                self.holder(for: capturedIndex).setLoaded(raw)
                self.processedPages.insert(capturedIndex)
                return
            }

            // 標準画質モード: NE人物セグメンテーション
            let usePersonSeg = (mode == 2) && !enhanceFilterOn && !hdrOn && !useAI && !denoiseOn

            // フィルタ不要ならそのまま表示
            if !enhanceFilterOn && !hdrOn && !useAI && !denoiseOn && !usePersonSeg {
                self.holder(for: capturedIndex).setLoaded(raw)
                self.processedPages.insert(capturedIndex)
                return
            }

            // 即表示（フィルタ完了まで仮表示）- Main thread上で確実に設定
            if self.holder(for: capturedIndex).image == nil {
                self.holder(for: capturedIndex).setLoaded(raw)
            }

            // サイズ情報は事前に取得（actor境界外でアクセスするため）
            let rawWidth = raw.pixelWidth
            let rawHeight = raw.pixelHeight

            // 重いフィルタ処理はバックグラウンドで
            Task.detached(priority: .userInitiated) {
                let original = raw
                var result = raw

                // CoreML 4x超解像
                if useAI {
                    LogManager.shared.log("Pipeline", "page \(capturedIndex): starting CoreML (input \(rawWidth)x\(rawHeight))")
                    let upscaled = await CoreMLImageProcessor.shared.process(result)
                    if let upscaled {
                        LogManager.shared.log("Pipeline", "page \(capturedIndex): CoreML success")
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
}
