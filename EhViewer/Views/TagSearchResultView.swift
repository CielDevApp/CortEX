import SwiftUI
import Combine

/// タグ検索やカテゴリフィルタの結果を表示するビュー
struct TagSearchResultView: View {
    let searchQuery: String
    let host: GalleryHost
    let title: String

    @StateObject private var viewModel = GalleryListViewModel()
    @Environment(\.navPathBox) private var navPathBox
    @State private var previewGallery: Gallery?
    @State private var previewReaderRequest: GalleryPreviewReaderRequest?

    var body: some View {
        List {
            ForEach(viewModel.galleries) { gallery in
                GalleryCardView(gallery: gallery)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navPathBox?.path.append(gallery)
                    }
                    .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 15) {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        previewGallery = gallery
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
        .overlay {
            if viewModel.isLoading && viewModel.galleries.isEmpty {
                ProgressView("検索中...")
            }
            if let g = previewGallery {
                GalleryPreviewOverlay(
                    gallery: g,
                    host: host,
                    onDismiss: { previewGallery = nil },
                    onTapPage: { thumbnails, page in
                        previewReaderRequest = GalleryPreviewReaderRequest(gallery: g, page: page, thumbnails: thumbnails)
                    }
                )
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $previewReaderRequest) { req in
            GalleryReaderView(gallery: req.gallery, host: host, initialPage: req.page, thumbnails: req.thumbnails)
                .onAppear {
                    HistoryManager.shared.record(gallery: req.gallery, page: req.page)
                    previewGallery = nil
                }
        }
        #endif
        .task {
            // 既に読み込み済みならスキップ（戻るたびのリセット防止）
            guard viewModel.galleries.isEmpty else { return }
            viewModel.searchText = searchQuery
            await viewModel.search()
        }
    }
}

/// NavigationPathへの参照を子Viewに渡すためのEnvironment
/// @ObservableObjectラッパーでBindingせずpathを共有
final class NavigationPathBox: ObservableObject {
    @Published var path = NavigationPath()
}

private struct NavPathBoxKey: EnvironmentKey {
    static let defaultValue: NavigationPathBox? = nil
}

extension EnvironmentValues {
    var navPathBox: NavigationPathBox? {
        get { self[NavPathBoxKey.self] }
        set { self[NavPathBoxKey.self] = newValue }
    }
}
