import SwiftUI
import Combine

/// nhentaiギャラリー詳細画面（E-HentaiのGalleryDetailViewと同等）
struct NhentaiDetailView: View {
    let initialGallery: NhentaiClient.NhGallery
    @StateObject private var detail = NhDetailLoader()

    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var coverImage: PlatformImage?
    @State private var readerRequest: NhReaderRequest?
    @State private var isFavorited: Bool
    @State private var cortexSearchURL: URL?
    @State private var showFavFailedAlert = false
    @State private var favFailedGalleryId: Int = 0

    private var gallery: NhentaiClient.NhGallery { detail.gallery ?? initialGallery }

    init(gallery: NhentaiClient.NhGallery) {
        self.initialGallery = gallery
        self._isFavorited = State(initialValue: NhentaiFavoritesCache.shared.contains(id: gallery.id))
    }

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                infoSection
                if let tags = gallery.tags, !tags.isEmpty {
                    tagsSection(tags)
                }
                actionButtons
                thumbnailGrid
            }
            .padding()
        }
        .navigationTitle(gallery.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $readerRequest) { req in
            NhentaiReaderView(gallery: gallery, initialPage: req.page)
        }
        #endif
        .navigationDestination(for: NhTagSearch.self) { search in
            NhTagSearchResultView(search: search)
        }
        .id(initialGallery.id)
        .sheet(item: $cortexSearchURL) { url in
            InAppBrowserView(url: url)
        }
        .alert("サーバー反映に失敗しました", isPresented: $showFavFailedAlert) {
            Button("Safari で完了") {
                #if canImport(UIKit)
                if let url = URL(string: "https://nhentai.net/g/\(favFailedGalleryId)/") {
                    UIApplication.shared.open(url)
                }
                #endif
            }
            Button("設定で再認証") {
                NotificationCenter.default.post(name: .navigateToSettingsTab, object: nil)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ローカルには追加済みです。Safari で手動完了するか、設定から nhentai に再認証してください。")
        }
        .task {
            await loadFullDetail()
            await loadCover()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            // カバー画像
            Group {
                if let img = coverImage {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .overlay { ProgressView() }
                }
            }
            .frame(width: 120, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                // タイトル
                if let jp = gallery.title.japanese {
                    Text(jp)
                        .font(.subheadline.bold())
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if let en = gallery.title.english, en != gallery.title.japanese {
                    Text(en)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                Spacer()

                // お気に入りボタン
                // ファボ追加: ローカル即時追加 + 裏サーバー試行 → 失敗時 Safari 誘導
                // ファボ削除: CF 鉄壁のため問答無用で Safari 誘導（ローカルは即時削除）
                if NhentaiCookieManager.isLoggedIn() {
                    Button {
                        let gid = gallery.id
                        if isFavorited {
                            // アンファボ: ローカル即時削除 → Safari
                            isFavorited = false
                            NhentaiFavoritesCache.shared.removeFromCache(id: gid)
                            #if canImport(UIKit)
                            if let url = URL(string: "https://nhentai.net/g/\(gid)/") {
                                UIApplication.shared.open(url)
                                LogManager.shared.log("nhentai", "unfavorite gid=\(gid) → local removed + Safari")
                            }
                            #endif
                        } else {
                            // ファボ追加: ローカル即時追加 → 裏サーバー試行
                            isFavorited = true
                            let capturedGallery = gallery
                            NhentaiFavoritesCache.shared.addToCache(capturedGallery)
                            Task {
                                let result = (try? await NhentaiClient.toggleFavorite(galleryId: gid)) ?? false
                                if result {
                                    LogManager.shared.log("nhentai", "favorite gid=\(gid) (server confirmed)")
                                } else {
                                    // サーバー失敗 → UI は維持、確認 alert を出す
                                    LogManager.shared.log("nhentai", "favorite gid=\(gid) server failed → showing alert")
                                    await MainActor.run {
                                        favFailedGalleryId = gid
                                        showFavFailedAlert = true
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(
                            isFavorited ? "お気に入り済み" : "お気に入り",
                            systemImage: isFavorited ? "heart.fill" : "heart"
                        )
                        .font(.caption)
                        .foregroundStyle(isFavorited ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Info

    private var infoSection: some View {
        GroupBox("情報") {
            VStack(spacing: 8) {
                // 言語
                let languages = gallery.tags?.filter { $0.type == "language" }.map(\.name) ?? []
                if !languages.isEmpty {
                    infoRow("言語", value: languages.joined(separator: ", "))
                }

                infoRow("ページ数", value: "\(gallery.num_pages)")

                // サークル
                let groups = gallery.tags?.filter { $0.type == "group" }.map(\.name) ?? []
                if !groups.isEmpty {
                    infoRow("サークル", value: groups.joined(separator: ", "))
                }

                // 作家
                let artists = gallery.tags?.filter { $0.type == "artist" }.map(\.name) ?? []
                if !artists.isEmpty {
                    infoRow("作家", value: artists.joined(separator: ", "))
                }

                // パロディ
                let parodies = gallery.tags?.filter { $0.type == "parody" }.map(\.name) ?? []
                if !parodies.isEmpty {
                    infoRow("パロディ", value: parodies.joined(separator: ", "))
                }

                // カテゴリ
                let categories = gallery.tags?.filter { $0.type == "category" }.map(\.name) ?? []
                if !categories.isEmpty {
                    infoRow("カテゴリ", value: categories.joined(separator: ", "))
                }

                infoRow("ID", value: "\(gallery.id)")
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption)
        }
    }

    // MARK: - Tags

    @AppStorage("cortexProtocolUnlocked") private var cortexUnlocked = false

    private func cortexAge(for characterName: String) -> Int? {
        guard let ages = UserDefaults.standard.dictionary(forKey: "cortex_character_ages") as? [String: Int] else { return nil }
        if let age = ages[characterName] { return age }
        for (name, age) in ages {
            if name.localizedCaseInsensitiveCompare(characterName) == .orderedSame { return age }
            if characterName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(characterName) { return age }
        }
        return nil
    }

    @ViewBuilder
    private func tagsSection(_ tags: [NhentaiClient.NhTag]) -> some View {
        let grouped = Dictionary(grouping: tags, by: \.type)

        GroupBox("タグ") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(grouped.keys.sorted()), id: \.self) { type in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(type)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        FlowLayout(spacing: 4) {
                            ForEach(grouped[type] ?? [], id: \.id) { tag in
                                HStack(spacing: 2) {
                                    NavigationLink(value: NhTagSearch(type: type, name: tag.name)) {
                                        Text(tag.name)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(tagColor(for: type).opacity(0.12))
                                            .foregroundStyle(tagColor(for: type))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }

                                    if cortexUnlocked && type == "character" {
                                        if let age = cortexAge(for: tag.name) {
                                            Text("\(age)")
                                                .font(.system(size: 9).monospaced().bold())
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.green.opacity(0.2))
                                                .foregroundStyle(.green)
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        }
                                        Button {
                                            let query = "\(tag.name) Animecharacter Age".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag.name
                                            if let url = URL(string: "https://www.google.com/search?q=\(query)") {
                                                cortexSearchURL = url
                                            }
                                        } label: {
                                            Image(systemName: "magnifyingglass")
                                                .font(.system(size: 9))
                                                .padding(3)
                                                .background(Color.cyan.opacity(0.15))
                                                .foregroundStyle(.cyan)
                                                .clipShape(Circle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func tagColor(for type: String) -> Color {
        switch type {
        case "artist": return .purple
        case "group": return .orange
        case "parody": return .green
        case "character": return .pink
        case "tag": return .blue
        case "language": return .teal
        case "category": return .brown
        default: return .gray
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 8) {
            // 最初から読む
            Button {
                HistoryManager.shared.recordNhentai(gallery: gallery, page: 0)
                readerRequest = NhReaderRequest(page: 0)
            } label: {
                Label("最初から読む", systemImage: "book.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .bold()
            }

            // ダウンロード
            nhDownloadButton
        }
    }

    @ViewBuilder
    private var nhDownloadButton: some View {
        let gid = -gallery.id

        if downloadManager.isDownloaded(gid: gid) {
            Label("ダウンロード済み", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
                .padding()
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let progress = downloadManager.activeDownloads[gid] {
            VStack(spacing: 6) {
                HStack {
                    Text("ダウンロード中 \(progress.current)/\(progress.total)")
                        .font(.subheadline).bold()
                    Spacer()
                    Button("キャンセル") {
                        downloadManager.cancelDownload(gid: gid)
                    }
                    .font(.caption).foregroundStyle(.red)
                }
                ProgressView(value: progress.fraction)
                    .tint(.orange)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Button {
                downloadManager.startNhentaiDownload(gallery: gallery)
            } label: {
                Label("ダウンロード", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .bold()
            }
        }
    }

    // MARK: - Thumbnail Grid

    private var thumbnailGrid: some View {
        GroupBox("ページ一覧（\(gallery.num_pages)ページ）") {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<gallery.num_pages, id: \.self) { index in
                    NhThumbCell(gallery: gallery, index: index, coverImage: coverImage) {
                        HistoryManager.shared.recordNhentai(gallery: gallery, page: index)
                        readerRequest = NhReaderRequest(page: index)
                    }
                }
            }
        }
        .task { await prefetchAllNhThumbs() }
    }

    /// サムネを先行取得（最大100件。残りはスクロールでオンデマンド取得）
    /// リーダー表示中も Task が生存するため、読みながらサムネが埋まっていく
    private func prefetchAllNhThumbs() async {
        guard let pages = gallery.images?.pages, !pages.isEmpty else { return }
        let mediaId = gallery.media_id
        let totalPages = pages.count
        let maxPrefetch = min(100, totalPages) // 最大100件（235ページで3.8秒フリーズ防止）

        // Phase 1: 1-20 を高優先で並列取得
        let priorityEnd = min(20, maxPrefetch)
        await fetchNhThumbBatch(pages: pages, mediaId: mediaId, range: 0..<priorityEnd, priority: .userInitiated)

        // Phase 2: 21-100 をバックグラウンドで取得（15枚ずつバッチ）
        if maxPrefetch > 20 {
            let batchSize = 15
            for batchStart in stride(from: 20, to: maxPrefetch, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, maxPrefetch)
                await fetchNhThumbBatch(pages: pages, mediaId: mediaId, range: batchStart..<batchEnd, priority: .utility)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        LogManager.shared.log("nhentai", "prefetchNhThumbs: \(maxPrefetch)/\(totalPages) done (remaining on-demand)")
    }

    private func fetchNhThumbBatch(
        pages: [NhentaiClient.NhPage],
        mediaId: String,
        range: Range<Int>,
        priority: TaskPriority
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for idx in range {
                let cacheKey = NhThumbCell.thumbCacheURL(mediaId: mediaId, page: idx + 1)
                // 既にキャッシュ済みならスキップ
                guard ImageCache.shared.image(for: cacheKey) == nil else { continue }
                let page = pages[idx]
                let pageNum = idx + 1

                group.addTask(priority: priority) {
                    guard let data = try? await NhentaiClient.fetchThumbImage(
                        mediaId: mediaId, page: pageNum, ext: page.ext, path: page.thumbPath
                    ) else { return }
                    #if canImport(UIKit)
                    let ciCtx = SpriteCache.ciContext
                    if let ciImage = CIImage(data: data),
                       let cgImage = ciCtx.createCGImage(ciImage, from: ciImage.extent) {
                        ImageCache.shared.setThumb(UIImage(cgImage: cgImage), for: cacheKey)
                        return
                    }
                    #endif
                    if let img = PlatformImage(data: data) {
                        ImageCache.shared.setThumb(img, for: cacheKey)
                    }
                }
            }
        }
    }

    // MARK: - Detail Loading

    private func loadFullDetail() async {
        await detail.load(id: initialGallery.id)
    }

    // MARK: - Cover Loading

    private func loadCover() async {
        guard let cover = gallery.images?.cover else { return }
        if let data = try? await NhentaiClient.fetchCoverImage(
            galleryId: gallery.id, mediaId: gallery.media_id, ext: cover.ext, path: cover.path
        ), let img = PlatformImage(data: data) {
            coverImage = img
        }
    }
}

/// fullScreenCover(item:) 用
private struct NhReaderRequest: Identifiable {
    let id = UUID()
    let page: Int
}

/// サムネセル（拡張子フォールバック付き取得）
private struct NhThumbCell: View {
    let gallery: NhentaiClient.NhGallery
    let index: Int
    /// 1ページ目のプレースホルダーとしてカバー画像を流用（E-Hと同じ設計）
    let coverImage: PlatformImage?
    let onTap: () -> Void

    @State private var thumbImage: PlatformImage?
    @State private var failed = false
    @State private var isLoading = false

    /// prefetch と共有するキャッシュキー（安定した URL 形式）
    static func thumbCacheURL(mediaId: String, page: Int) -> URL {
        URL(string: "nhthumb://\(mediaId)/\(page)")!
    }

    var body: some View {
        Button(action: onTap) {
            Group {
                if let img = thumbImage {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if index == 0, let coverImage {
                    // カバー画像を1ページ目のプレースホルダーに流用（追加コスト0）
                    Image(platformImage: coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if failed {
                    Color.gray.opacity(0.2)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                } else {
                    Color.gray.opacity(0.1)
                        .overlay { ProgressView().scaleEffect(0.6) }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomTrailing) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(2)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(2)
            }
        }
        .buttonStyle(.plain)
        .onChange(of: gallery.num_pages) { _, newCount in
            if thumbImage == nil && !isLoading && newCount > 0 {
                if let pages = gallery.images?.pages, index < pages.count {
                    failed = false
                    loadThumb()
                }
            }
        }
        .onAppear { loadThumb() }
    }

    private func loadThumb() {
        guard thumbImage == nil, !failed, !isLoading else { return }
        guard let pages = gallery.images?.pages, index < pages.count else { return }

        // ★ prefetch 済みキャッシュをチェック（ImageCache 経由）
        let cacheKey = Self.thumbCacheURL(mediaId: gallery.media_id, page: index + 1)
        if let cached = ImageCache.shared.image(for: cacheKey) {
            thumbImage = cached
            return
        }

        isLoading = true
        let mediaId = gallery.media_id
        let page = pages[index]
        let ext = page.ext
        let pageNum = index + 1
        let thumbPath = page.thumbPath
        Task.detached(priority: .userInitiated) {
            guard let data = try? await NhentaiClient.fetchThumbImage(
                mediaId: mediaId, page: pageNum, ext: ext, path: thumbPath
            ) else {
                await MainActor.run { failed = true; isLoading = false }
                return
            }
            #if canImport(UIKit)
            // GPU 経由デコード
            let ciCtx = SpriteCache.ciContext
            if let ciImage = CIImage(data: data),
               let cgImage = ciCtx.createCGImage(ciImage, from: ciImage.extent) {
                let img = UIImage(cgImage: cgImage)
                ImageCache.shared.setThumb(img, for: cacheKey)
                await MainActor.run { thumbImage = img; isLoading = false }
                return
            }
            #endif
            if let img = PlatformImage(data: data) {
                ImageCache.shared.setThumb(img, for: cacheKey)
                await MainActor.run { thumbImage = img; isLoading = false }
            } else {
                await MainActor.run { failed = true; isLoading = false }
            }
        }
    }
}

// MARK: - nhentaiタグ検索

struct NhTagSearch: Hashable {
    let type: String
    let name: String
    var query: String { "\(type):\(name.replacingOccurrences(of: " ", with: "-"))" }
    var displayTitle: String { "\(type): \(name)" }
}

struct NhTagSearchResultView: View {
    let search: NhTagSearch
    @State private var galleries: [NhentaiClient.NhGallery] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var currentPage = 1

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(galleries) { nh in
                    NavigationLink(value: nh) {
                        NhentaiCardView(gallery: nh)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading)
                }

                if hasMore && !galleries.isEmpty {
                    ProgressView()
                        .padding()
                        .task { await loadNext() }
                }

                if galleries.isEmpty && !isLoading {
                    ContentUnavailableView {
                        Label("結果なし", systemImage: "magnifyingglass")
                    }
                    .padding(.top, 100)
                }
            }
        }
        .navigationTitle(search.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: NhentaiClient.NhGallery.self) { nh in
            NhentaiDetailView(gallery: nh)
        }
        .overlay {
            if isLoading && galleries.isEmpty {
                ProgressView("検索中...")
            }
        }
        .task { await loadFirst() }
    }

    private func loadFirst() async {
        isLoading = true
        currentPage = 1
        do {
            let result = try await NhentaiClient.search(query: search.query, page: 1)
            galleries = result.result
            hasMore = result.num_pages > 1
        } catch {
            LogManager.shared.log("nhentai", "tag search failed: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func loadNext() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        currentPage += 1
        do {
            let result = try await NhentaiClient.search(query: search.query, page: currentPage)
            galleries.append(contentsOf: result.result)
            hasMore = currentPage < result.num_pages
        } catch {
            LogManager.shared.log("nhentai", "tag search next failed: \(error.localizedDescription)")
        }
        isLoading = false
    }
}

// MARK: - Detail Loader

@MainActor
class NhDetailLoader: ObservableObject {
    @Published var gallery: NhentaiClient.NhGallery?
    @Published var isLoading = false

    func load(id: Int) async {
        guard gallery == nil || gallery?.num_pages == 0 else { return }
        isLoading = true
        do {
            let full = try await NhentaiClient.fetchGallery(id: id)
            gallery = full
            LogManager.shared.log("nhentai", "detail loaded: id=\(full.id) pages=\(full.num_pages) tags=\(full.tags?.count ?? 0)")
        } catch {
            LogManager.shared.log("nhentai", "detail load failed: \(error.localizedDescription)")
        }
        isLoading = false
    }
}
