import Foundation
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// OCR認識結果 + 翻訳テキスト
struct TranslatedBlock: Identifiable {
    let id = UUID()
    let originalText: String
    var translatedText: String
    /// 画像座標系での正規化バウンディングボックス（0-1, Vision座標: 左下原点）
    let boundingBox: CGRect
    let confidence: Float
}

/// ページ単位の翻訳結果
struct PageTranslation {
    var blocks: [TranslatedBlock]
    var isTranslating: Bool
}

/// Vision OCR でページ内テキストを認識し、翻訳オーバーレイ用データを生成
final class TranslationService {
    static let shared = TranslationService()

    /// 翻訳結果キャッシュ（"gid_page" → result）
    private var cache: [String: PageTranslation] = [:]

    private init() {}

    private func cacheKey(gid: Int, page: Int) -> String { "\(gid)_\(page)" }

    func cached(gid: Int, page: Int) -> PageTranslation? {
        cache[cacheKey(gid: gid, page: page)]
    }

    func clearCache() { cache.removeAll() }

    /// 画像からOCRを実行し、テキストブロックを抽出
    func recognizeText(image: PlatformImage, gid: Int, page: Int) async -> PageTranslation {
        let key = cacheKey(gid: gid, page: page)
        if let cached = cache[key], !cached.isTranslating { return cached }

        #if canImport(UIKit)
        guard let cgImage = image.cgImage else {
            return PageTranslation(blocks: [], isTranslating: false)
        }

        let blocks = await performOCR(cgImage: cgImage)
        let result = PageTranslation(blocks: blocks, isTranslating: false)
        // 空結果はキャッシュしない（画像がプレースホルダーだった場合に再実行できるように）
        if !blocks.isEmpty {
            cache[key] = result
        }
        return result
        #else
        return PageTranslation(blocks: [], isTranslating: false)
        #endif
    }

    /// 翻訳済みブロックをキャッシュに保存
    func saveTranslated(gid: Int, page: Int, blocks: [TranslatedBlock]) {
        let key = cacheKey(gid: gid, page: page)
        cache[key] = PageTranslation(blocks: blocks, isTranslating: false)
    }

    // MARK: - OCR

    #if canImport(UIKit)
    private func performOCR(cgImage: CGImage) async -> [TranslatedBlock] {
        await withCheckedContinuation { continuation in
            var results: [TranslatedBlock] = []
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    // 短すぎるテキストやOCRノイズはスキップ
                    let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count < 2 { continue }

                    results.append(TranslatedBlock(
                        originalText: trimmed,
                        translatedText: "",
                        boundingBox: obs.boundingBox,
                        confidence: candidate.confidence
                    ))
                }
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja", "en", "zh-Hans", "zh-Hant", "ko"]
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
    #endif

    // MARK: - 言語検出

    static func detectLanguage(_ text: String) -> String {
        let tagger = NSLinguisticTagger(tagSchemes: [.language], options: 0)
        tagger.string = text
        return tagger.dominantLanguage ?? "und"
    }
}
