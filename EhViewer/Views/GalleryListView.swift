import SwiftUI
import TipKit

/// カテゴリタブの定義
enum GalleryTab: String, CaseIterable {
    case all = "All"
    case doujinshi = "Doujinshi"
    case manga = "Tankoubon"

    var categoryFilter: Int? {
        switch self {
        case .all: return nil
        case .doujinshi: return GalleryCategory.excludeAllExcept([.doujinshi])
        case .manga: return nil // tankoubon はタグで絞る
        }
    }
}

/// ソースモード
enum GallerySource: CaseIterable {
    case ehentai
    case nhentai

    func label(isLoggedIn: Bool) -> String {
        switch self {
        case .ehentai: return isLoggedIn ? "EXhentai" : "E-Hentai"
        case .nhentai: return "nhentai"
        }
    }
}

struct GalleryListView: View {
    @ObservedObject var authVM: AuthViewModel
    @State private var selectedTab: GalleryTab = .all
    @State private var selectedSource: GallerySource = .ehentai
    @StateObject private var allVM = GalleryListViewModel()
    @StateObject private var doujinshiVM = GalleryListViewModel()
    @StateObject private var mangaVM = GalleryListViewModel()
    @StateObject private var nhVM = NhentaiListViewModel()
    @State private var isSearchActive = false
    @State private var hasInitialized = false
    @State private var searchText = ""
    @State private var tabBarHidden = false
    @StateObject private var navPathBox = NavigationPathBox()
    /// B3 オンライン移植 (2026-07-21 再挑戦): カード → 詳細画面 push の zoom 遷移。
    /// NavigationStack push は iOS 18 zoom transition の本来の想定用途。gesture は奪わない。
    @Namespace private var listZoomNS
    @AppStorage(UDKey.galleryListLayout) private var galleryListLayout: String = "grid"
    /// 田中要望 2026-04-30: iOS の `.searchable` (日本語有利 baseQuery 込み) を撤回し、
    /// 検索ボタン → AdvancedSearchView sheet で全カテゴリ + 言語を任意指定する新 UX。
    /// 直近入力を sheet 再表示で復元するため state を保持。
    @State private var showAdvancedSearch = false
    @State private var advSearchLanguages: Set<String> = []

    private var currentVM: GalleryListViewModel {
        switch selectedTab {
        case .all: return allVM
        case .doujinshi: return doujinshiVM
        case .manga: return mangaVM
        }
    }

    /// ログイン状態に応じたホスト
    private var currentHost: GalleryHost {
        authVM.isLoggedIn ? .exhentai : .ehentai
    }

