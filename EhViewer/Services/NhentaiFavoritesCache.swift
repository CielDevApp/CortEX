import Foundation
import Combine

/// nhentaiお気に入りのディスクキャッシュ（E-HentaiのFavoritesCacheと同等）。
///
/// スレッド安全化 (A2-a, 2026-06-11): E-H 側 FavoritesCache と同じ理由・同じ方式。
/// in-memory キャッシュ (cachedList/cachedIds) を NSLock で保護し全メソッドを
/// nonisolated 化。NhGallery は NhPage 配列を内包しデコードが特に重い (~150ms) ため、
/// デコードは必ずロック外で行う。@Published version の更新だけ main へホップ。
final class NhentaiFavoritesCache: ObservableObject, @unchecked Sendable {
    static let shared = NhentaiFavoritesCache()

    /// 変更カウンター（@Publishedで変更通知、main でのみ更新）
    @Published var version: Int = 0

    private let stateLock = NSLock()
    nonisolated(unsafe) private var cachedList: [NhentaiClient.NhGallery]?
    nonisolated(unsafe) private var cachedIds: Set<Int>?

    nonisolated private var cacheDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    nonisolated private var cacheFileURL: URL {
        cacheDir.appendingPathComponent("nh_favorites_cache.json")
    }

    nonisolated private var timestampFileURL: URL {
        cacheDir.appendingPathComponent("nh_favorites_timestamp.txt")
    }

    // MARK: - 読み書き

    nonisolated func load() -> [NhentaiClient.NhGallery] {
        stateLock.lock()
        if let cached = cachedList {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()
        // デコード (~150ms) はロック外
        guard let data = try? Data(contentsOf: cacheFileURL),
              let list = try? JSONDecoder().decode([NhentaiClient.NhGallery].self, from: data) else { return [] }
        stateLock.lock()
        if cachedList == nil {
            cachedList = list
            cachedIds = Set(list.map { $0.id })
        }
        let result = cachedList ?? list
        stateLock.unlock()
        return result
    }

    nonisolated func save(_ galleries: [NhentaiClient.NhGallery]) {
        guard let data = try? JSONEncoder().encode(galleries) else { return }
        try? data.write(to: cacheFileURL)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: timestampFileURL, atomically: true, encoding: .utf8)
        stateLock.lock()
        cachedList = galleries
        cachedIds = Set(galleries.map { $0.id })
        stateLock.unlock()
        DispatchQueue.main.async {
            self.version += 1
        }
    }

    nonisolated func lastUpdated() -> Date? {
        guard let str = try? String(contentsOf: timestampFileURL, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    nonisolated var hasCachedData: Bool {
        FileManager.default.fileExists(atPath: cacheFileURL.path)
    }

    // MARK: - お気に入り追加/削除

    nonisolated func addToCache(_ gallery: NhentaiClient.NhGallery) {
        var list = load()
        if !list.contains(where: { $0.id == gallery.id }) {
            list.insert(gallery, at: 0)
            save(list)
            LogManager.shared.log("nhFav", "cache: added id=\(gallery.id), total=\(list.count)")
        }
    }

    nonisolated func removeFromCache(id: Int) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
        LogManager.shared.log("nhFav", "cache: removed id=\(id), total=\(list.count)")
    }

    nonisolated func contains(id: Int) -> Bool {
        stateLock.lock()
        let ids = cachedIds
        stateLock.unlock()
        if let ids { return ids.contains(id) }
        // 未ウォームの初回のみフォールバック (load() が ids も埋める)
        return load().contains { $0.id == id }
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
            let list: [NhentaiClient.NhGallery]
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([NhentaiClient.NhGallery].self, from: data) {
                list = decoded
            } else {
                list = []
            }
            self.stateLock.lock()
            if self.cachedList == nil {
                self.cachedList = list
                self.cachedIds = Set(list.map { $0.id })
            }
            self.stateLock.unlock()
        }
    }

    /// 最終更新テキスト
    nonisolated var lastUpdatedText: String {
        guard let date = lastUpdated() else { return "未取得" }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "たった今" }
        if diff < 3600 { return "\(Int(diff / 60))分前" }
        if diff < 86400 { return "\(Int(diff / 3600))時間前" }
        return "\(Int(diff / 86400))日前"
    }
}
