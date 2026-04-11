import SwiftUI
import TipKit
#if canImport(UIKit)
import WebKit
#endif

// MARK: - スプライト画像キャッシュ（メモリ + ImageCacheのディスクキャッシュ）

final class SpriteCache {
    static let shared = SpriteCache()
    private let sprites = NSCache<NSURL, PlatformImage>()
    private let croppedCache = NSCache<NSString, PlatformImage>()

    init() {
        sprites.countLimit = 30
        croppedCache.countLimit = 200
    }

    func sprite(for url: URL) -> PlatformImage? {
        if let mem = sprites.object(forKey: url as NSURL) { return mem }
        if let disk = ImageCache.shared.image(for: url) {
            sprites.setObject(disk, forKey: url as NSURL)
            return disk
        }
        return nil
    }

    func setSprite(_ image: PlatformImage, for url: URL) {
        sprites.setObject(image, forKey: url as NSURL)
        ImageCache.shared.set(image, for: url)
    }

    func croppedKey(url: URL, offsetX: CGFloat) -> String {
        "\(url.absoluteString)_\(Int(offsetX))"
    }

    private func croppedURL(key: String) -> URL {
        let stableHash = key.utf8.reduce(into: UInt64(5381)) { h, c in
            h = h &* 33 &+ UInt64(c)
        }
        return URL(string: "ehviewer-crop://\(stableHash)")!
    }

    func croppedImage(key: String) -> PlatformImage? {
        let nsKey = key as NSString
        if let mem = croppedCache.object(forKey: nsKey) { return mem }
        let url = croppedURL(key: key)
        if let disk = ImageCache.shared.image(for: url) {
            croppedCache.setObject(disk, forKey: nsKey)
            return disk
        }
        return nil
    }

    func setCropped(_ image: PlatformImage, key: String) {
        croppedCache.setObject(image, forKey: key as NSString)
        Task.detached(priority: .utility) {
            ImageCache.shared.set(image, for: self.croppedURL(key: key))
        }
    }
}

/// fullScreenCover(item:) 用のラッパー
private struct ReaderRequest: Identifiable {
    let id = UUID()
    let page: Int
}

/// タグ検索用のナビゲーション値
struct TagSearch: Hashable {
    let namespace: String
    let tag: String
    var query: String { "\(namespace):\"\(tag)$\"" }
    var displayTitle: String { "\(namespace):\(tag)" }
}

