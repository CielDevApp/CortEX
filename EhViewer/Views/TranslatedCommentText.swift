import SwiftUI
#if canImport(Translation) && !targetEnvironment(macCatalyst)
import Translation
#endif

/// コメント本文を表示し、タップ式で OS 標準の翻訳 popover を出す view。
/// `.translationPresentation` (iOS 17.4+) を利用。Mac Catalyst では Translation framework
/// 全体が unavailable なので翻訳ボタンを表示しない (原文表示のみ)。
///
/// 田中指示 2026-04-25「自動翻訳というよりタップして翻訳の方がいい」。
struct TranslatedCommentText: View {
    let original: String
    @State private var showTranslation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(original)
                .font(.caption)
                .lineLimit(8)
            #if !targetEnvironment(macCatalyst)
            if #available(iOS 17.4, *) {
                Button {
                    showTranslation = true
                } label: {
                    Label("翻訳", systemImage: "translate")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .translationPresentation(isPresented: $showTranslation, text: original)
            }
            #endif
        }
    }
}
