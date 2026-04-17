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

    /// サムネグリッドに表示するページ数（順次追加）
    @State private var visibleThumbCount = 15
    @State private var lastThumbExpand = Date.distantPast

    private var thumbnailGrid: some View {
        let _ = LogManager.shared.log("nhDbg", "thumbnailGrid body eval pages=\(gallery.num_pages) visible=\(visibleThumbCount) hasImages=\(gallery.images != nil)")
        return GroupBox("ページ一覧（\(gallery.num_pages)ページ）") {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<min(visibleThumbCount, gallery.num_pages), id: \.self) { index in
                    NhThumbCell(gallery: gallery, index: index, coverImage: coverImage) {
                        HistoryManager.shared.recordNhentai(gallery: gallery, page: index)
                        readerRequest = NhReaderRequest(page: index)
                    }
                    .onAppear {
                        // ★ 本当に最後のセルが表示された時だけ追加（連鎖防止）
                        // LazyVGridのprefetchは先回りで.onAppearを発火させるので、
                        // 末尾5個判定だと連鎖反応で暴走する（15→45→75→...）
                        guard index == visibleThumbCount - 1,
                              visibleThumbCount < gallery.num_pages else { return }
                        // デバウンス: 前回増加から1秒以上経過してから
                        let now = Date()
                        if now.timeIntervalSince(lastThumbExpand) < 1.0 { return }
                        lastThumbExpand = now
                        visibleThumbCount = min(visibleThumbCount + 15, gallery.num_pages)
                    }
                }
            }
        }
        .task(id: gallery.images?.pages.count ?? 0) {
            // detailロード後にgallery.imagesが入る → このtaskが再起動
            guard let pages = gallery.images?.pages, !pages.isEmpty else { return }
            let mediaId = gallery.media_id
            LogManager.shared.log("nhentai", "prefetch triggered: mediaId=\(mediaId) pages=\(pages.count)")
            // regular Task: view消失時にキャンセル伝播 → 蓄積防止
            await NhentaiDetailView.prefetchNhThumbsStatic(pages: pages, mediaId: mediaId)
        }
    }

    /// E-H SpriteCache.imageQueue準拠: cooperative pool非占有の専用thread
    static let thumbProcessQueue = DispatchQueue(label: "nh-thumb-process", qos: .userInitiated)

    /// 専用DispatchQueueでpreDecode実行（cooperative pool競合回避）
    nonisolated static func decodeOnDedicatedQueue(_ data: Data, maxDim: CGFloat) async -> PlatformImage? {
        await withCheckedContinuation { cont in
            thumbProcessQueue.async {
                if let img = PlatformImage(data: data) {
                    cont.resume(returning: img.preDecoded(maxDim: maxDim))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// キャンセル伝播を受けない独立prefetch（static = MainActor非隔離）
    nonisolated private static func prefetchNhThumbsStatic(
        pages: [NhentaiClient.NhPage], mediaId: String
    ) async {
        // 全ページprefetch（スクロール時の個別fetch回避、ただし長すぎる場合は100上限）
        let maxPrefetch = min(100, pages.count)

        // Phase 0: 即座に全範囲をisLoading=trueにマーク（cellsの個別I/Oを防ぐ）
        for idx in 0..<maxPrefetch {
            let cacheKey = NhThumbCell.thumbCacheURL(mediaId: mediaId, page: idx + 1)
            if ImageCache.shared.memoryImage(for: cacheKey) == nil {
                ImageCache.shared.setLoading(cacheKey)
            }
        }

        // View初期化を阻害しない程度の短い待機
        try? await Task.sleep(nanoseconds: 100_000_000)

        var networkNeeded = 0
        var diskHits = 0

        // Phase 1: ディスクキャッシュから一括ロード（メモリへ格納、isLoading解除）
        for idx in 0..<maxPrefetch {
            let cacheKey = NhThumbCell.thumbCacheURL(mediaId: mediaId, page: idx + 1)
            if ImageCache.shared.memoryImage(for: cacheKey) != nil {
                ImageCache.shared.removeLoading(cacheKey)
                continue
            }
            if ImageCache.shared.image(for: cacheKey) != nil {
                // image()内でメモリ格納される。preDecodeは重いので避ける
                ImageCache.shared.removeLoading(cacheKey)
                diskHits += 1
            } else {
                networkNeeded += 1
            }
        }
        LogManager.shared.log("nhentai", "prefetch phase1: \(diskHits) disk hits, \(networkNeeded) network needed")

        // Phase 2: 3並列DL + 縮小300px + バッチ間300msスリープ
        let batchSize = 3
        var idx = 0
        while idx < maxPrefetch {
            // view消失時のキャンセル伝播でループ終了（蓄積防止）
            if Task.isCancelled { break }
            let batchEnd = min(idx + batchSize, maxPrefetch)
            await withTaskGroup(of: Void.self) { group in
                for i in idx..<batchEnd {
                    let cacheKey = NhThumbCell.thumbCacheURL(mediaId: mediaId, page: i + 1)
                    if ImageCache.shared.memoryImage(for: cacheKey) != nil {
                        ImageCache.shared.removeLoading(cacheKey)
                        continue
                    }
                    let page = pages[i]
                    let pageNum = i + 1
                    group.addTask {
                        if Task.isCancelled {
                            ImageCache.shared.removeLoading(cacheKey)
                            return
                        }
                        if let data = try? await NhentaiClient.fetchThumbImage(
                            mediaId: mediaId, page: pageNum, ext: page.ext, path: page.thumbPath
                        ), let decoded = await NhentaiDetailView.decodeOnDedicatedQueue(data, maxDim: 300) {
                            ImageCache.shared.setThumb(decoded, for: cacheKey)
                        }
                        ImageCache.shared.removeLoading(cacheKey)
                    }
                }
            }
            idx = batchEnd
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        LogManager.shared.log("nhentai", "prefetchNhThumbs: \(maxPrefetch)/\(pages.count) done")
    }

    // MARK: - Detail Loading

    private func loadFullDetail() async {
        await detail.load(id: initialGallery.id)
    }

    // MARK: - Cover Loading

    private func loadCover() async {
        // 一覧画面で既に取得済みのカバーを ImageCache から流用（ネットワーク不要）
        let coverURL: URL?
        if let thumbPath = gallery.thumbnailPath {
            coverURL = URL(string: "https://t.nhentai.net/\(thumbPath)")
        } else if let cover = gallery.images?.cover {
            coverURL = NhentaiClient.coverURL(mediaId: gallery.media_id, ext: cover.ext, path: cover.path)
        } else {
            coverURL = nil
        }
        if let coverURL, let cached = ImageCache.shared.image(for: coverURL) {
            coverImage = cached
            return
        }

        // キャッシュにない場合のみネットワーク取得
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
    let coverImage: PlatformImage?
    let onTap: () -> Void

    @State private var thumbImage: PlatformImage?
    @State private var failed = false

    /// prefetch と共有するキャッシュキー（安定した URL 形式）
    static func thumbCacheURL(mediaId: String, page: Int) -> URL {
        URL(string: "nhthumb://\(mediaId)/\(page)")!
    }

    /// task(id:) 用の安定キー
    private var cacheKey: URL {
        Self.thumbCacheURL(mediaId: gallery.media_id, page: index + 1)
    }

    var body: some View {
        // E-H ThumbnailCellView準拠: ButtonではなくonTapGesture
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = thumbImage {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 150, maxHeight: 150)
                        .clipped()
                } else if index == 0, let coverImage {
                    Image(platformImage: coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 150, maxHeight: 150)
                        .clipped()
                } else if failed {
                    Color.gray.opacity(0.2)
                        .frame(height: 150)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                } else {
                    Color.gray.opacity(0.1)
                        .frame(height: 150)
                        .overlay { ProgressView().scaleEffect(0.6) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .overlay(alignment: .bottomTrailing) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold))
                .padding(2)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(2)
        }
        // E-H準拠: cacheKeyが変わらない限り1回だけ実行
        .task(id: cacheKey) {
            await loadThumb()
        }
    }

    /// MainActorから完全分離したサムネ取得（E-H ThumbnailCellView準拠）
    private func loadThumb() async {
        guard thumbImage == nil, !failed else { return }
        guard let pages = gallery.images?.pages, index < pages.count else { return }

        // 1. メモリキャッシュ（即座、I/Oなし）
        if let cached = ImageCache.shared.memoryImage(for: cacheKey) {
            thumbImage = cached
            return
        }

        // 2-4 を全てTask.detachedで実行（MainActorディスクI/O完全排除）
        let mediaId = gallery.media_id
        let page = pages[index]
        let pageNum = index + 1
        let key = cacheKey
        let isLoading = ImageCache.shared.isLoading(key)

        let result: PlatformImage? = await Task.detached(priority: .utility) {
            // 2. ディスクキャッシュ
            if let cached = ImageCache.shared.image(for: key) {
                return cached
            }

            // 3. prefetch進行中なら完了を待つ
            if isLoading {
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if let cached = ImageCache.shared.memoryImage(for: key) {
                        return cached
                    }
                    if !ImageCache.shared.isLoading(key) { break }
                }
                if let cached = ImageCache.shared.image(for: key) {
                    return cached
                }
            }

            // 4. ネットワーク取得
            guard let data = try? await NhentaiClient.fetchThumbImage(
                mediaId: mediaId, page: pageNum, ext: page.ext, path: page.thumbPath
            ) else { return nil }
            if let decoded = await NhentaiDetailView.decodeOnDedicatedQueue(data, maxDim: 300) {
                ImageCache.shared.setThumb(decoded, for: key)
                return decoded
            }
            return nil
        }.value

        if let result {
            thumbImage = result
        } else {
            failed = true
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
