import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// コメント本文を `translationLang` AppStorage の言語に自動翻訳して表示する view。
/// iOS 18+ / macOS 15+ で Apple Translation Framework を使用、それ以下は素通し。
/// `autoTranslateComments` (default true) で ON/OFF。
///
/// 田中指示 2026-04-25「コメントの自動翻訳、設定してる言語に」。
struct TranslatedCommentText: View {
    let original: String
    @AppStorage("translationLang") private var translationLang = "ja"
    @AppStorage("autoTranslateComments") private var autoTranslate = true

    var body: some View {
        // Apple Translation Framework は Mac Catalyst だと 26.0+ 必要 (iOS 26 相当、まだ未提供)。
        // iPhone (iOS 18+) のみ翻訳、それ以外は原文表示で fallback。
        if #available(iOS 18.0, macCatalyst 26.0, *) {
            ModernTranslatedCommentText(original: original, targetLang: translationLang, enabled: autoTranslate)
        } else {
            Text(original)
                .font(.caption)
                .lineLimit(8)
        }
    }
}

@available(iOS 18.0, macCatalyst 26.0, *)
private struct ModernTranslatedCommentText: View {
    let original: String
    let targetLang: String
    let enabled: Bool

    @State private var translated: String?
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Text(translated ?? original)
            .font(.caption)
            .lineLimit(8)
            .task {
                guard enabled else { return }
                // 翻訳セッション設定。source=nil で自動検出、target は AppStorage の言語。
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: nil,
                        target: Locale.Language(identifier: targetLang)
                    )
                }
            }
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate(original)
                    if response.targetText != original {
                        translated = response.targetText
                    }
                } catch {
                    LogManager.shared.log("Translate", "comment translate failed: \(error.localizedDescription)")
                }
            }
    }
}
