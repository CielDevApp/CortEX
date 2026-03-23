import SwiftUI
import Combine

/// タグ検索やカテゴリフィルタの結果を表示するビュー
struct TagSearchResultView: View {
    let searchQuery: String
    let host: GalleryHost
    let title: String

    @StateObject private var viewModel = GalleryListViewModel()

    var body: some View {
        List {
            ForEach(viewModel.galleries) { gallery in
                NavigationLink(value: gallery) {
                    GalleryCardView(gallery: gallery)
                }
            }

            if viewModel.hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .task { await viewModel.loadNextPage() }
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }

            if viewModel.galleries.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("結果がありません", systemImage: "magnifyingglass")
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await viewModel.refresh() }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: Gallery.self) { gallery in
            GalleryDetailView(gallery: gallery, host: host)
        }
        .navigationDestination(for: TagSearch.self) { search in
            TagSearchResultView(searchQuery: search.query, host: host, title: search.displayTitle)
        }
        .navigationDestination(for: UploaderSearch.self) { search in
            TagSearchResultView(searchQuery: search.query, host: host, title: search.displayTitle)
        }
        .navigationDestination(for: CategoryFilter.self) { filter in
            TagSearchResultView(searchQuery: filter.query, host: host, title: filter.displayTitle)
        }
        .overlay {
            if viewModel.isLoading && viewModel.galleries.isEmpty {
                ProgressView("検索中...")
            }
        }
        .task {
            viewModel.searchText = searchQuery
            await viewModel.search()
        }
    }
}
