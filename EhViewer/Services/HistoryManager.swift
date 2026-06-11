import Foundation
import Combine

/// 履歴エントリ共通インターフェース (B2, 2026-06-11)。
/// eh/nh で完全複製だった load/save/upsert/updateLastPage を HistoryOps に集約するための制約。
nonisolated protocol HistoryRecordable: Codable, Identifiable, Sendable where ID == Int {
    var lastReadPage: Int { get set }
    var viewedDate: Date { get set }
}

nonisolated struct HistoryEntry: Codable, Identifiable, Hashable, HistoryRecordable {
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
nonisolated struct NhHistoryEntry: Codable, Identifiable, Hashable, HistoryRecordable {
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

/// 履歴の共通操作 (B2): eh/nh の load/save/upsert/updateLastPage を 1 箇所に集約。
/// 配列を inout で受けて HistoryManager の @Published entries/nhEntries をそのまま操作するため、
/// 観測経路・公開 API を一切変えずに重複だけを排除する。
private enum HistoryOps {
    static func load<E: Decodable>(from url: URL) -> [E]? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([E].self, from: data) else { return nil }
        return decoded
    }

    static func save<E: Encodable & Sendable>(_ entries: [E], to url: URL) {
        // snapshot を値コピーで捕捉してから detach (A2-b 由来、main 側 mutate と非競合)
        let snapshot = entries
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    /// 既存なら viewedDate/lastReadPage を更新 + 型固有フィールドを updateExisting で反映して
    /// 先頭へ移動、無ければ makeNew を先頭挿入。上限超過は古い順に切り詰め。
    static func upsert<E: HistoryRecordable>(
        in entries: inout [E], id: Int, page: Int, max: Int,
        makeNew: () -> E, updateExisting: (inout E) -> Void
    ) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            var e = entries[idx]
            e.viewedDate = Date()
            e.lastReadPage = Swift.max(e.lastReadPage, page)
            updateExisting(&e)
            entries.remove(at: idx)
            entries.insert(e, at: 0)
        } else {
            entries.insert(makeNew(), at: 0)
        }
        if entries.count > max {
            entries = Array(entries.prefix(max))
        }
    }

    /// lastReadPage を前進させた場合のみ true (呼び出し側が save 要否を判断)。
    static func updateLastPage<E: HistoryRecordable>(in entries: inout [E], id: Int, page: Int) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return false }
        if entries[idx].lastReadPage < page {
            entries[idx].lastReadPage = page
            return true
        }
        return false
    }
}

@MainActor
class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published var entries: [HistoryEntry] = []
    @Published var nhEntries: [NhHistoryEntry] = []

    private let maxEntries = 500
    private let fileManager = FileManager.default

    private init() {
        entries = HistoryOps.load(from: filePath) ?? []
        nhEntries = HistoryOps.load(from: nhFilePath) ?? []
    }

    // MARK: - ファイルパス

    private var filePath: URL { historyDir.appendingPathComponent("history.json") }
    private var nhFilePath: URL { historyDir.appendingPathComponent("history_nh.json") }

    private var historyDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
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
        HistoryOps.upsert(
            in: &entries, id: gallery.gid, page: page, max: maxEntries,
            makeNew: {
                HistoryEntry(
                    gid: gallery.gid, token: gallery.token, title: gallery.title,
                    coverURL: gallery.coverURL, category: gallery.category?.rawValue,
                    rating: gallery.rating, pageCount: gallery.pageCount,
                    lastReadPage: page, viewedDate: Date()
                )
            },
            updateExisting: { $0.title = gallery.title; $0.coverURL = gallery.coverURL }
        )
        HistoryOps.save(entries, to: filePath)
    }

    /// リーダーでページが進んだときに最終ページを更新
    func updateLastPage(gid: Int, page: Int) {
        if HistoryOps.updateLastPage(in: &entries, id: gid, page: page) {
            HistoryOps.save(entries, to: filePath)
        }
    }

    // MARK: - nhentai 記録

    func recordNhentai(gallery: NhentaiClient.NhGallery, page: Int = 0) {
        HistoryOps.upsert(
            in: &nhEntries, id: gallery.id, page: page, max: maxEntries,
            makeNew: { NhHistoryEntry(gallery: gallery, lastReadPage: page, viewedDate: Date()) },
            updateExisting: { $0.gallery = gallery }
        )
        HistoryOps.save(nhEntries, to: nhFilePath)
    }

    func updateLastPageNh(id: Int, page: Int) {
        if HistoryOps.updateLastPage(in: &nhEntries, id: id, page: page) {
            HistoryOps.save(nhEntries, to: nhFilePath)
        }
    }

    func clearAll() {
        entries.removeAll()
        nhEntries.removeAll()
        HistoryOps.save(entries, to: filePath)
        HistoryOps.save(nhEntries, to: nhFilePath)
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