    var body: some View {
        NavigationStack(path: $navPathBox.path) {
            VStack(spacing: 0) {
                // ソース切替
                Picker("ソース", selection: $selectedSource) {
                    ForEach(GallerySource.allCases, id: \.self) { src in
                        Text(src.label(isLoggedIn: authVM.isLoggedIn)).tag(src)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 6)

                #if targetEnvironment(macCatalyst)
                // Mac Catalyst は従来の条件分岐 (マウス操作、Picker でソース切替)。
                if selectedSource == .ehentai {
                    ehentaiContent
                } else {
                    nhentaiContent
                }
                #else
                // 田中要望 2026-06-08: 左右スワイプで E-Hentai ⇄ nhentai を切替。
                // ページング TabView は両ページを生存させ続けるため、各 ScrollView の
                // スクロール位置が保持され、再フェッチも起きずシームレスに切替わる。
                // 上部セグメント Picker と双方向バインド (Picker タップでもスワイプでも同期)。
                TabView(selection: $selectedSource) {
                    ehentaiContent.tag(GallerySource.ehentai)
                    nhentaiContent.tag(GallerySource.nhentai)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // 白帯修正 (2026-07-21): TabView(.page)=内部UIPageViewControllerが下端safe area
                // に背景を通さず、そこに親の白が残る (ギャラリーだけ発症・iPhone/iPad両方)。TabView
                // 自体を下端へ伸ばしてページ背景で塗り切る。個人版で効果確認済 → 配布版へ移植。
                .ignoresSafeArea(.container, edges: .bottom)
                #endif
            }
            // 田中報告 2026-07-03: ScrollView 側の ignoresSafeArea は TabView(.page) 境界で
            // 下端まで届かず、iPad でも最下部に白帯が残った。画面全体のコンテナに背景を
            // 当てて貫通させる (セグメント帯も含め全面グループ背景で統一)。
            .background(CardDesign.listBackground.ignoresSafeArea())
            .navigationTitle("Cort:EX")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(tabBarHidden ? .hidden : .visible, for: .tabBar)
            .animation(.smooth(duration: 0.25), value: tabBarHidden)
            #endif
            .navigationDestination(for: Gallery.self) { gallery in
                GalleryDetailView(gallery: gallery, host: currentHost)
                    .navigationTransition(.zoom(sourceID: gallery.gid, in: listZoomNS))   // B3 online
            }
            .navigationDestination(for: NhentaiClient.NhGallery.self) { nh in
                NhentaiDetailView(gallery: nh)
                    .navigationTransition(.zoom(sourceID: "nh-\(nh.id)", in: listZoomNS))   // B3 online
            }
            .navigationDestination(for: TagSearch.self) { search in
                TagSearchResultView(searchQuery: search.query, host: currentHost, title: search.displayTitle)
            }
            .navigationDestination(for: UploaderSearch.self) { search in
                TagSearchResultView(searchQuery: search.query, host: currentHost, title: search.displayTitle)
            }
            .navigationDestination(for: CategoryFilter.self) { filter in
                TagSearchResultView(searchQuery: filter.query, host: currentHost, title: filter.displayTitle)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if selectedSource == .ehentai && !authVM.isLoggedIn {
                        Button {
                            authVM.showingLogin = true
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        galleryListLayout = (galleryListLayout == "grid") ? "list" : "grid"
                    } label: {
                        Image(systemName: galleryListLayout == "grid" ? "list.bullet" : "square.grid.2x2")
                    }
                }
                #if !targetEnvironment(macCatalyst)
                // 田中要望 2026-04-30: iOS は `.searchable` を撤回 → 検索ボタン経由 AdvancedSearchView。
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAdvancedSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                #endif
            }
            #if targetEnvironment(macCatalyst)
            .searchable(text: $searchText, prompt: selectedSource == .nhentai ? "nhentai検索..." : "検索...")
            .onSubmit(of: .search) {
                guard !searchText.isEmpty else { return }
                if selectedSource == .ehentai {
                    currentVM.searchText = searchText
                    isSearchActive = true
                    Task { await currentVM.search() }
                } else {
                    nhVM.searchText = searchText
                    nhVM.isSearchActive = true
                    Task { await nhVM.search() }
                }
            }
            #endif
            .onChange(of: selectedSource) { _, _ in
                searchText = ""
            }
            #if !targetEnvironment(macCatalyst)
            // 田中要望 2026-05-01: ギャラリーをブラー透過 + 一回り小さい角丸ウィンドウで表示。
            // キャンセルボタン or 外周タップで閉じる。
            .overlay {
                if showAdvancedSearch {
                    advancedSearchOverlay
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .zIndex(100)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: showAdvancedSearch)
            #endif
        }
        // 田中報告 2026-07-03 (2回目): VStack 層の背景でも iPad 起動直後から最下部に白帯。
        // NavigationStack の外側 = タブコンテンツ全面にも背景を張って物理的に塗り切る。
        .background(CardDesign.listBackground.ignoresSafeArea())
        .environment(\.navPathBox, navPathBox)
    }

    #if !targetEnvironment(macCatalyst)
    // MARK: - 検索 overlay (ブラー透過 + 角丸ウィンドウ + iOS 26 Liquid Glass)

    private func dismissSearch() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            showAdvancedSearch = false
        }
    }

    private var advancedSearchOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { dismissSearch() }

            AdvancedSearchView(
                mode: selectedSource == .nhentai ? .nhentai : .ehentai(currentHost),
                initialText: "",
                initialCategories: [],
                initialLanguages: advSearchLanguages,
                onClose: { dismissSearch() }
            ) { text, categoryFilter, baseQuery, _, languages, minRating in
                advSearchLanguages = languages
                if selectedSource == .ehentai {
                    searchText = text
                    currentVM.searchText = text
                    currentVM.categoryFilter = categoryFilter
                    currentVM.baseQuery = baseQuery
                    currentVM.minRating = minRating >= 2 ? minRating : nil
                    isSearchActive = !text.isEmpty || categoryFilter != nil || baseQuery != nil || (minRating >= 2)
                    Task { await currentVM.refresh() }
                } else {
                    searchText = text
                    nhVM.searchText = text
                    nhVM.isSearchActive = !text.isEmpty
                    Task { await nhVM.search() }
                }
            }
            .frame(maxWidth: 720)
            .modifier(LiquidGlassWindow(cornerRadius: 28))
            .shadow(color: .black.opacity(0.32), radius: 26, x: 0, y: 10)
            .padding(.horizontal, 18)
            .padding(.vertical, 50)
            // fix (2026-05-16): 親 overlay 側の .contentShape + .onTapGesture を撤去。
            // iOS 18 では外側の tap 吸収が内側 Button (検索履歴行) のタップを奪うため
            // (v02a-f12 で実機確認済み)。背景タップでの dismiss は ZStack 背面の
            // Rectangle 側 onTapGesture が担当する。
        }
    }
    #endif

    // MARK: - E-Hentai

    private var ehentaiContent: some View {
        VStack(spacing: 0) {
            if isSearchActive {
                // UI 刷新 (2026-07-03): 全幅の「検索: / クリア」帯 → コンパクトな material チップ
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(currentVM.searchText)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            #if targetEnvironment(macCatalyst)
            // 田中要望 2026-04-30: iOS は All/Doujinshi/Tankoubon タブを廃止 (検索画面でカテゴリ任意指定)。
            // Mac Catalyst は従来 UI 維持。
            if !isSearchActive {
                Picker("カテゴリ", selection: $selectedTab) {
                    ForEach(GalleryTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            #endif

            switch selectedTab {
            case .all:
                GalleryScrollList(viewModel: allVM, authVM: authVM, navPath: $navPathBox.path, zoomNamespace: listZoomNS, onScrollDown: { tabBarHidden = true }, onScrollUp: { tabBarHidden = false })
            case .doujinshi:
                GalleryScrollList(viewModel: doujinshiVM, authVM: authVM, navPath: $navPathBox.path, zoomNamespace: listZoomNS, onScrollDown: { tabBarHidden = true }, onScrollUp: { tabBarHidden = false })
            case .manga:
                GalleryScrollList(viewModel: mangaVM, authVM: authVM, navPath: $navPathBox.path, zoomNamespace: listZoomNS, onScrollDown: { tabBarHidden = true }, onScrollUp: { tabBarHidden = false })
            }
        }
        .overlay {
            if currentVM.isLoading && currentVM.galleries.isEmpty {
                ProgressView("読み込み中...")
            }
        }
        .task {
            let initialHost: GalleryHost = authVM.isLoggedIn ? .exhentai : .ehentai
            allVM.host = initialHost
            doujinshiVM.host = initialHost
            mangaVM.host = initialHost
            nhVM.languageFilter = authVM.isLoggedIn ? "-language:english -language:chinese -language:korean" : nil
            setupVM(allVM, tab: .all)
            setupVM(doujinshiVM, tab: .doujinshi)
            setupVM(mangaVM, tab: .manga)
            if !hasInitialized {
                hasInitialized = true
                await currentVM.loadGalleries()
            }
        }
        .onChange(of: selectedTab) {
            isSearchActive = false
            currentVM.searchText = ""
            if currentVM.galleries.isEmpty && !currentVM.isLoading {
                Task { await currentVM.loadGalleries() }
            }
        }
        .onChange(of: authVM.isLoggedIn) {
            let newHost: GalleryHost = authVM.isLoggedIn ? .exhentai : .ehentai
            allVM.host = newHost
            doujinshiVM.host = newHost
            mangaVM.host = newHost
            nhVM.languageFilter = authVM.isLoggedIn ? "-language:english -language:chinese -language:korean" : nil
            allVM.galleries = []
            doujinshiVM.galleries = []
            mangaVM.galleries = []
            nhVM.galleries = []
            isSearchActive = false
            Task { await currentVM.refresh() }
        }
    }

    // MARK: - nhentai

    private var nhentaiContent: some View {
        VStack(spacing: 0) {
            if nhVM.isSearchActive {
                // UI 刷新 (2026-07-03): 全幅帯 → material チップ (E-H 側と同型)
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(nhVM.searchText)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            searchText = ""
                            nhVM.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            if !nhVM.isSearchActive {
                Picker("並び順", selection: $nhVM.sortMode) {
                    Text("新着").tag(NhSortMode.recent)
                    Text("人気").tag(NhSortMode.popular)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            TipView(NhentaiSearchTip(), arrowEdge: .top)
                .padding(.horizontal)

            NhentaiScrollList(viewModel: nhVM, navPath: $navPathBox.path, zoomNamespace: listZoomNS, onScrollDown: { tabBarHidden = true }, onScrollUp: { tabBarHidden = false })
        }
        .overlay {
            if nhVM.isLoading && nhVM.galleries.isEmpty {
                ProgressView("読み込み中...")
            }
        }
        .onAppear {
            if nhVM.galleries.isEmpty && !nhVM.isLoading {
                Task { await nhVM.loadGalleries() }
            }
        }
        .onChange(of: nhVM.sortMode) {
            Task { await nhVM.refresh() }
        }
    }

    // MARK: - Helpers

    private func clearSearch() {
        searchText = ""
        currentVM.searchText = ""
        // 不可視フィルタの残留対策 (2026-06-10): 高度な検索で設定した
        // categoryFilter / baseQuery / minRating もリセットしないと、
        // 「クリア」後も絞り込みが効き続けて新着が出ない。
        currentVM.categoryFilter = nil
        currentVM.baseQuery = nil
        currentVM.minRating = nil
        // タブ既定値を復元 (iOS manga タブの "tag:tankoubon"、Mac Catalyst の
        // タブ既定 baseQuery/カテゴリ)。setupVM は nil の時だけ既定値を入れる設計。
        setupVM(currentVM, tab: selectedTab)
        isSearchActive = false
        Task { await currentVM.refresh() }
    }

    private func setupVM(_ vm: GalleryListViewModel, tab: GalleryTab) {
        // 田中要望 2026-04-30: 日本語有利 default は撤回。検索ボタン経由 AdvancedSearchView で
        // user が言語を任意指定する。tab は category 絞り込みのみ。Mac Catalyst は従来通り.
        #if targetEnvironment(macCatalyst)
        guard vm.baseQuery == nil else { return }
        let exclude = "-language:english -language:chinese -language:korean -language:translated"
        switch tab {
        case .all:
            vm.categoryFilter = nil
            vm.baseQuery = exclude
        case .doujinshi:
            vm.categoryFilter = GalleryCategory.excludeAllExcept([.doujinshi])
            vm.baseQuery = exclude
        case .manga:
            vm.categoryFilter = nil
            vm.baseQuery = "tag:tankoubon \(exclude)"
        }
        #else
        // iOS: tab に応じた category のみ設定、baseQuery は触らない (AdvancedSearchView が後で書き換える)。
        switch tab {
        case .all:
            if vm.categoryFilter == nil { /* keep nil */ }
        case .doujinshi:
            if vm.categoryFilter == nil {
                vm.categoryFilter = GalleryCategory.excludeAllExcept([.doujinshi])
            }
        case .manga:
            // 単行本タグ条件は keep (search が無効でも tankoubon 絞り込みは有効に)
            if vm.baseQuery == nil { vm.baseQuery = "tag:tankoubon" }
        }
        #endif
    }
}

// MARK: - E-Hentaiスクロールリスト

struct GalleryScrollList: View {
    @ObservedObject var viewModel: GalleryListViewModel
    @ObservedObject var authVM: AuthViewModel
    @Binding var navPath: NavigationPath
    var zoomNamespace: Namespace.ID   // B3 online: 親 GalleryListView の zoom namespace
    @State private var scrollPosition: Int?
    // 田中報告 2026-06-21: 起動直後/左右スワイプで一覧トップにスキマが出て一瞬で張り付く。
    // 真因 = 初回ロード (loadGalleries reset:true) も scrollResetToken を上げるため、既に
    // 先頭にいる状態で .scrollPosition(anchor:.top) が programmatic アンカー跳躍を起こす。
    // しかも scrollPosition が gid のまま居座り、ページ再レイアウト (TabView スワイプ) の度に
    // 再アンカーしてスキマが再発する。→ 初回 reset はスキップし scrollPosition を nil のまま保つ。
    // 2 回目以降 (プルダウン更新 / 検索) の総入れ替えだけ先頭固定する。
    @State private var didInitialReset = false
    @State private var previewGallery: Gallery?
    @State private var previewReaderRequest: GalleryPreviewReaderRequest?
    var onScrollDown: (() -> Void)?
    var onScrollUp: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @AppStorage(UDKey.galleryListLayout) private var galleryListLayout: String = "grid"

    /// Phase G-A iPad-only パイロット (2026-04-26): iPad のみ Grid、Mac/iPhone は既存 List。
    private var isIPadGrid: Bool {
        #if targetEnvironment(macCatalyst)
        return galleryListLayout == "grid"
        #elseif canImport(UIKit)
        let idiom = UIDevice.current.userInterfaceIdiom
        return (idiom == .pad || idiom == .phone) && galleryListLayout == "grid"
        #else
        return false
        #endif
    }

    /// idiom / プラットフォーム別グリッド列数: iPad=4、iPhone=3、Mac Catalyst=adaptive(180+)。
    private var gridColumns: [GridItem] {
        #if targetEnvironment(macCatalyst)
        return GalleryGridColumns.macColumns()
        #elseif canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .phone {
            return GalleryGridColumns.iPhoneColumns()
        }
        return GalleryGridColumns.iPadColumns(horizontalSizeClass: hSizeClass)
        #else
        return []
        #endif
    }

    var body: some View {
        if isIPadGrid {
            iPadGridScroll
        } else {
            originalListScroll
        }
    }

    @ViewBuilder
    private var iPadGridScroll: some View {
        #if canImport(UIKit)
        let columns = gridColumns
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                // 田中設計 (2026-04-27): real セルとダミーを統合 ForEach に。
                // index < galleries.count → real cell、それ以上 → ダミー (常時 +80 slot 確保)。
                // SwiftUI の自然な diff で「ダミー → real cell」置換が動く。
                // 田中報告 2026-07-03: 検索結果が少ない時も +80 ダミーが並び、件数より下へ
                // 無限にスクロールできてしまう。ダミーは「続きがある/読み込み中」の時だけ出す
                // (viewport 空白対策という本来目的に限定)。
                let dummyCountEh = (viewModel.hasMore || viewModel.isLoading) ? 80 : 0
                let totalSlotsEh = Array(0..<(viewModel.galleries.count + dummyCountEh))
                ForEach(totalSlotsEh, id: \.self) { index in
                    if index < viewModel.galleries.count {
                        let gallery = viewModel.galleries[index]
                        GalleryGridCellView(gallery: gallery)
                            .matchedTransitionSource(id: gallery.gid, in: zoomNamespace)   // B3 online
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // 田中報告 2026-05-02: 別作品を開いて戻ると前の作品の詳細が出る問題対応。
                                // SwiftUI NavigationPath の pop 残留 (既知挙動) を回避するため、
                                // 一覧からの直接 push 時は path をリセットして [gallery] のみにする。
                                // クリアと追加を別フレームに分け、同作品の再タップでも差分を発生させ確実に push。
                                navPath = NavigationPath()
                                DispatchQueue.main.async { navPath.append(gallery) }
                            }
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.4, maximumDistance: 15)
                                    .onEnded { _ in
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        previewGallery = gallery
                                    }
                            )
                            .onAppear {
                                if index >= viewModel.galleries.count - 4 && viewModel.hasMore && !viewModel.isLoading {
                                    Task { await viewModel.loadNextPage() }
                                }
                                let prefetchRange = (index + 1)...(index + 4)
                                let galleries = viewModel.galleries
                                Task.detached(priority: .userInitiated) {
                                    for i in prefetchRange {
                                        guard i < galleries.count else { break }
                                        if let url = galleries[i].coverURL,
                                           ImageCache.shared.image(for: url) == nil,
                                           !ImageCache.shared.isLoading(url) {
                                            ImageCache.shared.setLoading(url)
                                            do {
                                                let data = try await EhClient.shared.fetchThumbData(url: url, host: .exhentai)
                                                let ciCtx = SpriteCache.ciContext
                                                if let ciImage = CIImage(data: data),
                                                   let cgImage = SpriteCache.makeDisplayCGImage(ciImage) {
                                                    let img = UIImage(cgImage: cgImage)
                                                    ImageCache.shared.setThumb(img, for: url)
                                                } else if let img = PlatformImage(data: data) {
                                                    ImageCache.shared.setThumb(img, for: url)
                                                }
                                            } catch {}
                                            ImageCache.shared.removeLoading(url)
                                        }
                                    }
                                }
                            }
                            .id(gallery.gid)
                    } else {
                        // ダミー = 実カード構造のスケルトン + shimmer (Phase 3 v2, 高級版)
                        SkeletonCardPlaceholder()
                            .task { await viewModel.loadNextPage() }
                    }
                }
            }
            .padding(8)

            // 田中要望 2026-07-03: 一覧の終端に件数フッターを表示
            if !viewModel.hasMore && !viewModel.galleries.isEmpty {
                Text(viewModel.searchText.isEmpty
                     ? "全 \(viewModel.galleries.count) 件"
                     : "\(viewModel.galleries.count) 件見つかりました")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
            }

            if viewModel.galleries.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label(
                        authVM.isLoggedIn ? "ギャラリーがありません" : "未ログイン",
                        systemImage: authVM.isLoggedIn ? "photo.on.rectangle.angled" : "person.crop.circle.badge.exclamationmark"
                    )
                } description: {
                    if let error = viewModel.errorMessage { Text(error) }
                    else if !authVM.isLoggedIn { Text("ログインしてください") }
                    else { Text("プルダウンして再読み込み") }
                }
                .padding(.top, 100)
            }
        }
        .background(CardDesign.listBackground.ignoresSafeArea())
        .onScrollGeometryChange(for: CGFloat.self) { geo in geo.contentOffset.y } action: { oldVal, newVal in
            let delta = newVal - oldVal
            if abs(delta) > 100 { return }
            if delta > 8 { onScrollDown?() } else if delta < -5 { onScrollUp?() }
        }
        // Mac Catalyst は従来挙動を一切変えない (憲法: Mac は触らない)。iPhone/iPad のみ適用。
        #if !targetEnvironment(macCatalyst)
        .scrollPosition(id: $scrollPosition, anchor: .top)
        .onChange(of: viewModel.scrollResetToken) {
            // 田中報告 2026-05-30: iPad グリッドでもプルダウン更新で新着が画面外(上)に隠れ、検索位置も残る。
            // データ総入れ替え時は新しい先頭 gid へスクロールを固定し一番上を表示する。
            // ただし初回ロードは既に先頭表示なのでスキップ (起動時スキマ対策・上の didInitialReset 参照)。
            guard didInitialReset else { didInitialReset = true; return }
            scrollPosition = viewModel.galleries.first?.gid
        }
        #endif
        .refreshable { await viewModel.refresh() }
        .overlay {
            if let gallery = previewGallery {
                GalleryPreviewOverlay(
                    gallery: gallery,
                    host: viewModel.host,
                    onDismiss: { previewGallery = nil },
                    onTapPage: { thumbnails, page in
                        previewReaderRequest = GalleryPreviewReaderRequest(gallery: gallery, page: page, thumbnails: thumbnails)
                    }
                )
                .transition(.opacity)
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $previewReaderRequest) { req in
            GalleryReaderView(
                gallery: req.gallery,
                host: viewModel.host,
                initialPage: req.page,
                thumbnails: req.thumbnails
            )
            .onAppear {
                HistoryManager.shared.record(gallery: req.gallery, page: req.page)
                previewGallery = nil
            }
        }
        #endif
        #endif
    }

    @ViewBuilder
    private var originalListScroll: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.galleries.enumerated()), id: \.element.gid) { index, gallery in
                    // onTapGesture + onLongPressGesture: 長押し発火時は tap を抑制するSwiftUI標準動作
                    // UI 刷新 (2026-07-03): 行をカード化 (角丸 continuous + subtle shadow)
                    CardDesign.cardChrome(GalleryCardView(gallery: gallery))
                        .matchedTransitionSource(id: gallery.gid, in: zoomNamespace)   // B3 online
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 田中報告 2026-05-02: 別作品を開いて戻ると前の作品の詳細が出る問題対応 (path 残留対策)
                            navPath = NavigationPath()
                            DispatchQueue.main.async { navPath.append(gallery) }  // 同作品再タップ対策(別フレーム)
                        }
                        // iPadでGalleryCardView内NavigationLinkが長押しを奪うのでhighPriority
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.4, maximumDistance: 15)
                                .onEnded { _ in
                                    #if canImport(UIKit)
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    #endif
                                    previewGallery = gallery
                                }
                        )
                        .id(gallery.gid)
                    .onAppear {
                        // 次の3〜5件のカバー画像をバックグラウンドでプリフェッチ
                        let prefetchRange = (index + 1)...(index + 4)
                        let galleries = viewModel.galleries
                        Task.detached(priority: .userInitiated) {
                            for i in prefetchRange {
                                guard i < galleries.count else { break }
                                if let url = galleries[i].coverURL,
                                   ImageCache.shared.image(for: url) == nil,
                                   !ImageCache.shared.isLoading(url) {
                                    ImageCache.shared.setLoading(url)
                                    do {
                                        let data = try await EhClient.shared.fetchThumbData(url: url, host: .exhentai)
                                        #if canImport(UIKit)
                                        let ciCtx = SpriteCache.ciContext
                                        if let ciImage = CIImage(data: data),
                                           let cgImage = SpriteCache.makeDisplayCGImage(ciImage) {
                                            let img = UIImage(cgImage: cgImage)
                                            ImageCache.shared.setThumb(img, for: url)
                                        } else if let img = PlatformImage(data: data) {
                                            ImageCache.shared.setThumb(img, for: url)
                                        }
                                        #else
                                        if let img = PlatformImage(data: data) {
                                            ImageCache.shared.setThumb(img, for: url)
                                        }
                                        #endif
                                    } catch {
                                        // プリフェッチ失敗は無視（CachedImageViewが再試行する）
                                    }
                                    ImageCache.shared.removeLoading(url)
                                }
                            }
                        }
                    }

                    // UI 刷新 (2026-07-03): カード化に伴い区切り線は撤去 (カード間隔が分離を担う)
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

                // 田中要望 2026-07-03: 一覧の終端に件数フッターを表示
                if !viewModel.hasMore && !viewModel.galleries.isEmpty {
                    Text(viewModel.searchText.isEmpty
                         ? "全 \(viewModel.galleries.count) 件"
                         : "\(viewModel.galleries.count) 件見つかりました")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }

                if viewModel.galleries.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView {
                        Label(
                            authVM.isLoggedIn ? "ギャラリーがありません" : "未ログイン",
                            systemImage: authVM.isLoggedIn ? "photo.on.rectangle.angled" : "person.crop.circle.badge.exclamationmark"
                        )
                    } description: {
                        if let error = viewModel.errorMessage {
                            Text(error)
                        } else if !authVM.isLoggedIn {
                            Text("ログインしてください")
                        } else {
                            Text("プルダウンして再読み込み")
                        }
                    }
                    .padding(.top, 100)
                }
            }
        }
        .background(CardDesign.listBackground.ignoresSafeArea())
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { oldVal, newVal in
            let delta = newVal - oldVal
            if abs(delta) > 100 { return } // レイアウト変更による大ジャンプを無視
            if delta > 8 { onScrollDown?() }
            else if delta < -5 { onScrollUp?() }
        }
        .scrollPosition(id: $scrollPosition, anchor: .top)
        // Mac Catalyst は従来挙動を一切変えない (憲法: Mac は触らない)。iPhone/iPad のみ適用。
        #if !targetEnvironment(macCatalyst)
        .onChange(of: viewModel.scrollResetToken) {
            // 初回ロードは既に先頭表示なのでスキップ (起動時スキマ対策・didInitialReset 参照)。
            guard didInitialReset else { didInitialReset = true; return }
            // 田中報告 2026-05-30: プルダウン更新で新着が先頭に差し込まれても .scrollPosition が
            // 旧トップ作品を .top に固定し直し、新着が画面外(上)に隠れて「更新されない」ように見える。
            // 検索時も前のスクロール位置が残る。データ総入れ替え時は新しい先頭 gid へ固定し一番上を表示。
            scrollPosition = viewModel.galleries.first?.gid
        }
        #endif
        .refreshable { await viewModel.refresh() }
        .overlay {
            if let gallery = previewGallery {
                GalleryPreviewOverlay(
                    gallery: gallery,
                    host: viewModel.host,
                    onDismiss: { previewGallery = nil },
                    onTapPage: { thumbnails, page in
                        previewReaderRequest = GalleryPreviewReaderRequest(gallery: gallery, page: page, thumbnails: thumbnails)
                    }
                )
                .transition(.opacity)
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $previewReaderRequest) { req in
            GalleryReaderView(
                gallery: req.gallery,
                host: viewModel.host,
                initialPage: req.page,
                thumbnails: req.thumbnails
            )
            .onAppear {
                HistoryManager.shared.record(gallery: req.gallery, page: req.page)
                previewGallery = nil
            }
        }
        #endif
    }
}

