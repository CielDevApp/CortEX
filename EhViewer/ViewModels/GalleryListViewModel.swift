import Foundation
import Combine
import SwiftUI

class GalleryListViewModel: ObservableObject {
    @Published var galleries: [Gallery] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText: String = ""
    @Published var hasMore: Bool = false
    var host: GalleryHost = .exhentai

    /// カテゴリフィルタ（f_cats値）。nilなら全カテゴリ
    var categoryFilter: Int?
    /// 検索クエリに追加する固定条件（例: "language:japanese"）
    var baseQuery: String?

    private let client = EhClient.shared
    private var nextPageURL: String?
    private var currentPage: Int = 0
    private var cacheKey: String?

    /// 検索 race 対策 (2026-04-27): Enter 連打 / 連続検索で前のリクエストを cancel。
    /// URLSession async API は Task キャンセル時に in-flight HTTP も中断する。
    private var searchTask: Task<Void, Never>?

    func loadGalleries(reset: Bool = true) async {
        if reset {
            currentPage = 0
            nextPageURL = nil
        }

        // まずキャッシュから即表示（reset時のみ）
        if reset, galleries.isEmpty {
            let key = listCacheKey()
            cacheKey = key
            if let cached = Self.loadListCache(key: key) {
                galleries = cached
                LogManager.shared.log("Reader", "gallery list: \(cached.count) items from list cache")
            } else {
                // 一覧キャッシュなし → お気に入りキャッシュで仮表示
                let favs = FavoritesCache.shared.load()
                if !favs.isEmpty {
                    galleries = favs
                    LogManager.shared.log("Reader", "gallery list: \(favs.count) items from favorites cache (placeholder)")
                }
            }
        }

        // キャッシュ/お気に入りで仮表示中はスピナー非表示
        if galleries.isEmpty {
            isLoading = true
        }
        errorMessage = nil

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let result: (galleries: [Gallery], pageNumber: PageNumber)

            if !reset, let nextURL = nextPageURL {
                result = try await client.fetchByURL(urlString: nextURL, host: host)
            } else {
                let query = buildQueryWithTagTranslation()
                result = try await client.fetchGalleryList(
                    host: host, page: currentPage,
                    searchQuery: query, categoryFilter: categoryFilter
                )
            }

            // 検索 race 対策: 後続の search() で cancel 済みなら結果を反映せず終了。
            if Task.isCancelled { return }

            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            LogManager.shared.log("Reader", "gallery list: \(result.galleries.count) items in \(String(format: "%.0f", elapsed))ms")
            LogManager.shared.log("Perf", "loadGalleries: \(Int(elapsed))ms count=\(result.galleries.count) page=\(currentPage) reset=\(reset)")

            if reset {
                galleries = result.galleries
                // キャッシュ保存
                if let key = cacheKey {
                    Self.saveListCache(result.galleries, key: key)
                }
            } else {
                // 田中報告 2026-04-27: 言ったり戻ったりで galleries に同 gid が入ると
                // LazyVGrid + .id(gid) で SwiftUI が同一 view と見なし row 抜け / 空白化。
                // append 時に重複除外。
                let existingGids = Set(galleries.map { $0.gid })
                let deduped = result.galleries.filter { !existingGids.contains($0.gid) }
                if deduped.count != result.galleries.count {
                    LogManager.shared.log("GalleryList", "dedupe append: \(result.galleries.count) → \(deduped.count) (skipped \(result.galleries.count - deduped.count) dup)")
                }
                galleries.append(contentsOf: deduped)
            }
            nextPageURL = result.pageNumber.nextURL
            hasMore = result.pageNumber.hasNext
        } catch is CancellationError {
            return
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }

        if Task.isCancelled { return }
        isLoading = false
    }

    // MARK: - 一覧キャッシュ

    private func listCacheKey() -> String {
        let query = buildQuery() ?? ""
        let cat = categoryFilter.map(String.init) ?? "all"
        return "list_\(cat)_\(query)".replacingOccurrences(of: " ", with: "_")
    }

    private static func cacheDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer/listcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func saveListCache(_ galleries: [Gallery], key: String) {
        Task.detached(priority: .utility) {
            let path = cacheDir().appendingPathComponent("\(key).json")
            if let data = try? JSONEncoder().encode(galleries) {
                try? data.write(to: path)
            }
        }
    }

    private static func loadListCache(key: String) -> [Gallery]? {
        let path = cacheDir().appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode([Gallery].self, from: data)
    }

    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        currentPage += 1
        await loadGalleries(reset: false)
    }

    func search() async {
        // 既存の検索 in-flight があれば cancel (Enter 連打 / 連続検索の race 防止)。
        searchTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadGalleries(reset: true)
        }
        searchTask = task
        await task.value
    }

    func refresh() async {
        await loadGalleries(reset: true)
    }

    private func buildQuery() -> String? {
        var parts: [String] = []
        if let base = baseQuery, !base.isEmpty {
            parts.append(base)
        }
        if !searchText.isEmpty {
            parts.append(searchText)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// タグ辞書翻訳付き検索クエリを構築
    func buildQueryWithTagTranslation() -> String? {
        var parts: [String] = []
        if let base = baseQuery, !base.isEmpty {
            parts.append(base)
        }
        if !searchText.isEmpty {
            parts.append(TagTranslator.translate(searchText))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
