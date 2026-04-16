import Foundation
import Combine
import SwiftUI

enum FavoritesSort: String, CaseIterable {
    case dateDesc = "追加日・新しい順"
    case dateAsc = "追加日・古い順"
    case title = "タイトル順"
}

class FavoritesViewModel: ObservableObject {
    @Published var galleries: [Gallery] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasMore = false
    @Published var totalLoaded: Int = 0
    @Published var selectedCategory: Int = -1
    @Published var searchText: String = ""
    @Published var sortOrder: FavoritesSort = .dateDesc
    @Published var isFromCache = false
    @Published var lastUpdatedText: String = ""
    let host: GalleryHost = .exhentai

    private let client = EhClient.shared
    private let cache = FavoritesCache.shared
    private var nextPageURL: String?
    var allGalleries: [Gallery] = []

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func parsePostedDate(_ s: String) -> Date {
        Self.dateFormatter.date(from: s) ?? .distantPast
    }

    var displayGalleries: [Gallery] {
        var result = allGalleries

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.title.lowercased().contains(query) }
        }

        switch sortOrder {
        case .dateDesc: break
        case .dateAsc: result.reverse()
        case .title: result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }

        return result
    }

    /// キャッシュからのみ表示
    func loadFromCacheOnly() {
        let cached = cache.load()
        if !cached.isEmpty {
            allGalleries = cached
            totalLoaded = cached.count
            galleries = displayGalleries
            isFromCache = true
        }
        updateLastUpdatedText()
    }

    /// 差分更新: キャッシュが空なら全件取得、あれば1ページ差分
    func refreshFromServer() async {
        // キャッシュが空（初回 or 再インストール後）→ 全件取得
        if allGalleries.isEmpty {
            await fullRefreshFromServer()
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        isLoading = true
        errorMessage = nil

        do {
            let result = try await client.fetchFavorites(host: host, category: selectedCategory, page: 0)
            let serverFirst = result.galleries
            let serverGids = Set(serverFirst.map { $0.gid })

            // キャッシュの既存データ
            var merged = allGalleries

            // 1. サーバーの1ページ目にあるがキャッシュにないものを先頭に追加
            let cachedGids = Set(merged.map { $0.gid })
            var newItems: [Gallery] = []
            for g in serverFirst {
                if !cachedGids.contains(g.gid) {
                    newItems.append(g)
                }
            }
            if !newItems.isEmpty {
                merged.insert(contentsOf: newItems, at: 0)
            }

            // 2. サーバーの1ページ目にないがキャッシュの先頭付近にあるものを削除
            //    （お気に入りから外されたケース。ただし2ページ目以降のものは残す）
            let firstPageSize = serverFirst.count
            if firstPageSize > 0 && merged.count > firstPageSize {
                // キャッシュの先頭firstPageSize件の中で、サーバーにないものを削除
                var cleaned: [Gallery] = []
                for (i, g) in merged.enumerated() {
                    if i < firstPageSize + newItems.count {
                        // 先頭エリア: サーバーにあるものだけ残す
                        if serverGids.contains(g.gid) || i >= firstPageSize {
                            cleaned.append(g)
                        }
                    } else {
                        // 後方: そのまま残す
                        cleaned.append(g)
                    }
                }
                merged = cleaned
            }

            allGalleries = merged
            totalLoaded = allGalleries.count
            galleries = displayGalleries
            isFromCache = false
            cache.save(allGalleries)
            LogManager.shared.log("Perf", "refreshFromServer: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms total=\(allGalleries.count) new=\(newItems.count)")

            // サムネをバックグラウンドでプリフェッチ
            Task(priority: .background) {
                await Self.prefetchThumbnails(merged)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        updateLastUpdatedText()
    }

    /// 全件再取得（設定画面から呼ぶ）
    func fullRefreshFromServer() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        isLoading = true
        errorMessage = nil
        isFromCache = false

        var serverGalleries: [Gallery] = []

        do {
            let first = try await client.fetchFavorites(host: host, category: selectedCategory, page: 0)
            serverGalleries = first.galleries
            var nextURL = first.pageNumber.nextURL
            var hasMorePages = first.pageNumber.hasNext

            allGalleries = serverGalleries
            totalLoaded = allGalleries.count
            galleries = displayGalleries

            while hasMorePages {
                guard let url = nextURL else { break }
                await ExtremeMode.shared.delay(nanoseconds: 2_000_000_000)

                let result = try await client.fetchByURL(urlString: url, host: host)
                if result.galleries.isEmpty { break }

                serverGalleries.append(contentsOf: result.galleries)
                nextURL = result.pageNumber.nextURL
                hasMorePages = result.pageNumber.hasNext

                allGalleries = serverGalleries
                totalLoaded = allGalleries.count
                galleries = displayGalleries
            }

            cache.save(serverGalleries)
            LogManager.shared.log("Reader", "favorites full refresh: \(serverGalleries.count) items saved")
            LogManager.shared.log("Perf", "fullRefreshFromServer: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms total=\(serverGalleries.count)")

            // サムネをバックグラウンドでプリフェッチ
            Task(priority: .background) {
                await Self.prefetchThumbnails(serverGalleries)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        updateLastUpdatedText()
    }

    func applyFilter() {
        galleries = displayGalleries
    }

    // MARK: - サムネプリフェッチ

    /// サムネをバッチ並列プリフェッチ（background priority）
    static func prefetchThumbnails(_ galleries: [Gallery]) async {
        let urls = galleries.compactMap(\.coverURL).filter { url in
            ImageCache.shared.image(for: url) == nil && !ImageCache.shared.isLoading(url)
        }
        guard !urls.isEmpty else { return }
        LogManager.shared.log("Download", "\(urls.count) thumbnails to prefetch")

        let batchSize = 15
        for batchStart in stride(from: 0, to: urls.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, urls.count)
            let batch = Array(urls[batchStart..<batchEnd])

            await withTaskGroup(of: Void.self) { group in
                for url in batch {
                    group.addTask {
                        guard !ImageCache.shared.isLoading(url) else { return }
                        ImageCache.shared.setLoading(url)
                        defer { ImageCache.shared.removeLoading(url) }
                        do {
                            let data = try await EhClient.shared.fetchThumbData(url: url, host: .exhentai)
                            #if canImport(UIKit)
                            // GPU経由デコード（CachedImageViewと同じパターン）
                            let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
                            if let ciImage = CIImage(data: data),
                               let cgImage = ciCtx.createCGImage(ciImage, from: ciImage.extent) {
                                ImageCache.shared.setThumb(UIImage(cgImage: cgImage), for: url)
                                return
                            }
                            #endif
                            // GPUフォールバック
                            if let image = PlatformImage(data: data) {
                                ImageCache.shared.setThumb(image, for: url)
                            }
                        } catch {}
                    }
                }
            }
        }
        LogManager.shared.log("Download", "done")
    }

    /// 起動時にFavoritesCacheの未キャッシュサムネをプリフェッチ（最初の画面分のみ）
    static func prefetchCachedFavorites() {
        let cached = FavoritesCache.shared.load()
        guard !cached.isEmpty else { return }
        // GPU化済みなので多めにプリフェッチ（network律速のため上限は維持）
        let visible = Array(cached.prefix(200))
        Task(priority: .background) {
            await prefetchThumbnails(visible)
        }
    }

    private func updateLastUpdatedText() {
        if let date = cache.lastUpdated() {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale.current
            lastUpdatedText = formatter.localizedString(for: date, relativeTo: Date())
        } else {
            lastUpdatedText = "未取得"
        }
    }
}