/// プレビューから直接リーダーを開く用
struct GalleryPreviewReaderRequest: Identifiable {
    let id = UUID()
    let gallery: Gallery
    let page: Int
    var thumbnails: [ThumbnailInfo] = []
}

/// 長押しで表示される小窓プレビュー（背景タップで閉じる）
struct GalleryPreviewOverlay: View {
    let gallery: Gallery
    let host: GalleryHost
    let onDismiss: () -> Void
    /// (thumbnails, page) を返す。リーダーでサムネ再利用用
    let onTapPage: ([ThumbnailInfo], Int) -> Void

    @State private var thumbnails: [ThumbnailInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var visibleCount = 20

    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 6)]
    private let thumbsPerPage = 20

    var body: some View {
        ZStack {
            // 背景: タップで閉じる
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            // 小窓本体
            VStack(spacing: 0) {
                // ヘッダー
                HStack {
                    Text(gallery.title)
                        .font(.caption.bold())
                        .lineLimit(2)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()

                Divider()

                // サムネグリッド
                ScrollView {
                    if isLoading && thumbnails.isEmpty {
                        ProgressView().padding(.vertical, 40)
                    } else if let err = errorMessage {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(.orange)
                            Text(err).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 40)
                    } else if !isLoading && thumbnails.isEmpty {
                        // 古いギャラリーなどでparseが失敗するケース
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("サムネイル情報を取得できませんでした")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("古いギャラリーの場合があります")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button("1ページ目から読む") {
                                onTapPage([], 0)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 40)
                    } else {
                        // お気に入りキャッシュのGalleryはpageCount=0のケースがある
                        // そのため total は thumbnails.count も加味して決定
                        let totalPages = max(gallery.pageCount, thumbnails.count)
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(0..<min(visibleCount, totalPages), id: \.self) { index in
                                ThumbnailCellView(
                                    index: index,
                                    coverURL: gallery.coverURL,
                                    host: host,
                                    info: index < thumbnails.count ? thumbnails[index] : nil,
                                    cellHeight: 120,
                                    onTap: { onTapPage(thumbnails, index) },
                                    gid: gallery.gid
                                )
                                .onAppear {
                                    // 末尾近く到達で次ページ先読み（gallery.pageCount=0でも動作）
                                    if index >= thumbnails.count - 3 {
                                        let nextPage = thumbnails.count / thumbsPerPage
                                        loadThumbPageIfNeeded(page: nextPage)
                                    }
                                    // visibleCount拡張 - pageCount未知なら thumbnails.count+20 まで広げる
                                    let ceiling = gallery.pageCount > 0 ? gallery.pageCount : (thumbnails.count + 20)
                                    if index >= visibleCount - 6 && visibleCount < ceiling {
                                        visibleCount = min(visibleCount + 20, ceiling)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
            .frame(maxWidth: 600, maxHeight: 600)
            .padding()
        }
        .task {
            await loadInitial()
        }
    }

    private func loadInitial() async {
        LogManager.shared.log("preview", "loadInitial start gid=\(gallery.gid) host=\(host) pageCount=\(gallery.pageCount)")
        isLoading = true
        errorMessage = nil
        do {
            let infos = try await EhClient.shared.fetchThumbnailInfos(host: host, gallery: gallery, page: 0)
            LogManager.shared.log("preview", "loadInitial ok gid=\(gallery.gid) infos=\(infos.count)")
            thumbnails = infos
            isLoading = false
        } catch {
            LogManager.shared.log("preview", "loadInitial failed gid=\(gallery.gid): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    @State private var loadingPages: Set<Int> = []

    private func loadThumbPageIfNeeded(page: Int) {
        guard !loadingPages.contains(page), page > 0 else { return }
        loadingPages.insert(page)
        Task {
            do {
                let infos = try await EhClient.shared.fetchThumbnailInfos(host: host, gallery: gallery, page: page)
                let offset = page * thumbsPerPage
                let reindexed = infos.enumerated().map { (i, info) in
                    ThumbnailInfo(index: offset + i, spriteURL: info.spriteURL, offsetX: info.offsetX, width: info.width, height: info.height)
                }
                var current = thumbnails
                while current.count < offset + reindexed.count {
                    current.append(ThumbnailInfo(index: current.count, spriteURL: URL(string: "about:blank")!, offsetX: 0, width: 0, height: 0))
                }
                for info in reindexed where info.index < current.count {
                    current[info.index] = info
                }
                thumbnails = current
            } catch {
                loadingPages.remove(page)
            }
        }
    }
}


/// iOS 26+ Liquid Glass を使ったすりガラス窓モディファイア。
/// 旧 OS は単純な角丸クリップへフォールバック (Form の不透明背景がそのまま見える)。
private struct LiquidGlassWindow: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
