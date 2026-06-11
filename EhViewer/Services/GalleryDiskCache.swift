import Foundation
import Combine

/// お気に入り一覧のディスクキャッシュ共通基盤 (B1, 2026-06-11)。
///
/// E-H 版 FavoritesCache と nh 版 NhentaiFavoritesCache はコピペ度 95% で、本日 2 回
/// 同型バグを両方に手で書いた (BlockSample デコード / スレッド安全化)。重複を排し
/// 「片側だけ直してもう片側に残る」事故を構造的に防ぐためジェネリック化する。
///
/// スレッド安全 (A2-a 由来): load()/contains() は main (View body/init) と背景
/// (nonisolated な prewarm/prefetch) の両方から呼ばれる。in-memory 状態を NSLock で
/// 保護し全メソッドを nonisolated 化、重い JSON デコード/エンコードは必ずロック外で実行。
/// @Published version の更新だけ main へホップ。
///
/// 要件: 要素は Codable & Identifiable & Sendable で ID == Int (Gallery.id=gid /
/// NhGallery.id=id とも Int)。
class GalleryDiskCache<Element: Codable & Identifiable & Sendable>: ObservableObject, @unchecked Sendable
    where Element.ID == Int {

    /// 変更カウンター（@Publishedで変更通知、main でのみ更新）
    @Published var version: Int = 0

    private let cacheFileName: String
    private let timestampFileName: String
    private let logTag: String

    private let stateLock = NSLock()
    nonisolated(unsafe) private var cachedList: [Element]?
    nonisolated(unsafe) private var cachedIDs: Set<Int>?

    init(cacheFileName: String, timestampFileName: String, logTag: String) {
        self.cacheFileName = cacheFileName
        self.timestampFileName = timestampFileName
        self.logTag = logTag
    }

    nonisolated private var cacheDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    nonisolated private var cacheFileURL: URL { cacheDir.appendingPathComponent(cacheFileName) }
    nonisolated private var timestampFileURL: URL { cacheDir.appendingPathComponent(timestampFileName) }

    nonisolated func load() -> [Element] {
        stateLock.lock()
        if let cached = cachedList {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()
        // デコード (~100-150ms) はロック外: ロック中だと他スレッドの contains まで道連れ
        guard let data = try? Data(contentsOf: cacheFileURL),
              let list = try? JSONDecoder().decode([Element].self, from: data) else { return [] }
        stateLock.lock()
        if cachedList == nil {
            cachedList = list
            cachedIDs = Set(list.map { $0.id })
        }
        let result = cachedList ?? list
        stateLock.unlock()
        return result
    }

    nonisolated func contains(id: Int) -> Bool {
        stateLock.lock()
        let ids = cachedIDs
        stateLock.unlock()
        if let ids { return ids.contains(id) }
        // 未ウォームの初回のみフォールバック (load() が IDs も埋める)
        return load().contains { $0.id == id }
    }

    nonisolated func save(_ items: [Element]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: cacheFileURL)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: timestampFileURL, atomically: true, encoding: .utf8)
        stateLock.lock()
        cachedList = items
        cachedIDs = Set(items.map { $0.id })
        stateLock.unlock()
        DispatchQueue.main.async { self.version += 1 }
    }

    /// 起動時の背景ウォームアップ。初回 load のフルデコードが main で走るのを防ぐ。
    nonisolated func warmUpInBackground() {
        stateLock.lock()
        let warmed = cachedList != nil
        stateLock.unlock()
        guard !warmed else { return }
        let url = cacheFileURL
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let list: [Element]
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([Element].self, from: data) {
                list = decoded
            } else {
                list = []
            }
            self.stateLock.lock()
            if self.cachedList == nil {
                self.cachedList = list
                self.cachedIDs = Set(list.map { $0.id })
            }
            self.stateLock.unlock()
        }
    }

    nonisolated func addToCache(_ item: Element) {
        var list = load()
        if !list.contains(where: { $0.id == item.id }) {
            list.insert(item, at: 0)
            save(list)
            LogManager.shared.log(logTag, "cache: added id=\(item.id), total=\(list.count)")
        }
    }

    nonisolated func removeFromCache(id: Int) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
        LogManager.shared.log(logTag, "cache: removed id=\(id), total=\(list.count)")
    }

    nonisolated func lastUpdated() -> Date? {
        guard let str = try? String(contentsOf: timestampFileURL, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    nonisolated var hasCachedData: Bool {
        FileManager.default.fileExists(atPath: cacheFileURL.path)
    }

    /// 最終更新の相対表記 ("3分前" 等)。
    nonisolated var lastUpdatedText: String {
        guard let date = lastUpdated() else { return "未取得" }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "たった今" }
        if diff < 3600 { return "\(Int(diff / 60))分前" }
        if diff < 86400 { return "\(Int(diff / 3600))時間前" }
        return "\(Int(diff / 86400))日前"
    }
}
