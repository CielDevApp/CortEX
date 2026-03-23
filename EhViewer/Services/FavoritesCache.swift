import Foundation
import Combine

/// お気に入り一覧のディスクキャッシュ
class FavoritesCache: ObservableObject {
    static let shared = FavoritesCache()

    /// 変更カウンター（@Publishedで変更通知）
    @Published var version: Int = 0

    private let fileManager = FileManager.default

    private var cacheDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var cacheFileURL: URL {
        cacheDir.appendingPathComponent("favorites_cache.json")
    }

    private var timestampFileURL: URL {
        cacheDir.appendingPathComponent("favorites_timestamp.txt")
    }

    func load() -> [Gallery] {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return [] }
        return (try? JSONDecoder().decode([Gallery].self, from: data)) ?? []
    }

    func save(_ galleries: [Gallery]) {
        guard let data = try? JSONEncoder().encode(galleries) else { return }
        try? data.write(to: cacheFileURL)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: timestampFileURL, atomically: true, encoding: .utf8)
        version += 1
    }

    /// 最終更新日時
    func lastUpdated() -> Date? {
        guard let str = try? String(contentsOf: timestampFileURL, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    var hasCachedData: Bool {
        fileManager.fileExists(atPath: cacheFileURL.path)
    }

    /// お気に入りに追加（キャッシュ更新）
    func addToCache(_ gallery: Gallery) {
        var list = load()
        if !list.contains(where: { $0.gid == gallery.gid }) {
            list.insert(gallery, at: 0)
            save(list)
            LogManager.shared.log("Favorite", "cache: added gid=\(gallery.gid), total=\(list.count)")
        }
    }

    /// お気に入りから削除（キャッシュ更新）
    func removeFromCache(gid: Int) {
        var list = load()
        list.removeAll { $0.gid == gid }
        save(list)
        LogManager.shared.log("Favorite", "cache: removed gid=\(gid), total=\(list.count)")
    }
}
