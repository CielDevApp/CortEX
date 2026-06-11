import Foundation
import Combine

/// お気に入り一覧のディスクキャッシュ。
///
/// スレッド安全化 (A2-a, 2026-06-11): load()/containsFast() は main (View body/init) だけで
/// なく背景コンテキスト (nonisolated な ImageCache.prewarmRecentThumbs や
/// FavoritesViewModel.prefetchThumbnails 等) からも呼ばれる。旧実装は in-memory キャッシュ
/// (cachedList/cachedGids) が無保護で、暗黙 @MainActor 前提が崩れた瞬間に COW 配列の
/// データ競合 (SIGSEGV 級) になり得た。NSLock で状態を保護し全メソッドを nonisolated 化、
/// どのスレッドから呼んでも安全にする。@Published version の更新だけ main へホップ。
final class FavoritesCache: ObservableObject, @unchecked Sendable {
    static let shared = FavoritesCache()

    /// 変更カウンター（@Publishedで変更通知、main でのみ更新）
    @Published var version: Int = 0

    /// cachedList/cachedGids の保護。重い処理 (JSON デコード/エンコード) はロック外で行う
    private let stateLock = NSLock()

    /// デコード済みリストの in-memory 保持。毎回ディスク読み + 全件 JSON デコードすると
    /// タブ常駐 body の再評価毎に main が 100ms 級で凍結する (2026-06-10 BlockSample 実測)。
    nonisolated(unsafe) private var cachedList: [Gallery]?

    /// gid 高速参照用 Set。リーダー init 等のホットパスは containsFast を使うこと
    /// (憲兵令 2026-0610-001 真因: init での load() フルデコードがスクロール凍結の主犯だった)。
    nonisolated(unsafe) private var cachedGids: Set<Int>?

    nonisolated private var cacheDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    nonisolated private var cacheFileURL: URL {
        cacheDir.appendingPathComponent("favorites_cache.json")
    }

    nonisolated private var timestampFileURL: URL {
        cacheDir.appendingPathComponent("favorites_timestamp.txt")
    }

    nonisolated func load() -> [Gallery] {
        stateLock.lock()
        if let cached = cachedList {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()
        // デコード (~100ms) はロック外: ロック中に行うと他スレッドの containsFast まで道連れ
        guard let data = try? Data(contentsOf: cacheFileURL),
              let list = try? JSONDecoder().decode([Gallery].self, from: data) else { return [] }
        stateLock.lock()
        if cachedList == nil {
            cachedList = list
            cachedGids = Set(list.map { $0.gid })
        }
        let result = cachedList ?? list
        stateLock.unlock()
        return result
    }

    nonisolated func containsFast(gid: Int) -> Bool {
        stateLock.lock()
        let gids = cachedGids
        stateLock.unlock()
        if let gids { return gids.contains(gid) }
        // 未ウォームの初回のみフォールバック (load() が gids も埋める)
        return load().contains { $0.gid == gid }
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
            let list: [Gallery]
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([Gallery].self, from: data) {
                list = decoded
            } else {
                list = []
            }
            self.stateLock.lock()
            if self.cachedList == nil {
                self.cachedList = list
                self.cachedGids = Set(list.map { $0.gid })
            }
            self.stateLock.unlock()
        }
    }

    nonisolated func save(_ galleries: [Gallery]) {
        guard let data = try? JSONEncoder().encode(galleries) else { return }
        try? data.write(to: cacheFileURL)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(to: timestampFileURL, atomically: true, encoding: .utf8)
        stateLock.lock()
        cachedList = galleries
        cachedGids = Set(galleries.map { $0.gid })
        stateLock.unlock()
        DispatchQueue.main.async { self.version += 1 }
    }

    /// 最終更新日時
    nonisolated func lastUpdated() -> Date? {
        guard let str = try? String(contentsOf: timestampFileURL, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    nonisolated var hasCachedData: Bool {
        FileManager.default.fileExists(atPath: cacheFileURL.path)
    }

    /// お気に入りに追加（キャッシュ更新）
    nonisolated func addToCache(_ gallery: Gallery) {
        var list = load()
        if !list.contains(where: { $0.gid == gallery.gid }) {
            list.insert(gallery, at: 0)
            save(list)
            LogManager.shared.log("Favorite", "cache: added gid=\(gallery.gid), total=\(list.count)")
        }
    }

    /// お気に入りから削除（キャッシュ更新）
    nonisolated func removeFromCache(gid: Int) {
        var list = load()
        list.removeAll { $0.gid == gid }
        save(list)
        LogManager.shared.log("Favorite", "cache: removed gid=\(gid), total=\(list.count)")
    }
}
