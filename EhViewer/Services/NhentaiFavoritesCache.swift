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

    /// id 高速参照用の in-memory Set (E-H 側 FavoritesCache.containsFast と同根の対策)。
    /// contains() が毎回全件 JSON デコードしており、NhentaiReaderView.init から呼ばれる
    /// ホットパスで main を塞いでいた。
    private var cachedIds: Set<Int>?

    func save(_ galleries: [NhentaiClient.NhGallery]) {
        guard let data = try? JSONEncoder().encode(galleries) else { return }
        try? data.write(to: cacheFileURL)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: timestampFileURL, atomically: true, encoding: .utf8)
        cachedIds = Set(galleries.map { $0.id })
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
        if cachedIds == nil { cachedIds = Set(load().map { $0.id }) }
        return cachedIds?.contains(id) ?? false
    }

    /// 起動時の背景ウォームアップ (E-H 側と同根)。NhGallery は NhPage 配列を内包するため
    /// 初回デコードが特に重く、main で走ると BlockSample に写るレベルだった。
    func warmUpInBackground() {
        guard cachedIds == nil else { return }
        let url = cacheFileURL
        Task.detached(priority: .utility) {
            let ids: Set<Int>
            if let data = try? Data(contentsOf: url),
               let list = try? JSONDecoder().decode([NhentaiClient.NhGallery].self, from: data) {
                ids = Set(list.map { $0.id })
            } else {
                ids = []
            }
            await MainActor.run { [weak self] in
                if self?.cachedIds == nil { self?.cachedIds = ids }
            }
        }
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
