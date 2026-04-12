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

/// nhentai作品の履歴エントリ（NhGalleryをまるごと保持）
struct NhHistoryEntry: Codable, Identifiable, Hashable {
    var gallery: NhentaiClient.NhGallery
    var lastReadPage: Int
    var viewedDate: Date

    var id: Int { gallery.id }
}

/// HistoryViewで混在表示するための統合型
enum HistoryItem: Identifiable, Hashable {
    case eh(HistoryEntry)
    case nh(NhHistoryEntry)

    var id: String {
        switch self {
        case .eh(let e): return "eh_\(e.gid)"
        case .nh(let n): return "nh_\(n.id)"
        }
    }

    var viewedDate: Date {
        switch self {
        case .eh(let e): return e.viewedDate
        case .nh(let n): return n.viewedDate
        }
    }
}

class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published var entries: [HistoryEntry] = []
    @Published var nhEntries: [NhHistoryEntry] = []

    private let maxEntries = 500
    private let fileManager = FileManager.default

    private init() {
        load()
        loadNh()
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

    private var nhFilePath: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("history_nh.json")
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

    private func loadNh() {
        guard let data = try? Data(contentsOf: nhFilePath),
              let decoded = try? JSONDecoder().decode([NhHistoryEntry].self, from: data) else { return }
        nhEntries = decoded
    }

    private func saveNh() {
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(self.nhEntries) {
                try? data.write(to: self.nhFilePath)
            }
        }
    }

    // MARK: - 統合取得

    /// EH/NH エントリを時系列マージして返す
    var mergedItems: [HistoryItem] {
        let eh = entries.map { HistoryItem.eh($0) }
        let nh = nhEntries.map { HistoryItem.nh($0) }
        return (eh + nh).sorted { $0.viewedDate > $1.viewedDate }
    }

    var isEmpty: Bool { entries.isEmpty && nhEntries.isEmpty }

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

    // MARK: - nhentai 記録

    func recordNhentai(gallery: NhentaiClient.NhGallery, page: Int = 0) {
        if let idx = nhEntries.firstIndex(where: { $0.id == gallery.id }) {
            var entry = nhEntries[idx]
            entry.viewedDate = Date()
            entry.lastReadPage = max(entry.lastReadPage, page)
            entry.gallery = gallery
            nhEntries.remove(at: idx)
            nhEntries.insert(entry, at: 0)
        } else {
            let entry = NhHistoryEntry(
                gallery: gallery,
                lastReadPage: page,
                viewedDate: Date()
            )
            nhEntries.insert(entry, at: 0)
        }

        if nhEntries.count > maxEntries {
            nhEntries = Array(nhEntries.prefix(maxEntries))
        }
        saveNh()
    }

    func updateLastPageNh(id: Int, page: Int) {
        guard let idx = nhEntries.firstIndex(where: { $0.id == id }) else { return }
        if nhEntries[idx].lastReadPage < page {
            nhEntries[idx].lastReadPage = page
            saveNh()
        }
    }

    func clearAll() {
        entries.removeAll()
        nhEntries.removeAll()
        save()
        saveNh()
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
