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
        NavigationStack {
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

                if selectedSource == .ehentai {
                    ehentaiContent
                } else {
                    nhentaiContent
                }
            }
            .navigationTitle("Cort:EX")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(tabBarHidden ? .hidden : .visible, for: .tabBar)
            .animation(.smooth(duration: 0.25), value: tabBarHidden)
            #endif
            .navigationDestination(for: Gallery.self) { gallery in
                GalleryDetailView(gallery: gallery, host: currentHost)
            }
            .navigationDestination(for: NhentaiClient.NhGallery.self) { nh in
                NhentaiDetailView(gallery: nh)
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
            }
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
            .onChange(of: selectedSource) { _, _ in
                searchText = ""
            }
        }
    }

    // MARK: - E-Hentai

    private var ehentaiContent: some View {
        VStack(spacing: 0) {
            if isSearchActive {
                HStack {
                    Text("検索: \(currentVM.searchText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        clearSearch()
                    } label: {
                        Label("クリア", systemImage: "xmark.circle.fill")
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.08))
            }

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

            switch selectedTab {
            case .all:
                GalleryScrollList(viewModel: allVM, authVM: authVM, onScrollDown: { tabBarHidden = true }, onScrollUp: { tabBarHidden = false })
            case .doujinshi:
                GalleryScrollList(viewModel: doujinshiVM, authVM: authVM, onScrollDown: { tabBarHidden = true }, onScrollUp: { tabBarHidden = false })
            case .manga:
                GalleryScrollList(viewModel: mangaVM, authVM: authVM, onScrollDown: { tabBarHidden = true }, onScrollUp: { tabBarHidden = false })
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
                HStack {
                    Text("検索: \(nhVM.searchText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        searchText = ""
                        nhVM.clearSearch()
                    } label: {
                        Label("クリア", systemImage: "xmark.circle.fill")
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
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

            NhentaiScrollList(viewModel: nhVM, onScrollDown: { tabBarHidden = true }, onScrollUp: { tabBarHidden = false })
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
        isSearchActive = false
        Task { await currentVM.refresh() }
    }

    private func setupVM(_ vm: GalleryListViewModel, tab: GalleryTab) {
        guard vm.baseQuery == nil else { return }
        let exclude = "-language:korean -language:translated"
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
    }
}

// MARK: - E-Hentaiスクロールリスト

struct GalleryScrollList: View {
    @ObservedObject var viewModel: GalleryListViewModel
    @ObservedObject var authVM: AuthViewModel
    @State private var scrollPosition: Int?
    var onScrollDown: (() -> Void)?
    var onScrollUp: (() -> Void)?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.galleries.enumerated()), id: \.element.gid) { index, gallery in
                    NavigationLink(value: gallery) {
                        GalleryCardView(gallery: gallery)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
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
                                           let cgImage = ciCtx.createCGImage(ciImage, from: ciImage.extent) {
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
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { oldVal, newVal in
            let delta = newVal - oldVal
            if abs(delta) > 100 { return } // レイアウト変更による大ジャンプを無視
            if delta > 8 { onScrollDown?() }
            else if delta < -5 { onScrollUp?() }
        }
        .scrollPosition(id: $scrollPosition, anchor: .top)
        .refreshable { await viewModel.refresh() }
    }
}

// MARK: - nhentaiスクロールリスト

struct NhentaiScrollList: View {
    @ObservedObject var viewModel: NhentaiListViewModel
    var onScrollDown: (() -> Void)?
    var onScrollUp: (() -> Void)?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.galleries) { nh in
                    NavigationLink(value: nh) {
                        NhentaiCardView(gallery: nh)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

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
                        Label("ギャラリーがありません", systemImage: "photo.on.rectangle.angled")
                    }
                    .padding(.top, 100)
                }
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { oldVal, newVal in
            let delta = newVal - oldVal
            if delta > 15 { onScrollDown?() }
            else if delta < -15 { onScrollUp?() }
        }
        .refreshable { await viewModel.refresh() }
    }
}

// MARK: - nhentaiカードView

struct NhentaiCardView: View {
    let gallery: NhentaiClient.NhGallery
    @State private var coverImage: PlatformImage?

    var body: some View {
        HStack(spacing: 10) {
            // カバー
            if let img = coverImage {
                Image(platformImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 80, height: 110)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    .onAppear { loadCover() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(gallery.displayTitle)
                    .font(.subheadline)
                    .lineLimit(3)

                HStack(spacing: 4) {
                    Text("NH")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    if gallery.num_pages > 0 {
                        Text("\(gallery.num_pages) ページ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let tags = gallery.tags {
                    let langTags = tags.filter { $0.type == "language" }.map(\.name)
                    if !langTags.isEmpty {
                        Text(langTags.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    private func loadCover() {
        // v2: thumbnailPathがあればそれを使う、なければimages.cover
        let url: URL
        if let thumbPath = gallery.thumbnailPath {
            url = URL(string: "https://t.nhentai.net/\(thumbPath)")!
        } else if let cover = gallery.images?.cover {
            url = NhentaiClient.coverURL(mediaId: gallery.media_id, ext: cover.ext, path: cover.path)
        } else {
            return
        }

        if let cached = ImageCache.shared.image(for: url) {
            coverImage = cached
            return
        }

        Task {
            // 最大2回リトライ（CDNレート制限対策）
            for attempt in 1...2 {
                let coverExt = gallery.images?.cover?.ext ?? "jpg"
                let coverPath = gallery.thumbnailPath ?? gallery.images?.cover?.path
                let galleryId = gallery.id
                let mediaId = gallery.media_id
                let capturedURL = url

                // nhentaiカバーは小画像なのでCPUデコード（GPU dispatchオーバーヘッド回避）
                let decoded: PlatformImage? = await Task.detached(priority: .userInitiated) {
                    guard let data = try? await NhentaiClient.fetchCoverImage(
                        galleryId: galleryId, mediaId: mediaId,
                        ext: coverExt, path: coverPath
                    ) else { return nil }
                    return PlatformImage(data: data)
                }.value

                if let img = decoded {
                    ImageCache.shared.setThumb(img, for: capturedURL)
                    coverImage = img
                    return
                }

                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...4_000_000_000))
                } else {
                    LogManager.shared.log("nhentai", "cover failed: \(mediaId)")
                }
            }
        }
    }
}

/// nhentaiカバー画像の共通View（履歴・お気に入り等でも使用）
/// v2 path + disk/memory cache + 拡張子フォールバック対応
struct NhentaiCoverView: View {
    let gallery: NhentaiClient.NhGallery
    @State private var coverImage: PlatformImage?

    var body: some View {
        Group {
            if let img = coverImage {
                Image(platformImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.15)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    .onAppear { loadCover() }
            }
        }
    }

    private func loadCover() {
        let url: URL
        if let thumbPath = gallery.thumbnailPath {
            url = URL(string: "https://t.nhentai.net/\(thumbPath)")!
        } else if let cover = gallery.images?.cover {
            url = NhentaiClient.coverURL(mediaId: gallery.media_id, ext: cover.ext, path: cover.path)
        } else {
            return
        }

        if let cached = ImageCache.shared.image(for: url) {
            coverImage = cached
            return
        }

        Task {
            let coverExt = gallery.images?.cover?.ext ?? "jpg"
            let coverPath = gallery.thumbnailPath ?? gallery.images?.cover?.path
            let galleryId = gallery.id
            let mediaId = gallery.media_id
            let capturedURL = url

            let decoded: PlatformImage? = await Task.detached(priority: .userInitiated) {
                guard let data = try? await NhentaiClient.fetchCoverImage(
                    galleryId: galleryId, mediaId: mediaId,
                    ext: coverExt, path: coverPath
                ) else { return nil }
                return PlatformImage(data: data)
            }.value

            if let img = decoded {
                ImageCache.shared.setThumb(img, for: capturedURL)
                coverImage = img
            }
        }
    }
}
