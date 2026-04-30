import Foundation
import Combine

/// AdvancedSearchView の過去検索履歴を host (E-Hentai / ExHentai / nhentai) ごとに保存。
/// UserDefaults JSON 永続。最近 20 件、同一内容 (text+categories+languages) は最上位に統合。
struct SearchHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let hostKey: String
    let text: String
    let categories: [String]
    let languages: [String]
    let savedAt: Date

    var displayLabel: String {
        var parts: [String] = []
        if !text.isEmpty { parts.append("\"\(text)\"") }
        if !categories.isEmpty { parts.append(categories.joined(separator: "/")) }
        if !languages.isEmpty { parts.append(languages.joined(separator: "/")) }
        if parts.isEmpty { return "(空検索)" }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()
    private let key = "advancedSearchHistory.v1"
    private let limit = 20

    @Published private(set) var entries: [SearchHistoryEntry] = []

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func record(hostKey: String, text: String, categories: [String], languages: [String]) {
        // 完全空 (検索ワード/カテゴリ/言語すべて空) は履歴に残さない
        guard !(text.isEmpty && categories.isEmpty && languages.isEmpty) else { return }
        // 同一内容を除去 (host 含めて完全一致)
        entries.removeAll { e in
            e.hostKey == hostKey
            && e.text == text
            && e.categories == categories
            && e.languages == languages
        }
        let entry = SearchHistoryEntry(
            id: UUID(),
            hostKey: hostKey,
            text: text,
            categories: categories,
            languages: languages,
            savedAt: Date()
        )
        entries.insert(entry, at: 0)
        // host 別 limit。グローバル合計はゆるい制限。
        var perHostCount: [String: Int] = [:]
        var trimmed: [SearchHistoryEntry] = []
        for e in entries {
            let c = (perHostCount[e.hostKey] ?? 0) + 1
            if c > limit { continue }
            perHostCount[e.hostKey] = c
            trimmed.append(e)
        }
        entries = trimmed
        persist()
    }

    func entries(forHostKey hostKey: String) -> [SearchHistoryEntry] {
        entries.filter { $0.hostKey == hostKey }
    }

    func remove(_ entry: SearchHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear(hostKey: String) {
        entries.removeAll { $0.hostKey == hostKey }
        persist()
    }
}
