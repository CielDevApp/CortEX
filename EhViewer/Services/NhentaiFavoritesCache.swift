import Foundation

/// nhentai お気に入り一覧のディスクキャッシュ。
/// 実体は GalleryDiskCache<NhGallery> (B1, 2026-06-11)。E-H 版とロジック共通化済み。
/// NhGallery は NhPage 配列を内包しデコードが重い (~150ms) が、基底のロック外デコード
/// 規律で吸収される。
final class NhentaiFavoritesCache: GalleryDiskCache<NhentaiClient.NhGallery>, @unchecked Sendable {
    static let shared = NhentaiFavoritesCache()

    private init() {
        super.init(cacheFileName: "nh_favorites_cache.json",
                   timestampFileName: "nh_favorites_timestamp.txt",
                   logTag: "nhFav")
    }
}
