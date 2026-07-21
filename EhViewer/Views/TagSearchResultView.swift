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
    // タグ飛び先の絞り込み (最低評価 + 除外言語)
    @State private var showFilter = false
    @State private var minRating = 0
    @State private var selectedLanguages: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.galleries) { gallery in
                    // navPathBox は GalleryDetailView 経由の push でこの View まで伝播せず nil になる
                    // (実測 box=false)。GalleryDetailView のタグと同じ NavigationLink(value:) にして
                    // enclosing NavigationStack の path へ直接積む (navPathBox 非依存で確実に動く)。
                    NavigationLink(value: gallery) {
                        GalleryCardView(gallery: gallery)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.4, maximumDistance: 15)
                            .onEnded { _ in
                                #if canImport(UIKit)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                #endif
                                previewGallery = gallery
                            }
                    )

                    Divider().padding(.leading)
                }

                if viewModel.hasMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding()
                            .task { await viewModel.loadNextPage() }
                        Spacer()
                    }
                }

                if viewModel.galleries.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView {
                        Label("結果がありません", systemImage: "magnifyingglass")
                    }
                    .padding(.top, 100)
                }
            }
        }
        .refreshable { await viewModel.refresh() }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showFilter = true } label: {
                    // nh 側と統一 (逆輸入): 未選択=線アイコン / フィルタ有効時=塗り。
                    Image(systemName: (minRating >= 2 || !selectedLanguages.isEmpty)
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showFilter) {
            NavigationStack {
                Form {
                    Section("最低評価") {
                        HStack(spacing: 8) {
                            ForEach(1...5, id: \.self) { i in
                                Image(systemName: i <= minRating ? "star.fill" : "star")
                                    .font(.title2)
                                    .foregroundStyle(.yellow)
                                    .contentShape(Rectangle())
                                    .onTapGesture { minRating = (minRating == i ? 0 : i) }
                            }
                            Spacer()
                            Text(minRating >= 2 ? "★\(minRating) 以上のみ" : "指定なし")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ForEach(AdvancedSearchView.allLanguages, id: \.code) { lang in
                            Button {
                                if selectedLanguages.contains(lang.code) { selectedLanguages.remove(lang.code) }
                                else { selectedLanguages.insert(lang.code) }
                            } label: {
                                HStack {
                                    Text(lang.label).foregroundStyle(.primary)
                                    Spacer()
                                    if selectedLanguages.contains(lang.code) {
                                        Image(systemName: "checkmark").foregroundStyle(.blue)
                                    }
                                }
                                .contentShape(Rectangle())   // 行全体を当たり判定に (文字以外/余白タップでも反応)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("表示する言語")
                    } footer: {
                        Text("選択した言語のみ表示（未選択なら全言語）。E-H 仕様上「★2以上」が最小。")
                    }
                }
                .navigationTitle("絞り込み")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("適用") { applyFilter(); showFilter = false }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { showFilter = false }
                    }
                }
            }
        }
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
            GalleryReaderView(gallery: req.gallery, host: host, initialPage: req.page, thumbnails: req.thumbnails, route: .onlineTagSearch)
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

    /// 絞り込み適用 → 最低評価フィルタ + 除外言語トークンを設定して再検索
    private func applyFilter() {
        viewModel.minRating = minRating >= 2 ? minRating : nil
        // 選択した言語のみ表示 (AdvancedSearchView と同じ include ロジック)。
        // 日本語含む or 複数選択は「選択外を除外」、単独選択は include トークン。
        viewModel.baseQuery = {
            guard !selectedLanguages.isEmpty else { return nil }
            if selectedLanguages.contains("japanese") || selectedLanguages.count >= 2 {
                let defined = Set(AdvancedSearchView.allLanguages.map { $0.code })
                let toExclude = defined.subtracting(selectedLanguages)
                return toExclude.map { "-language:\($0)" }.sorted().joined(separator: " ")
            }
            if let only = selectedLanguages.first { return "language:\(only)$" }
            return nil
        }()
        viewModel.galleries = []
        Task { await viewModel.search() }
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