struct GalleryDetailView: View {
    let gallery: Gallery
    let host: GalleryHost

    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var detail: GalleryDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isGalleryRemoved = false
    @State private var nhSearchResults: [NhentaiClient.NhGallery] = []
    @State private var isSearchingNh = false
    @State private var copiedTitle = false
    @State private var selectedNhGallery: NhentaiClient.NhGallery?
    @State private var isLoadingNhDetail = false
    @State private var readerRequest: ReaderRequest?
    @State private var thumbnails: [ThumbnailInfo] = []
    @State private var croppedThumbs: [Int: PlatformImage] = [:]

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection(detail)
                    infoSection(detail)
                    if !detail.normalizedTags.isEmpty {
                        tagsSection(detail)
                    }
                    readButton(startPage: 0)
                    downloadButton(detail)
                    if !detail.comments.isEmpty {
                        commentsSection(detail.comments)
                    }
                    thumbnailGrid(detail)
                }
                .padding()
            } else if isLoading {
                ProgressView("読み込み中...")
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if isGalleryRemoved {
                VStack(spacing: 16) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.red)
                    Text("この作品はE-Hentaiから削除されました")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(gallery.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)

                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = gallery.title
                            #endif
                            copiedTitle = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedTitle = false }
                        } label: {
                            Image(systemName: copiedTitle ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(copiedTitle ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    TipView(RemovedGalleryTip(), arrowEdge: .bottom)
                        .padding(.horizontal)

                    Divider().padding(.horizontal, 40)

                    if isSearchingNh {
                        ProgressView("nhentaiを検索中...")
                    } else if !nhSearchResults.isEmpty {
                        Text("nhentaiで見つかりました")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)

                        if isLoadingNhDetail {
                            ProgressView("読み込み中...")
                                .padding(.vertical, 8)
                        }

                        ForEach(nhSearchResults) { nh in
                            Button {
                                Task {
                                    isLoadingNhDetail = true
                                    do {
                                        let full = try await NhentaiClient.fetchGallery(id: nh.id)
                                        selectedNhGallery = full
                                        LogManager.shared.log("nhentai", "nhSearch tap: id=\(full.id) pages=\(full.num_pages)")
                                    } catch {
                                        LogManager.shared.log("nhentai", "nhSearch tap failed: \(error.localizedDescription)")
                                        selectedNhGallery = nh
                                    }
                                    isLoadingNhDetail = false
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    // カバーサムネ
                                    if let cover = nh.images?.cover {
                                        AsyncImage(url: NhentaiClient.coverURL(mediaId: nh.media_id, ext: cover.ext)) { image in
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        } placeholder: {
                                            Color.gray.opacity(0.3)
                                        }
                                        .frame(width: 50, height: 70)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(nh.displayTitle)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .foregroundStyle(.primary)
                                        Text("\(nh.num_pages) ページ")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "book.fill")
                                        .foregroundStyle(.orange)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button {
                            searchNhentai()
                        } label: {
                            Label("nhentaiで探す", systemImage: "magnifyingglass")
                                .font(.headline)
                                .padding()
                                .frame(maxWidth: 260)
                                .background(.orange)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    Divider().padding(.horizontal, 40)

                    // Nyahentai（Safari外部リンク）
                    Button {
                        openNyahentai()
                    } label: {
                        Label("nyahentai.oneで探す", systemImage: "safari")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: 280)
                            .background(.purple)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // hitomi.la（Safari外部リンク）
                    Button {
                        openHitomi()
                    } label: {
                        Label("hitomi.laで探す", systemImage: "safari")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: 280)
                            .background(.pink)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("エラー", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            }
        }
        .navigationTitle(gallery.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS)
        .fullScreenCover(item: $readerRequest) { request in
            GalleryReaderView(
                gallery: detail?.gallery ?? gallery,
                host: host,
                initialPage: request.page,
                thumbnails: thumbnails
            )
            .onAppear {
                HistoryManager.shared.record(gallery: detail?.gallery ?? gallery, page: request.page)
            }
        }
        #else
        .sheet(item: $readerRequest) { request in
            GalleryReaderView(
                gallery: detail?.gallery ?? gallery,
                host: host,
                initialPage: request.page,
                thumbnails: thumbnails
            )
            .onAppear {
                HistoryManager.shared.record(gallery: detail?.gallery ?? gallery, page: request.page)
            }
        }
        #endif
        #if os(iOS)
        .fullScreenCover(item: $selectedNhGallery) { nh in
            NhentaiReaderView(gallery: nh)
        }
        #endif
        .navigationDestination(for: TagSearch.self) { search in
            TagSearchResultView(
                searchQuery: search.query,
                host: host,
                title: search.displayTitle
            )
        }
        .navigationDestination(for: UploaderSearch.self) { search in
            TagSearchResultView(
                searchQuery: search.query,
                host: host,
                title: search.displayTitle
            )
        }
        .sheet(item: $cortexSearchURL) { url in
            InAppBrowserView(url: url)
        }
        .toolbar {
            if let detail {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await toggleFavorite(detail) }
                    } label: {
                        Image(systemName: detail.isFavorited ? "heart.fill" : "heart")
                            .foregroundStyle(detail.isFavorited ? .red : .primary)
                    }
                }
            }
        }
        .task {
            await loadDetail()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerSection(_ detail: GalleryDetail) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CachedImageView(url: detail.gallery.coverURL, host: host)
                .frame(width: 140, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.gallery.title)
                    .font(.headline)
                    .lineLimit(4)
                    .contextMenu {
                        Button {
                            copyToClipboard(detail.gallery.title)
                        } label: {
                            Label("タイトルをコピー", systemImage: "doc.on.doc")
                        }
                        if let jpn = detail.jpnTitle, !jpn.isEmpty {
                            Button {
                                copyToClipboard(jpn)
                            } label: {
                                Label("日本語タイトルをコピー", systemImage: "doc.on.doc")
                            }
                        }
                    }

                if let jpnTitle = detail.jpnTitle, !jpnTitle.isEmpty {
                    Text(jpnTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .contextMenu {
                            Button {
                                copyToClipboard(jpnTitle)
                            } label: {
                                Label("コピー", systemImage: "doc.on.doc")
                            }
                        }
                }

                Spacer()

                if let category = detail.gallery.category {
                    Text(category.rawValue)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: category.color))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        let v = detail.gallery.rating - Double(i)
                        Image(systemName: v >= 1 ? "star.fill" : v >= 0.5 ? "star.leadinghalf.filled" : "star")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                    Text(String(format: "%.1f", detail.gallery.rating))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Info

    @ViewBuilder
    private func infoSection(_ detail: GalleryDetail) -> some View {
        GroupBox("情報") {
            VStack(spacing: 8) {
                if let uploader = detail.gallery.uploader, !uploader.isEmpty {
                    HStack {
                        Text("投稿者").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        NavigationLink(value: UploaderSearch(uploader: uploader)) {
                            Text(uploader)
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                if let language = detail.language { infoRow("言語", value: language) }
                infoRow("ページ数", value: "\(detail.gallery.pageCount)")
                if let fileSize = detail.fileSize { infoRow("ファイルサイズ", value: fileSize) }
                if !detail.gallery.postedDate.isEmpty { infoRow("投稿日", value: detail.gallery.postedDate) }
                if let fav = detail.favoritedCount { infoRow("お気に入り数", value: "\(fav)") }
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption)
        }
    }

    // MARK: - Tags

    @AppStorage("cortexProtocolUnlocked") private var cortexUnlocked = false
    @State private var cortexSearchURL: URL?

    private func cortexAge(for characterName: String) -> Int? {
        guard let ages = UserDefaults.standard.dictionary(forKey: "cortex_character_ages") as? [String: Int] else { return nil }
        // 完全一致
        if let age = ages[characterName] { return age }
        // 部分一致（CENSUSで登録した名前と詳細タグの名前が微妙に違う場合）
        for (name, age) in ages {
            if name.localizedCaseInsensitiveCompare(characterName) == .orderedSame { return age }
            if characterName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(characterName) { return age }
        }
        return nil
    }

    private func tagsSection(_ detail: GalleryDetail) -> some View {
        GroupBox("タグ") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(detail.normalizedTags.keys.sorted()), id: \.self) { namespace in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(namespace)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        FlowLayout(spacing: 4) {
                            ForEach(detail.normalizedTags[namespace] ?? [], id: \.self) { tag in
                                HStack(spacing: 2) {
                                    NavigationLink(value: TagSearch(namespace: namespace, tag: tag)) {
                                        Text(tag)
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.12))
                                            .foregroundStyle(.blue)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }

                                    // CORTEX PROTOCOL: character tag age + search
                                    if cortexUnlocked && namespace == "character" {
                                        if let age = cortexAge(for: tag) {
                                            Text("\(age)")
                                                .font(.system(size: 9).monospaced().bold())
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.green.opacity(0.2))
                                                .foregroundStyle(.green)
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        }
                                        Button {
                                            let query = "\(tag) Animecharacter Age".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
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

    // MARK: - Comments

    @ViewBuilder
    private func commentsSection(_ comments: [GalleryComment]) -> some View {
        GroupBox("コメント（\(comments.count)）") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(comments.prefix(10).enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(comment.author)
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                            Spacer()
                            if let score = comment.score {
                                Text(score)
                                    .font(.caption2)
                                    .foregroundStyle(score.hasPrefix("-") ? .red : .green)
                            }
                        }
                        Text(comment.date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(comment.content)
                            .font(.caption)
                            .lineLimit(8)
                    }
                    .padding(.vertical, 4)
                    if comment.author != comments.prefix(10).last?.author || comment.date != comments.prefix(10).last?.date {
                        Divider()
                    }
                }
                if comments.count > 10 {
                    Text("他 \(comments.count - 10) 件のコメント")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Read Button

    private func readButton(startPage: Int) -> some View {
        Button {
            readerRequest = ReaderRequest(page: startPage)
        } label: {
            Label("最初から読む", systemImage: "book.fill")
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .bold()
        }
    }

    // MARK: - Download Button

    @ViewBuilder
    private func downloadButton(_ detail: GalleryDetail) -> some View {
        let dm = downloadManager
        let gid = detail.gallery.gid

        if dm.isDownloaded(gid: gid) {
            Label("ダウンロード済み", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
                .padding()
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let progress = dm.activeDownloads[gid] {
            VStack(spacing: 6) {
                HStack {
                    Text("ダウンロード中 \(progress.current)/\(progress.total)")
                        .font(.subheadline)
                        .bold()
                    Spacer()
                    Button("キャンセル") {
                        dm.cancelDownload(gid: gid)
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                ProgressView(value: progress.fraction)
                    .tint(.blue)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Button {
                dm.startDownload(gallery: detail.gallery, host: host)
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

    @ViewBuilder
    private func thumbnailGrid(_ detail: GalleryDetail) -> some View {
        GroupBox("ページ一覧（\(detail.gallery.pageCount)ページ）") {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<detail.gallery.pageCount, id: \.self) { index in
                    thumbnailCell(index: index)
                }
            }
        }
        .task {
            await loadThumbnails()
        }
    }

    private let thumbCellHeight: CGFloat = 150

    private func thumbnailCell(index: Int) -> some View {
        ThumbnailCellView(
            index: index,
            coverURL: gallery.coverURL,
            host: host,
            info: index < thumbnails.count ? thumbnails[index] : nil,
            cellHeight: thumbCellHeight,
            onTap: { readerRequest = ReaderRequest(page: index) }
        )
    }

    private func placeholderView(index: Int) -> some View {
        VStack {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text("\(index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Data Loading

    private func loadDetail() async {
        isLoading = true
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let result = try await EhClient.shared.fetchGalleryDetail(host: host, gallery: gallery)
            let dt = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            LogManager.shared.log("Perf", "loadDetail: \(dt)ms gid=\(gallery.gid) pages=\(result.gallery.pageCount) tags=\(result.normalizedTags.count)")
            if result.gallery.pageCount == 0 {
                isGalleryRemoved = true
            } else {
                detail = result
            }
        } catch let error as EhError where error == .galleryRemoved {
            isGalleryRemoved = true
            LogManager.shared.log("Detail", "gid=\(gallery.gid) gallery removed")
        } catch {
            let dt = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            LogManager.shared.log("Perf", "loadDetail: \(dt)ms FAILED \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func openNyahentai() {
        let query = NhentaiClient.buildSearchQuery(from: gallery.title)
        guard !query.isEmpty else { return }
        #if canImport(UIKit)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://nyahentai.one/?s=\(encoded)") {
            UIApplication.shared.open(url)
        }
        #endif
    }

    private func openHitomi() {
        let query = NhentaiClient.buildSearchQuery(from: gallery.title)
        guard !query.isEmpty else { return }
        #if canImport(UIKit)
        // hitomi.laは window.location.search をdecodeURIComponentして検索する
        // URL形式: https://hitomi.la/search.html?クエリ（s=なし、?直後にクエリ）
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://hitomi.la/search.html?\(encoded)") {
            UIApplication.shared.open(url)
        }
        #endif
    }

    private func searchNhentai() {
        let query = NhentaiClient.buildSearchQuery(from: gallery.title)
        guard !query.isEmpty else { return }
        isSearchingNh = true
        LogManager.shared.log("nhentai", "searching: \(query)")

        Task {
            do {
                let result = try await NhentaiClient.search(query: query)
                nhSearchResults = Array(result.result.prefix(5))
                LogManager.shared.log("nhentai", "found \(result.result.count) results, showing \(nhSearchResults.count)")
            } catch {
                LogManager.shared.log("nhentai", "search failed: \(error.localizedDescription)")
            }
            isSearchingNh = false
        }
    }

    /// サムネイル情報を逐次取得（1ページ目即表示、残りバックグラウンド）
    /// エクストリームモード: フル画像URLを解決してディスクキャッシュに先読み
    private func prefetchFullImages() {
        guard ExtremeMode.shared.isEnabled, let detail else { return }
        let gallery = detail.gallery
        let galleryHost = host
        Task.detached(priority: .utility) {
            LogManager.shared.log("Download", "extreme prefetch: starting for gid=\(gallery.gid)")
            // URLキャッシュからページURLを取得
            var pageURLs: [URL] = []
            var page = 0
            while true {
                do {
                    let urls = try await EhClient.shared.fetchImagePageURLs(host: galleryHost, gallery: gallery, page: page)
                    if urls.isEmpty { break }
                    pageURLs.append(contentsOf: urls)
                    page += 1
                    if pageURLs.count >= gallery.pageCount || page > 200 { break }
                } catch { break }
            }
            // 各ページの画像URLを解決してダウンロード
            for (i, pageURL) in pageURLs.enumerated() {
                do {
                    let imageURL = try await EhClient.shared.fetchImageURL(pageURL: pageURL)
                    if ImageCache.shared.image(for: imageURL) == nil {
                        let data = try await EhClient.shared.fetchImageData(url: imageURL, host: galleryHost)
                        if let img = PlatformImage(data: data) {
                            ImageCache.shared.set(img, for: imageURL)
                        }
                    }
                    if i % 5 == 0 {
                        LogManager.shared.log("Download", "extreme prefetch: \(i+1)/\(pageURLs.count)")
                    }
                } catch { continue }
            }
            LogManager.shared.log("Download", "extreme prefetch: done \(pageURLs.count) pages")
        }
    }

    private func loadThumbnails() async {
        guard let detail, thumbnails.isEmpty else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        // エクストリームモード: フル画像先読み開始
        prefetchFullImages()
        let pageCount = detail.gallery.pageCount

        // ページ0を先に取得（即時表示に必要）
        var allInfos: [ThumbnailInfo] = []
        do {
            let tp = CFAbsoluteTimeGetCurrent()
            let infos = try await EhClient.shared.fetchThumbnailInfos(
                host: host, gallery: detail.gallery, page: 0
            )
            LogManager.shared.log("Perf", "thumbPage 0: \(Int((CFAbsoluteTimeGetCurrent() - tp) * 1000))ms \(infos.count) infos")
            if !infos.isEmpty {
                let reindexed = infos.enumerated().map { (i, info) in
                    ThumbnailInfo(
                        index: i,
                        spriteURL: info.spriteURL,
                        offsetX: info.offsetX,
                        width: info.width,
                        height: info.height
                    )
                }
                allInfos.append(contentsOf: reindexed)
                thumbnails = allInfos
                let batch = reindexed
                Task { await preloadSprites(for: batch) }
            }
        } catch {
            // ページ0取得失敗時は終了
            return
        }

        // 残ページが存在しない場合はここで終了
        guard allInfos.count < pageCount, allInfos.count > 0 else { return }

        // 残りのページ数を算出（ページ0の件数から推定）
        let infosPerPage = allInfos.count
        let estimatedPages = min(51, (pageCount + infosPerPage - 1) / infosPerPage)
        guard estimatedPages > 1 else { return }

        // 残りページ（1〜）を並列フェッチ
        let capturedGallery = detail.gallery
        let capturedHost = host
        let capturedPageCount = pageCount
        var pageResults: [(page: Int, infos: [ThumbnailInfo])] = []

        await withTaskGroup(of: (Int, [ThumbnailInfo])?.self) { group in
            for page in 1..<estimatedPages {
                // ノーマルモード時は500msディレイをページ間に挿入
                if !ExtremeMode.shared.isEnabled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                group.addTask {
                    let tp = CFAbsoluteTimeGetCurrent()
                    do {
                        let infos = try await EhClient.shared.fetchThumbnailInfos(
                            host: capturedHost, gallery: capturedGallery, page: page
                        )
                        LogManager.shared.log("Perf", "thumbPage \(page): \(Int((CFAbsoluteTimeGetCurrent() - tp) * 1000))ms \(infos.count) infos")
                        return infos.isEmpty ? nil : (page, infos)
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                guard let (page, infos) = result else { continue }
                pageResults.append((page: page, infos: infos))
            }
        }

        // ページ順にソートしてallInfosに追加・表示更新
        pageResults.sort { $0.page < $1.page }
        for (_, infos) in pageResults {
            guard allInfos.count < capturedPageCount else { break }
            let offset = allInfos.count
            let reindexed = infos.enumerated().map { (i, info) in
                ThumbnailInfo(
                    index: offset + i,
                    spriteURL: info.spriteURL,
                    offsetX: info.offsetX,
                    width: info.width,
                    height: info.height
                )
            }
            allInfos.append(contentsOf: reindexed)
            let batch = reindexed
            Task { await preloadSprites(for: batch) }
        }
        thumbnails = allInfos
        LogManager.shared.log("Perf", "loadThumbnails total: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms \(allInfos.count) infos")
    }

    /// スプライトシート画像を並列ダウンロード（画像サーバーへのリクエストはディレイ不要）
    private func preloadSprites(for infos: [ThumbnailInfo]) async {
        var seen = Set<URL>()
        var urls: [URL] = []
        for info in infos {
            if seen.insert(info.spriteURL).inserted {
                urls.append(info.spriteURL)
            }
        }

        // スプライトDL並列数: DL中は1、通常2（GPU/ネットワーク競合防止）
        let maxConcurrent = DownloadManager.shared.activeDownloadCount > 0 ? 1 : 2
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for url in urls {
                if SpriteCache.shared.sprite(for: url) != nil { continue }

                if running >= maxConcurrent {
                    await group.next()
                    running -= 1
                }
                running += 1
                group.addTask {
                    do {
                        let data = try await EhClient.shared.fetchImageData(url: url, host: self.host)
                        if let image = PlatformImage(data: data) {
                            await MainActor.run {
                                SpriteCache.shared.setSprite(image, for: url)
                            }
                        }
                    } catch {
                        print("[Thumb] preload sprite failed: \(url)")
                    }
                }
            }
        }

        // ダウンロード済みスプライトから切り出し
        for info in infos {
            await loadCroppedThumb(index: info.index)
        }
    }

    /// スプライトシートから1枚分を切り出す（バックグラウンドで実行）
    private func loadCroppedThumb(index: Int) async {
        guard index < thumbnails.count else { return }
        if croppedThumbs[index] != nil { return }

        let info = thumbnails[index]
        let cache = SpriteCache.shared
        let croppedKey = cache.croppedKey(url: info.spriteURL, offsetX: info.offsetX)

        if let cached = cache.croppedImage(key: croppedKey) {
            croppedThumbs[index] = cached
            return
        }

        // スプライトシートをダウンロード（キャッシュ済みならスキップ）
        var sprite = cache.sprite(for: info.spriteURL)
        if sprite == nil {
            do {
                let data = try await EhClient.shared.fetchImageData(url: info.spriteURL, host: host)
                if let downloaded = PlatformImage(data: data) {
                    cache.setSprite(downloaded, for: info.spriteURL)
                    sprite = downloaded
                }
            } catch {
                return
            }
        }

        guard let sprite else { return }

        let x = abs(Int(info.offsetX))
        let w = Int(info.width)
        let h = Int(info.height)
        let clampedX = min(x, sprite.pixelWidth - 1)
        let clampedW = min(w, sprite.pixelWidth - clampedX)
        let clampedH = min(h, sprite.pixelHeight)
        let cropRect = CGRect(x: clampedX, y: 0, width: clampedW, height: clampedH)

        // バックグラウンドで切り出し+リサイズ
        let result: PlatformImage? = await Task.detached(priority: .utility) {
            guard let cropped = sprite.croppedImage(rect: cropRect) else { return nil }
            // 表示サイズ（3列グリッドで約120pt = @3xで360px）に縮小
            let maxPixel: CGFloat = 360
            let scale = min(maxPixel / CGFloat(clampedW), maxPixel / CGFloat(clampedH), 1.0)
            if scale < 1.0 {
                let newW = Int(CGFloat(clampedW) * scale)
                let newH = Int(CGFloat(clampedH) * scale)
                #if canImport(UIKit)
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: newW, height: newH))
                return renderer.image { _ in
                    cropped.draw(in: CGRect(x: 0, y: 0, width: newW, height: newH))
                }
                #else
                return cropped
                #endif
            }
            return cropped
        }.value

        if let result {
            cache.setCropped(result, key: croppedKey)
            croppedThumbs[index] = result
        }
    }

    private func toggleFavorite(_ detail: GalleryDetail) async {
        let action = detail.isFavorited ? "remove" : "add"
        LogManager.shared.log("Favorite", "\(action) gid=\(gallery.gid) token=\(gallery.token)")
        do {
            if detail.isFavorited {
                try await EhClient.shared.removeFavorite(host: host, gid: gallery.gid, token: gallery.token)
                var updated = self.detail
                updated?.isFavorited = false
                self.detail = updated
                FavoritesCache.shared.removeFromCache(gid: gallery.gid)
                LogManager.shared.log("Favorite", "removed successfully")
            } else {
                try await EhClient.shared.addFavorite(host: host, gid: gallery.gid, token: gallery.token)
                var updated = self.detail
                updated?.isFavorited = true
                self.detail = updated
                FavoritesCache.shared.addToCache(gallery)
                LogManager.shared.log("Favorite", "added successfully")
            }
        } catch {
            LogManager.shared.log("Favorite", "\(action) FAILED: \(error)")
        }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    nonisolated func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    nonisolated func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    nonisolated private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - URL Identifiable (CORTEX PROTOCOL)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - In-App Browser (CORTEX PROTOCOL)

#if canImport(UIKit)
struct InAppBrowserView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InAppWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.host ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Image(systemName: "safari")
                        }
                    }
                }
        }
    }
}

struct InAppWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#endif
