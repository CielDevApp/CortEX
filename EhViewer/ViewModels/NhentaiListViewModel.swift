import Foundation
import Combine

enum NhSortMode: String, CaseIterable {
    case recent = "recent"
    case popular = "popular"
}

class NhentaiListViewModel: ObservableObject {
    @Published var galleries: [NhentaiClient.NhGallery] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var searchText = ""
    @Published var isSearchActive = false
    @Published var sortMode: NhSortMode = .recent

    private var currentPage = 1

    func loadGalleries() async {
        guard !isLoading else { return }
        isLoading = true

        do {
            let query = buildQuery()
            let sort = sortMode == .popular ? "popular" : nil
            let result = try await NhentaiClient.search(query: query, page: 1, sort: sort)
            galleries = result.result
            hasMore = result.num_pages > 1
            currentPage = 1
        } catch {
            LogManager.shared.log("nhentai", "load failed: \(error.localizedDescription)")
        }

        isLoading = false
        Task { await enrichGalleries() }
    }

    func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let startIndex = galleries.count
        currentPage += 1

        do {
            let query = buildQuery()
            let sort = sortMode == .popular ? "popular" : nil
            let result = try await NhentaiClient.search(query: query, page: currentPage, sort: sort)
            // 田中報告 2026-04-27: append 時に同 id 重複除外 (LazyVGrid 空白化対策)
            let existingIDs = Set(galleries.map { $0.id })
            let deduped = result.result.filter { !existingIDs.contains($0.id) }
            galleries.append(contentsOf: deduped)
            hasMore = currentPage < result.num_pages
        } catch {
            LogManager.shared.log("nhentai", "nextPage failed: \(error.localizedDescription)")
        }

        isLoading = false
        Task { await enrichGalleries(from: startIndex) }
    }

    /// v2 search結果にnum_pagesがないので、バックグラウンドで詳細を取得して補完
    /// レート制限対策: 1.5秒間隔で順次取得
    @MainActor
    private func enrichGalleries(from startIndex: Int = 0) async {
        for i in startIndex..<galleries.count {
            guard galleries[i].num_pages == 0 else { continue }
            do {
                let full = try await NhentaiClient.fetchGallery(id: galleries[i].id)
                var updated = galleries
                updated[i] = full
                galleries = updated
            } catch {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    func search() async {
        isSearchActive = true
        await loadGalleries()
    }

    func refresh() async {
        galleries = []
        await loadGalleries()
    }

    func clearSearch() {
        searchText = ""
        isSearchActive = false
        Task { await refresh() }
    }

    /// 言語フィルタ（E-Hentaiの言語設定と連動）
    @Published var languageFilter: String?

    private func buildQuery() -> String {
        var parts: [String] = []
        if isSearchActive && !searchText.isEmpty {
            parts.append(TagTranslator.translate(searchText))
        }
        if let lang = languageFilter, !lang.isEmpty {
            parts.append(lang)
        }
        return parts.joined(separator: " ")
    }
}
