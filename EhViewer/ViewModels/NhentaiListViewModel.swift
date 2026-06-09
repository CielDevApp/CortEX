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
    /// 取得失敗時の UI 通知用 (catch でログのみだと田中に何も見えない)
    @Published var errorMessage: String?

    private var currentPage = 1

    func loadGalleries() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let query = buildQuery()
            let sort = sortMode == .popular ? "popular" : nil
            let result = try await NhentaiClient.search(query: query, page: 1, sort: sort)
            galleries = result.result
            hasMore = result.num_pages > 1
            currentPage = 1
        } catch {
            LogManager.shared.log("nhentai", "load failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
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
            // 失敗時にページ番号を戻さないと該当ページ 25 件が恒久欠落するので rollback
            currentPage -= 1
            LogManager.shared.log("nhentai", "nextPage failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
        Task { await enrichGalleries(from: startIndex) }
    }

    /// v2 search結果にnum_pagesがないので、バックグラウンドで詳細を取得して補完
    /// レート制限対策: 1.5秒間隔で順次取得
    @MainActor
    private func enrichGalleries(from startIndex: Int = 0) async {
        // クラッシュ修正 2026-06-09 (EXC_BREAKPOINT): await を跨ぐ間に galleries が
        // 別経路 (refresh/clearSearch の galleries=[]、再検索) で短くなると、固定した
        // index `i` が範囲外になり galleries[i] で Swift トラップ → 即落ちしていた。
        // 対策: 毎反復で bounds を再確認し、await 後は index を信用せず id で再特定して更新。
        var i = startIndex
        while i < galleries.count {
            guard galleries[i].num_pages == 0 else { i += 1; continue }
            let targetID = galleries[i].id
            do {
                let full = try await NhentaiClient.fetchGallery(id: targetID)
                // await 復帰後: galleries は差し替わっている可能性 → id で現在位置を再特定。
                if let idx = galleries.firstIndex(where: { $0.id == targetID }) {
                    galleries[idx] = full
                }
            } catch {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            i += 1
        }
    }

    func search() async {
        isSearchActive = true
        await loadGalleries()
    }

    func refresh() async {
        // E-H 側 GalleryListViewModel.refresh (v02a-f14) と同方式:
        // .refreshable のタスクはプルダウン戻り中の再描画 (tabBarHidden トグル等) で
        // キャンセルされ得るため、独立 Task で包んで生存させる。
        // galleries を先にクリアしない (成功して差し替わるまで旧データ保持 = 空一覧残り対策)。
        let task = Task { [weak self] in
            await self?.loadGalleries()
        }
        await task.value
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
