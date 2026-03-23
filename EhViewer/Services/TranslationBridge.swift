import Foundation

// TranslationBridge: Viewベースの .translationTask 経由に移行したため、
// このファイルからは原文フォールバックのみ提供
enum TranslationBridge {
    static func fallback(blocks: [TranslatedBlock]) -> [TranslatedBlock] {
        var result = blocks
        for i in result.indices { result[i].translatedText = result[i].originalText }
        return result
    }
}
