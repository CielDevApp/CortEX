import SwiftUI
import TipKit

// C (2026-06-11): GalleryListView.swift から nhentai 一覧コンポーネントを退去 (純粋移動)。
// eh 側の型・LiquidGlassWindow を一切参照しない自己完結クラスタ。

// MARK: - nhentaiスクロールリスト

struct NhentaiScrollList: View {
    @ObservedObject var viewModel: NhentaiListViewModel
    @Binding var navPath: NavigationPath
    @State private var previewGallery: NhentaiClient.NhGallery?
    @State private var previewReaderRequest: NhentaiPreviewReaderRequest?
    /// E-H 側 GalleryScrollList と同方式 (v02a-f13): 検索/更新でデータ総入れ替えした時に
    /// 前のスクロール位置が残る問題対策。scrollResetToken 変化で先頭 id へ固定する。
    @State private var scrollPosition: Int?
    // 起動時スキマ対策 (E-H 側 GalleryScrollList と同方式・2026-06-21): 初回 reset は
    // 既に先頭表示なのでスキップし、programmatic アンカー跳躍 (スキマ→張り付き) を防ぐ。
    @State private var didInitialReset = false
    var onScrollDown: (() -> Void)?
    var onScrollUp: (() -> Void)?
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @AppStorage(UDKey.galleryListLayout) private var galleryListLayout: String = "grid"

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
                let totalSlots = Array(0..<(viewModel.galleries.count + 80))
                ForEach(totalSlots, id: \.self) { index in
                    if index < viewModel.galleries.count {
                        let nh = viewModel.galleries[index]
                        NhentaiGridCellView(gallery: nh)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                navPath = NavigationPath()
                                DispatchQueue.main.async { navPath.append(nh) }  // 同作品再タップ対策(別フレーム)
                            }
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.4, maximumDistance: 15)
                                    .onEnded { _ in
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        previewGallery = nh
                                    }
                            )
                            .onAppear {
                                if index >= viewModel.galleries.count - 4 && viewModel.hasMore && !viewModel.isLoading {
                                    Task { await viewModel.loadNextPage() }
                                }
                            }
                            .id(nh.id)
                    } else {
                        // ダミーは実カード (カバー 2:3 + 情報ストリップ) の高さに近い比率で確保
                        RoundedRectangle(cornerRadius: CardDesign.cardCorner, style: .continuous)
                            .fill(Color.gray.opacity(0.18))
                            .aspectRatio(0.56, contentMode: .fit)
                            .task { await viewModel.loadNextPage() }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            if viewModel.galleries.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("ギャラリーがありません", systemImage: "photo.on.rectangle.angled")
                }
                .padding(.top, 100)
            }
        }
        .background(CardDesign.listBackground)
        .onScrollGeometryChange(for: CGFloat.self) { geo in geo.contentOffset.y } action: { oldVal, newVal in
            let delta = newVal - oldVal
            if delta > 15 { onScrollDown?() } else if delta < -15 { onScrollUp?() }
        }
        // Mac Catalyst は従来挙動を変えない (憲法: Mac は触らない)。iPhone/iPad のみ。
        #if !targetEnvironment(macCatalyst)
        .scrollPosition(id: $scrollPosition, anchor: .top)
        .onChange(of: viewModel.scrollResetToken) {
            guard didInitialReset else { didInitialReset = true; return }
            scrollPosition = viewModel.galleries.first?.id
        }
        #endif
        .refreshable { await viewModel.refresh() }
        .overlay {
            if let nh = previewGallery {
                NhentaiPreviewOverlay(
                    gallery: nh,
                    onDismiss: { previewGallery = nil },
                    onTapPage: { loadedGallery, page in
                        previewReaderRequest = NhentaiPreviewReaderRequest(gallery: loadedGallery, page: page)
                    }
                )
                .transition(.opacity)
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $previewReaderRequest) { req in
            NhentaiReaderView(gallery: req.gallery, initialPage: req.page)
                .onAppear {
                    HistoryManager.shared.recordNhentai(gallery: req.gallery, page: req.page)
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
                ForEach(viewModel.galleries) { nh in
                    // UI 刷新 (2026-07-03): 行をカード化 (E-H 側と同型)
                    CardDesign.cardChrome(NhentaiCardView(gallery: nh))
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navPath = NavigationPath()
                            DispatchQueue.main.async { navPath.append(nh) }  // 同作品再タップ対策(別フレーム)
                        }
                        .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 15) {
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                            previewGallery = nh
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

                if viewModel.galleries.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView {
                        Label("ギャラリーがありません", systemImage: "photo.on.rectangle.angled")
                    }
                    .padding(.top, 100)
                }
            }
        }
        .background(CardDesign.listBackground)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { oldVal, newVal in
            let delta = newVal - oldVal
            if delta > 15 { onScrollDown?() }
            else if delta < -15 { onScrollUp?() }
        }
        // Mac Catalyst は従来挙動を変えない (憲法: Mac は触らない)。iPhone/iPad のみ。
        #if !targetEnvironment(macCatalyst)
        .scrollPosition(id: $scrollPosition, anchor: .top)
        .onChange(of: viewModel.scrollResetToken) {
            guard didInitialReset else { didInitialReset = true; return }
            scrollPosition = viewModel.galleries.first?.id
        }
        #endif
        .refreshable { await viewModel.refresh() }
        .overlay {
            if let nh = previewGallery {
                NhentaiPreviewOverlay(
                    gallery: nh,
                    onDismiss: { previewGallery = nil },
                    onTapPage: { loadedGallery, page in
                        previewReaderRequest = NhentaiPreviewReaderRequest(gallery: loadedGallery, page: page)
                    }
                )
                .transition(.opacity)
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $previewReaderRequest) { req in
            NhentaiReaderView(gallery: req.gallery, initialPage: req.page)
                .onAppear {
                    HistoryManager.shared.recordNhentai(gallery: req.gallery, page: req.page)
                    previewGallery = nil
                }
        }
        #endif
    }
}

