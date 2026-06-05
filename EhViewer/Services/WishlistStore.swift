import Foundation
import Combine

/// Phase R-7: 店頭スキャン等で集めた「欲しい本」リスト。Documents/EhViewer/wishlist.json に永続化。
@MainActor
final class WishlistStore: ObservableObject {
    static let shared = WishlistStore()

    @Published private(set) var items: [WishlistItem] = []

    struct WishlistItem: Codable, Identifiable {
        let id: UUID
        var title: String
        var author: String?
        var isbn: String?
        var source: Source
        var addedDate: Date
        enum Source: String, Codable { case isbn, manual, ocr }
    }

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wishlist.json")
    }()

    init() { load() }

    func add(title: String, author: String? = nil, isbn: String? = nil, source: WishlistItem.Source) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // 重複排除: ISBN 一致 or タイトル完全一致
        if let isbn, items.contains(where: { $0.isbn == isbn }) { return }
        if items.contains(where: { $0.title == t }) { return }
        items.insert(WishlistItem(id: UUID(), title: t, author: author, isbn: isbn, source: source, addedDate: Date()), at: 0)
        save()
    }

    func remove(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) where i >= 0 && i < items.count {
            items.remove(at: i)
        }
        save()
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
              let decoded = try? JSONDecoder().decode([WishlistItem].self, from: data) else { return }
        items = decoded
    }
}
