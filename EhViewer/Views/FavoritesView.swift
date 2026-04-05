import SwiftUI
import TipKit

struct FavoritesView: View {
    @StateObject private var viewModel = FavoritesViewModel()
    @ObservedObject var authVM: AuthViewModel
    @ObservedObject private var favCache = FavoritesCache.shared
    @ObservedObject private var nhFavCache = NhentaiFavoritesCache.shared
    @State private var showWallpaper = false
    @State private var favSource: GallerySource = .ehentai
    @State private var nhFavorites: [NhentaiClient.NhGallery] = []
    @State private var isLoadingNh = false
    @State private var nhErrorMessage: String?
    @State private var searchText = ""
    @State private var nhSortOrder: FavoritesSort = .dateDesc
    @State private var tabBarHidden = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ソース切替
                Picker("ソース", selection: $favSource) {
                    Text("E-Hentai").tag(GallerySource.ehentai)
                    Text("nhentai").tag(GallerySource.nhentai)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 6)

                if favSource == .nhentai {
                    nhentaiFavoritesContent
                } else {

                // ステータスバー
                HStack {
                    if !viewModel.galleries.isEmpty || viewModel.isFromCache {
                        Text("\(viewModel.totalLoaded)件")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if viewModel.isFromCache {
                            Text("(キャッシュ)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Text("更新: \(viewModel.lastUpdatedText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("取得中...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Menu {
                        ForEach(FavoritesSort.allCases, id: \.self) { sort in
                            Button {
                                viewModel.sortOrder = sort
                                viewModel.applyFilter()
                            } label: {
                                HStack {
                                    Text(sort.rawValue)
                                    if viewModel.sortOrder == sort {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("並替", systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                    }

                    Button {
                        Task { await viewModel.refreshFromServer() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .disabled(viewModel.isLoading)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                // ギャラリーリスト
                List {
                    ForEach(viewModel.galleries) { gallery in
                        NavigationLink(value: gallery) {
                            GalleryCardView(gallery: gallery)
                        }
                    }

                    if viewModel.galleries.isEmpty && !viewModel.isLoading {
                        ContentUnavailableView {
                            Label(
                                viewModel.searchText.isEmpty ? "お気に入りがありません" : "検索結果なし",
                                systemImage: viewModel.searchText.isEmpty ? "heart.slash" : "magnifyingglass"
                            )
                        } description: {
                            if let error = viewModel.errorMessage {
                                Text(error)
                            } else if !authVM.isLoggedIn {
                                Text("ログインしてください")
                            } else if viewModel.totalLoaded == 0 {
                                Text("↻ ボタンでサーバーから取得")
                            } else if !viewModel.searchText.isEmpty {
                                Text("「\(viewModel.searchText)」に一致するお気に入りがありません")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.refreshFromServer()
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { oldVal, newVal in
                    let delta = newVal - oldVal
                    if abs(delta) > 100 { return }
                    if delta > 8 { tabBarHidden = true }
                    else if delta < -5 { tabBarHidden = false }
                }

                } // end E-Hentai else
            }
            .navigationTitle("お気に入り")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(tabBarHidden ? .hidden : .visible, for: .tabBar)
            .animation(.smooth(duration: 0.25), value: tabBarHidden)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showWallpaper = true
                    } label: {
                        Image(systemName: "rectangle.grid.3x2.fill")
                    }
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showWallpaper) {
                WallpaperView {
                    AppDelegate.orientationLock = .all
                    showWallpaper = false
                }
                .onAppear {
                    AppDelegate.orientationLock = .portrait
                    // 現在横画面なら縦に戻す
                    if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                    }
                }
            }
            #endif
            .searchable(text: $searchText, prompt: "お気に入り内を検索...")
            .onChange(of: searchText) {
                if favSource == .ehentai {
                    viewModel.searchText = searchText
                    viewModel.applyFilter()
                }
            }
            .onChange(of: favSource) { _, newSource in
                searchText = ""
                viewModel.searchText = ""
                viewModel.applyFilter()
                if newSource == .nhentai {
                    loadNhFromCache()
                }
            }
            .navigationDestination(for: Gallery.self) { gallery in
                GalleryDetailView(gallery: gallery, host: authVM.isLoggedIn ? .exhentai : .ehentai)
            }
            .navigationDestination(for: NhentaiClient.NhGallery.self) { nh in
                NhentaiDetailView(gallery: nh)
            }
            .navigationDestination(for: CategoryFilter.self) { filter in
                TagSearchResultView(searchQuery: filter.query, host: authVM.isLoggedIn ? .exhentai : .ehentai, title: filter.displayTitle)
            }
            .navigationDestination(for: TagSearch.self) { search in
                TagSearchResultView(searchQuery: search.query, host: authVM.isLoggedIn ? .exhentai : .ehentai, title: search.displayTitle)
            }
            .navigationDestination(for: UploaderSearch.self) { search in
                TagSearchResultView(searchQuery: search.query, host: authVM.isLoggedIn ? .exhentai : .ehentai, title: search.displayTitle)
            }
            .overlay {
                if viewModel.isLoading && viewModel.galleries.isEmpty {
                    ProgressView("サーバーから取得中...")
                }
            }
            .onAppear {
                viewModel.loadFromCacheOnly()
            }
            .onChange(of: favCache.version) { _, _ in
                viewModel.loadFromCacheOnly()
            }
            .onChange(of: authVM.isLoggedIn) {
                if !authVM.isLoggedIn {
                    viewModel.galleries = []
                    viewModel.errorMessage = nil
                }
            }
        }
    }

    // MARK: - nhentaiお気に入り

    private var nhentaiFavoritesContent: some View {
        Group {
            // ステータスバー
            if !nhFavorites.isEmpty || nhFavCache.hasCachedData {
                HStack {
                    Text("\(nhFavorites.count)件")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !isLoadingNh && nhFavCache.hasCachedData {
                        Text("(キャッシュ)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text("更新: \(nhFavCache.lastUpdatedText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isLoadingNh {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("取得中...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Menu {
                        ForEach(FavoritesSort.allCases, id: \.self) { sort in
                            Button {
                                nhSortOrder = sort
                            } label: {
                                HStack {
                                    Text(sort.rawValue)
                                    if nhSortOrder == sort {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("並替", systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                    }

                    Button {
                        Task { await syncNhFavorites() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .disabled(isLoadingNh)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            TipView(FavoritesSyncTip(), arrowEdge: .top)
                .padding(.horizontal)

            if isLoadingNh && nhFavorites.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("nhentaiお気に入りを同期中...")
                    Spacer()
                }
            } else if nhFavorites.isEmpty {
                VStack {
                    Spacer()
                    if NhentaiCookieManager.isLoggedIn() {
                        ContentUnavailableView {
                            Label("nhentaiのお気に入りがありません", systemImage: "heart")
                        } description: {
                            if let error = nhErrorMessage {
                                Text(error)
                            }
                        } actions: {
                            Button {
                                Task { await syncNhFavorites() }
                            } label: {
                                Label("サーバーから同期", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView {
                            Label("nhentai未ログイン", systemImage: "person.crop.circle.badge.exclamationmark")
                        } description: {
                            Text("設定からnhentaiにログインしてください")
                        }
                    }
                    Spacer()
                }
            } else {
                List {
                    ForEach(filteredNhFavorites) { nh in
                        NavigationLink(value: nh) {
                            NhentaiCardView(gallery: nh)
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                .refreshable { await syncNhFavorites() }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { oldVal, newVal in
                    let delta = newVal - oldVal
                    if abs(delta) > 100 { return }
                    if delta > 8 { tabBarHidden = true }
                    else if delta < -5 { tabBarHidden = false }
                }
            }
        }
        .onAppear {
            loadNhFromCache()
        }
        .onChange(of: nhFavCache.version) { _, _ in
            loadNhFromCache()
        }
    }

    /// キャッシュからnhentaiお気に入りを読み込み
    private func loadNhFromCache() {
        let cached = nhFavCache.load()
        if !cached.isEmpty {
            nhFavorites = cached
        }
    }

    /// nhentaiお気に入りをサーバーと同期（WKWebView HTML解析）
    private func syncNhFavorites() async {
        LogManager.shared.log("nhFav", "=== syncNhFavorites START ===")
        LogManager.shared.log("nhFav", "isLoggedIn=\(NhentaiCookieManager.isLoggedIn()) hasCf=\(NhentaiCookieManager.hasCfClearance())")
        isLoadingNh = true
        nhErrorMessage = nil
        do {
            #if canImport(UIKit)
            let fetcher = NhentaiFavoritesFetcher()
            let ids = try await fetcher.fetchAllFavoriteIds()
            LogManager.shared.log("nhFav", "WKWebView returned \(ids.count) IDs")

            // キャッシュ済みギャラリーを辞書化（APIコール削減）
            let cached = nhFavCache.load()
            let cachedDict = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
            LogManager.shared.log("nhFav", "cache has \(cachedDict.count) items, need to fetch \(ids.filter { cachedDict[$0] == nil }.count) new")

            var galleries: [NhentaiClient.NhGallery] = []
            for (i, id) in ids.enumerated() {
                if let cachedGallery = cachedDict[id] {
                    galleries.append(cachedGallery)
                } else if let g = try? await NhentaiClient.fetchGallery(id: id) {
                    galleries.append(g)
                    // API呼び出し後は1秒待機（レートリミット対策）
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if (i + 1) % 10 == 0 || i == ids.count - 1 {
                    nhFavorites = galleries
                    nhFavCache.save(galleries)
                }
            }

            nhFavCache.save(galleries)
            nhFavorites = galleries
            LogManager.shared.log("nhFav", "synced: \(galleries.count) items")
            #else
            let serverFavs = try await NhentaiClient.fetchAllFavorites()
            nhFavCache.save(serverFavs)
            nhFavorites = serverFavs
            #endif
        } catch {
            nhErrorMessage = error.localizedDescription
            LogManager.shared.log("nhFav", "sync failed: \(error.localizedDescription)")
        }
        isLoadingNh = false
    }

    /// nhentaiお気に入りの検索フィルタ+ソート
    private var filteredNhFavorites: [NhentaiClient.NhGallery] {
        var result = nhFavorites

        // 検索フィルタ
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.displayTitle.lowercased().contains(query)
                || $0.englishTitle.lowercased().contains(query)
                || ($0.title.pretty?.lowercased().contains(query) ?? false)
            }
        }

        // ソート
        switch nhSortOrder {
        case .dateDesc:
            break  // サーバーからの順序（追加日・新しい順）をそのまま使用
        case .dateAsc:
            result.reverse()
        case .title:
            result.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        }

        return result
    }
}