/// nhentaiプレビューから直接リーダー起動用
struct NhentaiPreviewReaderRequest: Identifiable {
    let id = UUID()
    let gallery: NhentaiClient.NhGallery
    let page: Int
}

/// nhentai長押しプレビュー
struct NhentaiPreviewOverlay: View {
    let initialGallery: NhentaiClient.NhGallery
    let onDismiss: () -> Void
    /// loaded gallery (pages入り)とpage indexを返す
    let onTapPage: (NhentaiClient.NhGallery, Int) -> Void

    init(gallery: NhentaiClient.NhGallery, onDismiss: @escaping () -> Void, onTapPage: @escaping (NhentaiClient.NhGallery, Int) -> Void) {
        self.initialGallery = gallery
        self.onDismiss = onDismiss
        self.onTapPage = onTapPage
    }

    @State private var coverImage: PlatformImage?
    @State private var loadedGallery: NhentaiClient.NhGallery?
    @State private var isLoadingDetail = false

    private var gallery: NhentaiClient.NhGallery { loadedGallery ?? initialGallery }
    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 6)]

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack {
                    Text(gallery.displayTitle)
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

                ScrollView {
                    let pagesReady = (gallery.images?.pages.isEmpty == false)
                    if !pagesReady {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("ページ情報取得中…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 40)
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(0..<gallery.num_pages, id: \.self) { index in
                                NhThumbCell(
                                    gallery: gallery,
                                    index: index,
                                    coverImage: coverImage
                                ) {
                                    onTapPage(gallery, index)
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
            await ensureDetailLoaded()
        }
    }

    private func ensureDetailLoaded() async {
        if (initialGallery.images?.pages.isEmpty == false) { return }
        guard !isLoadingDetail else { return }
        isLoadingDetail = true
        LogManager.shared.log("nhentai", "preview: loading detail id=\(initialGallery.id)")
        do {
            let full = try await NhentaiClient.fetchGallery(id: initialGallery.id)
            loadedGallery = full
            LogManager.shared.log("nhentai", "preview: detail loaded pages=\(full.num_pages)")
        } catch {
            LogManager.shared.log("nhentai", "preview: detail failed: \(error.localizedDescription)")
        }
        isLoadingDetail = false
    }
}

// MARK: - nhentaiカードView

struct NhentaiCardView: View {
    let gallery: NhentaiClient.NhGallery
    @State private var coverImage: PlatformImage?
    @ObservedObject private var readHistory = ReadHistoryStore.shared
    @AppStorage(UDKey.grayOutReadGalleries) private var grayOutReadGalleries = true

    /// 既読グレー表示 (トグル OFF 中は抑制のみ、記録は残る)。判定は O(1)。
    private var isReadDimmed: Bool {
        grayOutReadGalleries && readHistory.isRead(site: .nh, gid: gallery.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // カバー (UI 刷新 2026-07-03: continuous 角丸 + P バッジをカバー上へ)
            Group {
                if let img = coverImage {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 110)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 80, height: 110)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                        .onAppear { loadCover() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CardDesign.coverCorner, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if gallery.num_pages > 0 {
                    CoverPagesBadge(pages: gallery.num_pages)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(gallery.displayTitle)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundStyle(isReadDimmed ? Color.secondary : Color.primary)

                HStack(spacing: 6) {
                    TintedBadge(text: "NH", color: .orange)

                    if let tags = gallery.tags {
                        let langTags = tags.filter { $0.type == "language" }.map(\.name)
                        if !langTags.isEmpty {
                            Text(langTags.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)
            }
            .frame(height: 110)
            Spacer()
        }
    }

    private func loadCover() {
        // v2: thumbnailPathがあればそれを使う、なければimages.cover
        // thumbnailPath はネットワーク由来文字列なので percent-encode + URL 生成失敗時は
        // cover 経路へフォールバック (旧実装の強制 unwrap はクラッシュ要因)
        let url: URL
        if let thumbPath = gallery.thumbnailPath,
           let thumbURL = URL(string: "https://t.nhentai.net/" + (thumbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? thumbPath)) {
            url = thumbURL
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
        // thumbnailPath はネットワーク由来文字列なので percent-encode + URL 生成失敗時は
        // cover 経路へフォールバック (旧実装の強制 unwrap はクラッシュ要因)
        let url: URL
        if let thumbPath = gallery.thumbnailPath,
           let thumbURL = URL(string: "https://t.nhentai.net/" + (thumbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? thumbPath)) {
            url = thumbURL
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
