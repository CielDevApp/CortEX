import Foundation

/// E-Hentai お気に入り一覧のディスクキャッシュ。
/// 実体は GalleryDiskCache<Gallery> (B1, 2026-06-11)。固有の呼び出し名 (containsFast(gid:)
/// / removeFromCache(gid:)) だけ薄いエイリアスで残し、既存 20+ 呼び出し元を不変にする。
final class FavoritesCache: GalleryDiskCache<Gallery>, @unchecked Sendable {
    static let shared = FavoritesCache()

    private init() {
        super.init(cacheFileName: "favorites_cache.json",
                   timestampFileName: "favorites_timestamp.txt",
                   logTag: "Favorite")
    }

    /// gid 高速参照 (リーダー init 等のホットパス用、憲兵令 2026-0610-001 真因対策)。
    nonisolated func containsFast(gid: Int) -> Bool { contains(id: gid) }

    /// gid ラベルの削除 (既存呼び出し元の互換維持)。
    nonisolated func removeFromCache(gid: Int) { removeFromCache(id: gid) }
}
