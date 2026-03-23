import Foundation
import Combine

/// nhentaiお気に入りのディスクキャッシュ（E-HentaiのFavoritesCacheと同等）
class NhentaiFavoritesCache: ObservableObject {
    static let shared = NhentaiFavoritesCache()

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
        cacheDir.appendingPathComponent("nh_favorites_cache.json")
    }

    private var timestampFileURL: URL {
        cacheDir.appendingPathComponent("nh_favorites_timestamp.txt")
    }

    // MARK: - 読み書き

    func load() -> [NhentaiClient.NhGallery] {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return [] }
        return (try? JSONDecoder().decode([NhentaiClient.NhGallery].self, from: data)) ?? []
    }

    func save(_ galleries: [NhentaiClient.NhGallery]) {
        guard let data = try? JSONEncoder().encode(galleries) else { return }
        try? data.write(to: cacheFileURL)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: timestampFileURL, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            self.version += 1
        }
    }

    func lastUpdated() -> Date? {
        guard let str = try? String(contentsOf: timestampFileURL, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    var hasCachedData: Bool {
        fileManager.fileExists(atPath: cacheFileURL.path)
    }

    // MARK: - お気に入り追加/削除

    func addToCache(_ gallery: NhentaiClient.NhGallery) {
        var list = load()
        if !list.contains(where: { $0.id == gallery.id }) {
            list.insert(gallery, at: 0)
            save(list)
            LogManager.shared.log("nhFav", "cache: added id=\(gallery.id), total=\(list.count)")
        }
    }

    func removeFromCache(id: Int) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
        LogManager.shared.log("nhFav", "cache: removed id=\(id), total=\(list.count)")
    }

    func contains(id: Int) -> Bool {
        load().contains { $0.id == id }
    }

    /// 最終更新テキスト
    var lastUpdatedText: String {
        guard let date = lastUpdated() else { return "未取得" }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "たった今" }
        if diff < 3600 { return "\(Int(diff / 60))分前" }
        if diff < 86400 { return "\(Int(diff / 3600))時間前" }
        return "\(Int(diff / 86400))日前"
    }
}
