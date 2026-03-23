import Foundation
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - @Generable 構造体（iOS 26+）

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GenreClassificationResult {
    /// 推定ジャンル（vanilla/ntr/femdom/yuri/yaoi/other）
    var genre: String
    /// 確信度（0.0〜1.0）
    var confidence: Double
}

@available(iOS 26.0, *)
@Generable
struct RecommendationResult {
    /// 提案するタグの組み合わせ（例: ["big_breasts, maid", "elf, fantasy"]）
    var suggestions: [String]
}
#endif

// MARK: - AIFeatures

/// Apple Intelligence機能管理（iOS 26+ / Foundation Models）
final class AIFeatures: ObservableObject {
    static let shared = AIFeatures()

    @Published var isAvailable = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "aiGenreClassification") }
    }

    /// おすすめタグ（履歴分析結果）
    @Published var recommendedTags: [String] = []
    /// ジャンル分類結果キャッシュ
    @Published var genreCache: [Int: String] = [:] // gid → genre

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "aiGenreClassification")
        checkAvailability()
    }

    private func checkAvailability() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            Task { await checkModelAvailability() }
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func checkModelAvailability() async {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            await MainActor.run { self.isAvailable = true }
            LogManager.shared.log("AI", "Foundation Models available")
        default:
            await MainActor.run { self.isAvailable = false }
            LogManager.shared.log("AI", "Foundation Models not available: \(model.availability)")
        }
    }
    #endif

    // MARK: - ジャンル分類

    func classifyGallery(gid: Int, tags: [String]) async -> String? {
        guard isAvailable && isEnabled && !EcoMode.shared.isEnabled else { return nil }
        if let cached = genreCache[gid] { return cached }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await performClassification(gid: gid, tags: tags)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func performClassification(gid: Int, tags: [String]) async -> String? {
        let instructions = """
        Given a list of E-Hentai tags, classify the genre of the work.
        Choose exactly one genre from: vanilla, ntr, femdom, yuri, yaoi, other
        Return a confidence score between 0.0 and 1.0.
        """

        let prompt = "Tags: \(tags.joined(separator: ", "))"

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: GenreClassificationResult.self)
            let genre = response.content.genre
            let confidence = response.content.confidence
            LogManager.shared.log("AI", "genre classification: gid=\(gid) genre=\(genre) confidence=\(String(format: "%.2f", confidence))")

            await MainActor.run {
                self.genreCache[gid] = genre
            }
            return genre
        } catch {
            LogManager.shared.log("AI", "genre classification failed: \(error.localizedDescription)")
            return nil
        }
    }
    #endif

    // MARK: - おすすめタグ分析

    func analyzeRecommendations(history: [(tags: [String], count: Int)]) async {
        guard !EcoMode.shared.isEnabled else { return }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            await performSmartRecommendation(history: history)
            return
        }
        #endif

        // フォールバック: 単純な頻度分析
        await performSimpleRecommendation(history: history)
    }

    /// フォールバック: 頻度ベースのおすすめ
    private func performSimpleRecommendation(history: [(tags: [String], count: Int)]) async {
        var freq: [String: Int] = [:]
        for entry in history {
            for tag in entry.tags {
                freq[tag, default: 0] += entry.count
            }
        }
        let top = freq.sorted { $0.value > $1.value }.prefix(10).map(\.key)
        await MainActor.run {
            self.recommendedTags = Array(top)
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func performSmartRecommendation(history: [(tags: [String], count: Int)]) async {
        let instructions = """
        Analyze the user's E-Hentai browsing history tag frequency data.
        Suggest 3 tag combinations the user might enjoy next.
        Each suggestion should be a comma-separated string of E-Hentai tags (e.g. "big breasts, maid").
        """

        // 上位タグを抽出してプロンプトに
        var freq: [String: Int] = [:]
        for entry in history {
            for tag in entry.tags { freq[tag, default: 0] += entry.count }
        }
        let topTags = freq.sorted { $0.value > $1.value }.prefix(20)
        let prompt = "View frequency:\n" + topTags.map { "- \($0.key): \($0.value) times" }.joined(separator: "\n")

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: RecommendationResult.self)
            let suggestions = response.content.suggestions
            LogManager.shared.log("AI", "smart recommendations: \(suggestions)")

            await MainActor.run {
                self.recommendedTags = suggestions
            }
        } catch {
            LogManager.shared.log("AI", "smart recommendation failed: \(error.localizedDescription), falling back")
            await performSimpleRecommendation(history: history)
        }
    }
    #endif
}
