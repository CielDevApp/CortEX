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
    }

    func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        currentPage += 1

        do {
            let query = buildQuery()
            let sort = sortMode == .popular ? "popular" : nil
            let result = try await NhentaiClient.search(query: query, page: currentPage, sort: sort)
            galleries.append(contentsOf: result.result)
            hasMore = currentPage < result.num_pages
        } catch {
            LogManager.shared.log("nhentai", "nextPage failed: \(error.localizedDescription)")
        }

        isLoading = false
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
