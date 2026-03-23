import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Hashable {
    var gid: Int
    var token: String
    var title: String
    var coverURL: URL?
    var category: String?
    var rating: Double
    var pageCount: Int
    var lastReadPage: Int
    var viewedDate: Date

    var id: Int { gid }
}

class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published var entries: [HistoryEntry] = []

    private let maxEntries = 500
    private let fileManager = FileManager.default

    private init() {
        load()
    }

    // MARK: - ファイルパス

    private var filePath: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("history.json")
    }

    // MARK: - 永続化

    private func load() {
        guard let data = try? Data(contentsOf: filePath),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(self.entries) {
                try? data.write(to: self.filePath)
            }
        }
    }

    // MARK: - 記録

    func record(gallery: Gallery, page: Int = 0) {
        if let idx = entries.firstIndex(where: { $0.gid == gallery.gid }) {
            // 既存エントリを更新
            var entry = entries[idx]
            entry.viewedDate = Date()
            entry.lastReadPage = max(entry.lastReadPage, page)
            entry.title = gallery.title
            entry.coverURL = gallery.coverURL
            entries.remove(at: idx)
            entries.insert(entry, at: 0)
        } else {
            // 新規追加
            let entry = HistoryEntry(
                gid: gallery.gid,
                token: gallery.token,
                title: gallery.title,
                coverURL: gallery.coverURL,
                category: gallery.category?.rawValue,
                rating: gallery.rating,
                pageCount: gallery.pageCount,
                lastReadPage: page,
                viewedDate: Date()
            )
            entries.insert(entry, at: 0)
        }

        // 上限チェック
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        save()
    }

    /// リーダーでページが進んだときに最終ページを更新
    func updateLastPage(gid: Int, page: Int) {
        guard let idx = entries.firstIndex(where: { $0.gid == gid }) else { return }
        if entries[idx].lastReadPage < page {
            entries[idx].lastReadPage = page
            save()
        }
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    func toGallery(_ entry: HistoryEntry) -> Gallery {
        Gallery(
            gid: entry.gid,
            token: entry.token,
            title: entry.title,
            category: entry.category.flatMap { GalleryCategory(rawValue: $0) },
            coverURL: entry.coverURL,
            rating: entry.rating,
            pageCount: entry.pageCount,
            postedDate: "",
            uploader: nil,
            tags: []
        )
    }
}
