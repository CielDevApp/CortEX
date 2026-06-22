import Foundation
import Combine

/// 新作通知機能 (Phase 3): フォロー/購読リスト。好きなタグ・投稿者・キーワードを登録し、
/// 新作がアップされたら通知する仕組みの「購読定義」を保持する。
/// Documents/EhViewer/subscriptions.json に永続化 ([[WishlistStore]] と同方式)。
/// 実際の新着検知・通知送信は Mac 側ポーラー(ReCap 相乗り)が担当 (Phase 2)。
@MainActor
final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()

    @Published private(set) var items: [SubscriptionItem] = []

    struct SubscriptionItem: Codable, Identifiable {
        let id: UUID
        var kind: Kind
        var value: String        // タグ名 / 投稿者名 / キーワード
        var label: String        // 表示名 (空なら value を表示)
        var addedDate: Date

        enum Kind: String, Codable, CaseIterable {
            case tag, uploader, keyword
            var displayName: String {
                switch self {
                case .tag: return "タグ"
                case .uploader: return "投稿者"
                case .keyword: return "キーワード"
                }
            }
            var icon: String {
                switch self {
                case .tag: return "tag.fill"
                case .uploader: return "person.fill"
                case .keyword: return "magnifyingglass"
                }
            }
        }

        var displayLabel: String { label.isEmpty ? value : label }

        /// E-Hentai 検索クエリ (Mac ポーラーが新着取得に使う)。
        /// タグは namespace 付き(`female:sole female`等)なら tag: 構文、それ以外は引用符検索。
        var searchQuery: String {
            switch kind {
            case .tag:
                // namespace 付き(`female:sole female`)は E-H 正式構文 `female:"sole female"` に。
                if let colon = value.firstIndex(of: ":") {
                    let ns = String(value[..<colon])
                    let name = String(value[value.index(after: colon)...])
                    return "\(ns):\"\(name)\""
                }
                return "\"\(value)\""
            case .uploader:
                return "uploader:\(value)"
            case .keyword:
                return value
            }
        }
    }

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("subscriptions.json")
    }()

    init() { load() }

    /// 購読を追加。同 kind + value の重複は無視。
    @discardableResult
    func add(kind: SubscriptionItem.Kind, value: String, label: String = "") -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return false }
        if items.contains(where: { $0.kind == kind && $0.value.caseInsensitiveCompare(v) == .orderedSame }) {
            return false  // 既に購読済み
        }
        let item = SubscriptionItem(
            id: UUID(), kind: kind, value: v,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            addedDate: Date()
        )
        items.insert(item, at: 0)
        save()
        return true
    }

    func remove(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) where i >= 0 && i < items.count {
            items.remove(at: i)
        }
        save()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// kind + value 指定で削除 (詳細ページの長押しトグルで購読解除する用)。
    func remove(kind: SubscriptionItem.Kind, value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        items.removeAll { $0.kind == kind && $0.value.caseInsensitiveCompare(v) == .orderedSame }
        save()
    }

    /// 既に購読済みか (UI の「購読/解除」トグル表示用)。
    func isSubscribed(kind: SubscriptionItem.Kind, value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.contains { $0.kind == kind && $0.value.caseInsensitiveCompare(v) == .orderedSame }
    }

    private func save() {
        let snapshot = items
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SubscriptionItem].self, from: data) else { return }
        items = decoded
    }
}
