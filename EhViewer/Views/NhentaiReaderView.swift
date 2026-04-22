import SwiftUI
import TipKit
import CoreImage

/// nhentaiギャラリーリーダー
struct NhentaiReaderView: View {
    let gallery: NhentaiClient.NhGallery
    var initialPage: Int = 0

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var showControls = true
    @State private var sliderValue: Double
    @State private var isSliding = false
    @State private var showPageOverlay = false
    @State private var sliderJumpTarget: Int?
    @State private var images: [Int: PlatformImage] = [:]       // 表示用（フィルタ適用済み）
    @State private var rawImages: [Int: PlatformImage] = [:]   // フィルタ再適用用の元画像
    @State private var pageDataCache: [Int: Data] = [:]
    @State private var loadingPages: Set<Int> = []
    @State private var horizontalPage: Int
    @State private var isFavorited: Bool
    @State private var showClosePrompt = false
    @State private var showSavePrompt = false
    @State private var zoomImage: PlatformImage?
    @State private var showFilterPanel = false
    @State private var showFavFailedAlert = false
    @State private var favFailedGalleryId: Int = 0
    @AppStorage("translationMode") private var translationMode = false
    @AppStorage("noFilterMode") private var noFilterMode = false
    @AppStorage("imageEnhanceFilter") private var imageEnhanceFilter = false
    @AppStorage("denoiseEnabled") private var denoiseEnabled = false
    @AppStorage("hdrEnhancement") private var hdrEnhancement = false
    @AppStorage("aiImageProcessing") private var aiImageProcessing = false
    /// 0=低画質(サムネのみ), 2=標準(サムネ→標準画質のプログレッシブ)
    @AppStorage("onlineQualityMode") private var onlineQualityMode = 2

    init(gallery: NhentaiClient.NhGallery, initialPage: Int = 0) {
        self.gallery = gallery
        self.initialPage = initialPage
        self._currentIndex = State(initialValue: initialPage)
        self._sliderValue = State(initialValue: Double(initialPage))
        self._horizontalPage = State(initialValue: initialPage)
        self._isFavorited = State(initialValue: NhentaiFavoritesCache.shared.contains(id: gallery.id))
    }
    @ObservedObject private var downloadManager = DownloadManager.shared
    @AppStorage("readerDirection") private var userReaderDirection = 0
    @AppStorage("readingOrder") private var readingOrder = 1
    /// 動画 WebP per-gallery モード解決結果。nil = 未解決
    @State private var resolvedDirection: Int? = nil
    @State private var showAnimationDialog = false
    /// ランタイム検知 dialog 発火済みフラグ
    @State private var animationDetectionHandled = false

    private var totalPages: Int { gallery.num_pages }
    /// 動画 WebP モード解決後の有効方向。未解決時は黒画面で待機
    private var effectiveDirection: Int { resolvedDirection ?? userReaderDirection }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if resolvedDirection != nil {
                if effectiveDirection == 0 {
                    verticalReader
                } else {
                    horizontalReader
                }
            }

            if showControls {
                controlsOverlay

                VStack(spacing: 8) {
                    TipView(ReaderControlsTip(), arrowEdge: .bottom)
                    if effectiveDirection == 1 {
                        TipView(ReaderSwipeDismissTip(), arrowEdge: .bottom)
                        TipView(HorizontalReaderTip(), arrowEdge: .bottom)
                    }
                    if effectiveDirection == 1 && readingOrder == 1 {
                        TipView(RTLSliderTip(), arrowEdge: .bottom)
                    }
                    if UIDevice.current.userInterfaceIdiom == .pad && effectiveDirection == 1 {
                        TipView(SpreadModeTip(), arrowEdge: .bottom)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 120)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }

            // ズームオーバーレイ
            if let img = zoomImage {
                ZoomableImageOverlay(image: img) {
                    withAnimation(.easeOut(duration: 0.2)) { zoomImage = nil }
                }
            }

            // 画質設定パネル
            if showFilterPanel {
                nhFilterPanel
                    .transition(.move(edge: .trailing))
            }

            if showPageOverlay {
                Text("\(Int(sliderValue) + 1)")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 140, height: 140)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .transition(.opacity)
            }
        }
        #if os(iOS)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .statusBarHidden(!showControls)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        // DL中の閉じる確認
        .alert("ダウンロード中", isPresented: $showClosePrompt) {
            Button("バックグラウンドで続行") {
                dismiss()
            }
            Button("中止して削除", role: .destructive) {
                let gid = -gallery.id
                downloadManager.cancelDownload(gid: gid)
                downloadManager.deleteDownload(gid: gid)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            let gid = -gallery.id
            let progress = downloadManager.activeDownloads[gid]
            Text("ダウンロード進行中（\(progress?.current ?? 0)/\(progress?.total ?? gallery.num_pages)）。どうしますか？")
        }
        // 閉じる時の保存確認（E-Hentaiと同じ方式）
        .alert("保存済みに登録", isPresented: $showSavePrompt) {
            Button("残りもダウンロード") {
                saveReadPagesAndDownload()
                dismiss()
            }
            Button("このまま閉じる") {
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(pageDataCache.count)/\(totalPages) ページ閲覧済み。残りをダウンロードしますか？")
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
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ローカルには追加済みです。Safari で手動完了するか、設定から nhentai に再認証してください。")
        }
        .task {
            // リーダー表示開始 → DL側に減速ヒント
            DownloadManager.setReaderActive(gid: -gallery.id, active: true)
            await resolveReaderMode()
            // 純オンライン保険: 最初の数ページの実バイト判定で dialog 発火
            Task { await monitorAnimationDetection() }
            // 初期表示: 現在ページ優先 + 前後5ページ先読み（爆速ページめくり用）
            loadPage(initialPage)
            for offset in 1...5 {
                loadPage(initialPage + offset)
                loadPage(initialPage - offset)
            }
        }
        .animationModeDialog(isPresented: $showAnimationDialog) { mode, dontAskAgain in
            if dontAskAgain {
                downloadManager.setReaderModeOverride(gid: -gallery.id, mode: mode)
            }
            resolvedDirection = (mode == .horizontal) ? 1 : 0
        }
        .onDisappear {
            DownloadManager.setReaderActive(gid: -gallery.id, active: false)
        }
        .onChange(of: noFilterMode) { _, _ in reapplyFilters() }
        .onChange(of: imageEnhanceFilter) { _, _ in reapplyFilters() }
        .onChange(of: denoiseEnabled) { _, _ in reapplyFilters() }
        .onChange(of: hdrEnhancement) { _, _ in reapplyFilters() }
        .onChange(of: aiImageProcessing) { _, _ in reapplyFilters() }
    }

    /// オンライン読み中のランタイム検知。pageDataCache を polling し、
    /// 最初の数ページのいずれかが動画 WebP なら dialog 発火。
    @MainActor
    private func monitorAnimationDetection() async {
        guard userReaderDirection == 1 else { return }
        let nhGid = -gallery.id
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if animationDetectionHandled { return }
            if showAnimationDialog { return }
            if let m = downloadManager.downloads[nhGid], m.readerModeOverride != nil { return }
            for page in 0..<min(5, totalPages) {
                if let data = pageDataCache[page], WebPAnimationDetector.isAnimatedWebP(data: data) {
                    animationDetectionHandled = true
                    LogManager.shared.log("Anim", "Online runtime detect (nh): page=\(page) gid=\(nhGid) → SHOW DIALOG")
                    showAnimationDialog = true
                    return
                }
            }
        }
    }

    // MARK: - 動画 WebP モード解決

    @MainActor
    private func resolveReaderMode() async {
        guard userReaderDirection == 1 else {
            resolvedDirection = userReaderDirection
            return
        }
        let nhGid = -gallery.id
        // 1) DL 済み meta があれば実走査結果を優先
        if downloadManager.downloads[nhGid] != nil {
            await downloadManager.ensureAnimatedWebpScanned(gid: nhGid)
            if let m = downloadManager.downloads[nhGid] {
                if let ov = m.readerModeOverride {
                    resolvedDirection = (ov == .horizontal) ? 1 : 0
                    return
                }
                if m.hasAnimatedWebp == true {
                    showAnimationDialog = true
                    return
                }
                if m.hasAnimatedWebp == false {
                    resolvedDirection = 1
                    return
                }
            }
        }
        // 2) DL 前のオンライン読みは title + tags heuristic
        let title = gallery.displayTitle
        let titleHit = title.contains("Animated") || title.contains("GIF") || title.contains("gif") || title.contains("🎥")
        let tagHit = (gallery.tags ?? []).contains { tag in
            let n = tag.name.lowercased()
            return n == "animated" || n.contains("gif")
        }
        if titleHit || tagHit {
            showAnimationDialog = true
        } else {
            resolvedDirection = 1
        }
    }

    // MARK: - 画質設定パネル

    private var nhIsLowQualityMode: Bool { onlineQualityMode <= 1 }

    private var nhFilterPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3").font(.subheadline)
                Text("画質設定").font(.subheadline.bold())
                Spacer()
                if nhIsLowQualityMode {
                    Text("低画質モード")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.3))
                        .clipShape(Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.white)

            Toggle("無補正モード", isOn: $noFilterMode)
                .font(.subheadline).tint(.green)

            if !noFilterMode {
                Toggle("画像補正フィルタ", isOn: $imageEnhanceFilter)
                    .font(.subheadline).tint(.blue)

                Toggle("ノイズ除去", isOn: $denoiseEnabled)
                    .font(.subheadline).tint(.blue)

                HStack {
                    Toggle("HDR風補正（カラー作品推奨）", isOn: $hdrEnhancement)
                        .font(.subheadline).tint(.blue)
                    if imageEnhanceFilter {
                        Text("(HDR統合済み)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Toggle("AI超解像", isOn: $aiImageProcessing)
                    .font(.subheadline).tint(.blue)
            }

            Divider().overlay(.gray.opacity(0.5))

            if nhIsLowQualityMode {
                HStack {
                    Text("現在: 低画質モード")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }

                Button {
                    onlineQualityMode = 2
                    nhReloadAll()
                } label: {
                    VStack(spacing: 2) {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("標準画質で読み込み直す")
                        }
                        Text("通信量増・サーバーから高解像度画像を取得")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Text("現在: 標準画質")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFilterPanel = false
                    }
                    onlineQualityMode = 0
                    nhReloadAll()
                } label: {
                    VStack(spacing: 2) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("低画質モードに切り替え")
                        }
                        Text("通信量削減・サムネベースで高速表示")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.blue.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(.gray.opacity(0.5))

            Toggle("翻訳モード", isOn: $translationMode)
                .font(.subheadline).tint(.blue)
                .onChange(of: translationMode) {
                    if !translationMode {
                        TranslationService.shared.clearCache()
                    }
                }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 60)
    }

    /// 画質モード切替時の全リロード
    private func nhReloadAll() {
        rawImages.removeAll()
        images.removeAll()
        pageDataCache.removeAll()
        loadingPages.removeAll()
        // 現在表示中ページ周辺±5を即リロード
        let center = currentIndex
        loadPage(center)
        for offset in 1...5 {
            loadPage(center + offset)
            loadPage(center - offset)
        }
    }

    @AppStorage("autoSaveOnRead") private var autoSaveOnRead = false

    private func handleClose() {
        let gid = -gallery.id
        if downloadManager.isDownloading(gid: gid) {
            showClosePrompt = true
        } else if downloadManager.isDownloaded(gid: gid) {
            dismiss()
        } else if autoSaveOnRead && !pageDataCache.isEmpty {
            showSavePrompt = true
        } else {
            dismiss()
        }
    }

    /// 閲覧済みページを保存してから残りをDL開始
    private func saveReadPagesAndDownload() {
        let gid = -gallery.id  // nhentaiはgid負数
        let dir = DownloadManager.shared.galleryDirectory(gid: gid)
        DownloadManager.shared.ensureDirectory(dir)

        // 閲覧済みページデータをディスクに書き込み
        var savedPages: [Int] = []
        for (index, data) in pageDataCache.sorted(by: { $0.key < $1.key }) {
            let filePath = DownloadManager.shared.imageFilePath(gid: gid, page: index)
            if !FileManager.default.fileExists(atPath: filePath.path) {
                try? data.write(to: filePath)
            }
            // カバー
            if index == 0 {
                let coverPath = DownloadManager.shared.coverFilePath(gid: gid)
                if !FileManager.default.fileExists(atPath: coverPath.path) {
                    try? data.write(to: coverPath)
                }
            }
            savedPages.append(index)
        }

        // メタデータ作成（保存済みページ情報付き）
        if DownloadManager.shared.downloads[gid] == nil {
            var meta = DownloadedGallery(
                gid: gid, token: "nh_\(gallery.media_id)", title: gallery.displayTitle,
                coverFileName: "cover.jpg", pageCount: totalPages,
                downloadDate: Date(), isComplete: false, downloadedPages: savedPages,
                source: "nhentai"
            )
            meta.isComplete = savedPages.count >= totalPages
            DownloadManager.shared.saveMetadata(meta)
        }

        // 残りをDL（既に保存済みページはスキップされる）
        DownloadManager.shared.startNhentaiDownload(gallery: gallery)
    }

    // MARK: - 縦スクロール

    private var verticalReader: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<totalPages, id: \.self) { index in
                        pageCell(index: index)
                            .id(index)
                            .frame(maxWidth: .infinity)
                            .onAppear {
                                currentIndex = index
                                loadPage(index)
                                if !EcoMode.shared.isEnabled {
                                    // ±5ページ先読み（爆速ページめくり）
                                    for offset in 1...5 {
                                        loadPage(index + offset)
                                        loadPage(index - offset)
                                    }
                                }
                            }
                    }
                }
            }
            .onLongPressGesture(minimumDuration: 0.3) {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            }
            .onChange(of: currentIndex) { _, newIndex in
                if !isSliding { sliderValue = Double(newIndex) }
                HistoryManager.shared.updateLastPageNh(id: gallery.id, page: newIndex)
            }
            .onChange(of: Int(sliderValue)) {
                #if canImport(UIKit)
                if isSliding {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                #endif
            }
            .onChange(of: sliderJumpTarget) { _, target in
                if let target {
                    proxy.scrollTo(target, anchor: .top)
                    sliderJumpTarget = nil
                }
            }
            .onAppear {
                if initialPage > 0 {
                    proxy.scrollTo(initialPage, anchor: .top)
                }
            }
        }
    }

    // MARK: - 横ページめくり

    private var horizontalReader: some View {
        #if canImport(UIKit)
        PagedReaderView(
            totalPages: totalPages,
            currentPage: $horizontalPage,
            showControls: $showControls,
            readingOrder: readingOrder,
            imageForPage: { index in images[index] },
            onPageAppear: { index in
                currentIndex = index
                loadPage(index)
                if !EcoMode.shared.isEnabled {
                    // ±5ページ先読み（爆速ページめくり、見開きモード対応）
                    for offset in 1...5 {
                        loadPage(index + offset)
                        loadPage(index - offset)
                    }
                }
            },
            onDismiss: { handleClose() },
            onZoomImage: { img in zoomImage = img }
        )
        .ignoresSafeArea()
        .onChange(of: horizontalPage) { _, newPage in
            currentIndex = newPage
            if !isSliding { sliderValue = Double(newPage) }
        }
        #else
        Text("横モード未対応")
        #endif
    }

    // MARK: - ページセル

    @ViewBuilder
    private func pageCell(index: Int) -> some View {
        if let image = images[index] {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("\(index + 1) / \(totalPages)")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 300)
        }
    }

    // MARK: - ページロード

    /// データをGPUデコード
    private func decodeImageData(_ data: Data) async -> PlatformImage? {
        return await withCheckedContinuation { (cont: CheckedContinuation<PlatformImage?, Never>) in
            SpriteCache.imageQueue.async {
                if let ciImage = CIImage(data: data),
                   let cgImage = SpriteCache.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                    cont.resume(returning: PlatformImage(cgImage: cgImage))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadPage(_ index: Int) {
        guard index >= 0, index < totalPages else { return }
        // images既読みなら再ロード不要。ただし低画質モード時はrawImagesだけ埋まって
        // いるケースもあるので !images[index] でも重複loadingだけは弾く
        guard !loadingPages.contains(index) else { return }
        if images[index] != nil && rawImages[index] != nil { return }
        loadingPages.insert(index)

        guard let pages = gallery.images?.pages, index < pages.count else { return }
        let page = pages[index]
        let isLowQuality = onlineQualityMode <= 1

        Task {
            LogManager.shared.log("nhLoad", "page \(index + 1) start mode=\(onlineQualityMode)")

            // サムネ先行ロード
            // 低画質モード: サムネに対してフィルタパイプライン実行（CoreML超解像含む）
            // 標準画質モード: サムネを即placeholder表示（フィルタ適用しない）、すぐ裏で標準画質fetch
            if let thumbData = try? await NhentaiClient.fetchThumbImage(
                galleryId: gallery.id, mediaId: gallery.media_id, page: index + 1, ext: page.ext, thumbPath: page.thumbPath
            ), let thumb = await decodeImageData(thumbData) {
                LogManager.shared.log("nhLoad", "page \(index + 1) thumb loaded \(thumb.pixelWidth)x\(thumb.pixelHeight)")
                if isLowQuality {
                    // 低画質モード: thumb に対してフィルタパイプライン実行
                    rawImages[index] = thumb
                    applyFiltersAsync(index: index, raw: thumb)
                } else {
                    // 標準画質モード: placeholder表示のみ、rawImagesは上書きしない
                    if images[index] == nil {
                        images[index] = thumb
                    }
                }
            } else {
                LogManager.shared.log("nhLoad", "page \(index + 1) thumb failed")
            }

            // 低画質モードならここで終了（標準画質取得しない）
            if isLowQuality {
                loadingPages.remove(index)
                return
            }

            // 標準画質取得: DL済みローカルファイルを先にチェック（DL中の帯域競合回避）
            let nhGid = -gallery.id
            let localPath = DownloadManager.shared.imageFilePath(gid: nhGid, page: index + 1)
            if FileManager.default.fileExists(atPath: localPath.path),
               let data = try? Data(contentsOf: localPath),
               !data.isEmpty {
                pageDataCache[index] = data
                if let img = await decodeImageData(data) {
                    LogManager.shared.log("nhLoad", "page \(index + 1) full from local DL \(img.pixelWidth)x\(img.pixelHeight)")
                    rawImages[index] = img
                    applyFiltersAsync(index: index, raw: img)
                }
                loadingPages.remove(index)
                return
            }

            // 標準画質取得（ネットワーク）
            do {
                let data = try await NhentaiClient.fetchPageImage(
                    galleryId: gallery.id, mediaId: gallery.media_id, page: index + 1, ext: page.ext, path: page.path
                )
                pageDataCache[index] = data

                if let img = await decodeImageData(data) {
                    LogManager.shared.log("nhLoad", "page \(index + 1) full loaded \(img.pixelWidth)x\(img.pixelHeight)")
                    rawImages[index] = img
                    applyFiltersAsync(index: index, raw: img)
                }
            } catch {
                LogManager.shared.log("nhentai", "page \(index + 1) failed: \(error.localizedDescription)")
            }
            loadingPages.remove(index)
        }
    }

    /// 画像フィルタ適用（E-Hentaiと同じ処理を使用）
    /// 同期版: CoreML以外のフィルタのみ
    private func applyFilters(_ image: PlatformImage) -> PlatformImage {
        guard !noFilterMode, !EcoMode.shared.isEnabled else { return image }

        var result = image

        if denoiseEnabled {
            if let denoised = ReaderViewModel.applyDenoiseStatic(result) {
                result = denoised
            }
        }

        if imageEnhanceFilter {
            if let enhanced = LanczosUpscaler.shared.enhanceFilter(result) {
                result = enhanced
            }
        } else if hdrEnhancement {
            if let hdr = HDREnhancer().enhance(result) {
                result = hdr
            }
        }

        return result
    }

    /// 非同期フィルタ適用（EHと同じパイプライン）
    /// デフォルトで Vision Framework による Neural Engine 人物セグメンテーション補正を適用。
    /// noFilterMode=true で無効化。
    private func applyFiltersAsync(index: Int, raw: PlatformImage) {
        // noFilter/EcoModeなら即座にraw表示
        if noFilterMode || EcoMode.shared.isEnabled {
            images[index] = raw
            return
        }
        // 即表示(フィルタ完了まで仮表示)
        if images[index] == nil {
            images[index] = raw
        }
        let capturedIndex = index
        let capturedRaw = raw
        let capturedUseAI = aiImageProcessing && CoreMLImageProcessor.shared.modelAvailable
        let capturedDenoise = denoiseEnabled
        let capturedEnhance = imageEnhanceFilter
        let capturedHDR = hdrEnhancement

        Task.detached(priority: .userInitiated) {
            var result = capturedRaw

            // CoreML 4x超解像
            if capturedUseAI {
                let upscaled = await CoreMLImageProcessor.shared.process(result)
                if let upscaled { result = upscaled }
            }

            // ノイズ除去
            if capturedDenoise {
                result = ReaderViewModel.applyDenoiseStatic(result) ?? result
            }

            // 画像補正フィルタ / HDR排他
            if capturedEnhance {
                result = LanczosUpscaler.shared.enhanceFilter(result) ?? result
            } else if capturedHDR {
                result = HDREnhancer().enhance(result) ?? result
            }

            // Neural Engine 人物セグメンテーション（デフォルト補正）
            #if canImport(UIKit)
            if let enhanced = LanczosUpscaler.shared.applyPersonSegmentation(result) {
                result = enhanced
            }
            #endif

            await MainActor.run {
                images[capturedIndex] = result
            }
        }
    }

    /// 設定変更時に全画像を再フィルタ（Main thread同期、確実にUI反映）
    private func reapplyFilters() {
        let snapshot = rawImages
        LogManager.shared.log("nhFilter", "reapplyFilters: count=\(snapshot.count) noFilter=\(noFilterMode) enhance=\(imageEnhanceFilter) denoise=\(denoiseEnabled) hdr=\(hdrEnhancement) ai=\(aiImageProcessing)")
        for (index, raw) in snapshot {
            applyFiltersAsync(index: index, raw: raw)
        }
    }

    /// 見開き対応ページラベル
    private var nhSpreadLabel: String {
        let page = isSliding ? Int(sliderValue) : currentIndex
        if effectiveDirection == 1 {
            return PagedReaderView.spreadPageLabel(
                currentPage: page,
                totalPages: totalPages,
                readingOrder: readingOrder,
                imageForPage: { images[$0] }
            )
        }
        return "\(page + 1) / \(totalPages)"
    }

    // MARK: - コントロール

    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button { handleClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(gallery.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                // お気に入りボタン
                // ファボ追加: ローカル即時 + 裏サーバー試行 → 失敗時 Safari
                // ファボ削除: CF 鉄壁 → ローカル即時削除 + Safari 誘導
                if NhentaiCookieManager.isLoggedIn() {
                    Button {
                        let gid = gallery.id
                        if isFavorited {
                            isFavorited = false
                            NhentaiFavoritesCache.shared.removeFromCache(id: gid)
                            #if canImport(UIKit)
                            if let url = URL(string: "https://nhentai.net/g/\(gid)/") {
                                UIApplication.shared.open(url)
                            }
                            #endif
                        } else {
                            isFavorited = true
                            NhentaiFavoritesCache.shared.addToCache(gallery)
                            Task {
                                let result = (try? await NhentaiClient.toggleFavorite(galleryId: gid)) ?? false
                                if !result {
                                    await MainActor.run {
                                        favFailedGalleryId = gid
                                        showFavFailedAlert = true
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: isFavorited ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(isFavorited ? .red : .white)
                    }
                    .buttonStyle(.plain)
                }

                // 翻訳ボタン
                Button {
                    if translationMode {
                        TranslationService.shared.clearCache()
                    }
                    translationMode.toggle()
                } label: {
                    Image(systemName: "character.book.closed")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(translationMode ? .blue : .white)
                }
                .buttonStyle(.plain)

                // 画質設定ボタン
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFilterPanel.toggle()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(showFilterPanel ? .yellow : .white)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.ultraThinMaterial.opacity(0.8))

            Spacer()

            VStack(spacing: 6) {
                if totalPages > 1 {
                    Slider(
                        value: $sliderValue,
                        in: 0...Double(max(totalPages - 1, 1)),
                        step: 1
                    ) { editing in
                        isSliding = editing
                        if editing {
                            withAnimation(.easeIn(duration: 0.15)) { showPageOverlay = true }
                        } else {
                            if effectiveDirection == 1 {
                                horizontalPage = Int(sliderValue)
                            } else {
                                sliderJumpTarget = Int(sliderValue)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation(.easeOut(duration: 0.2)) { showPageOverlay = false }
                            }
                        }
                    }
                    .tint(.white)
                    .padding(.horizontal)
                    .environment(\.layoutDirection, readingOrder == 1 && effectiveDirection == 1 ? .rightToLeft : .leftToRight)
                }

                HStack {
                    Text(nhSpreadLabel)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Spacer()
                    Text("nhentai")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
            .background(.ultraThinMaterial.opacity(0.8))
        }
    }
}
