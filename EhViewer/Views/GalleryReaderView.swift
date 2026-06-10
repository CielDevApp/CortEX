import SwiftUI
import Combine
import TipKit

struct GalleryReaderView: View {
    let gallery: Gallery
    let host: GalleryHost

    @StateObject private var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var showPageJump = false
    @State private var jumpPageText = ""
    @State private var dragOffset: CGFloat = 0
    @State private var zoomImage: PlatformImage?
    @State private var sliderValue: Double = 0
    @State private var isSliding = false
    @State private var showPageOverlay = false
    @State private var showFilterPanel = false
    @State private var showStandardConfirm = false
    @AppStorage("onlineQualityMode") private var onlineQualityMode = 2
    @AppStorage("imageEnhanceFilter") private var imageEnhanceFilter = false
    @AppStorage("hdrEnhancement") private var hdrEnhancement = false
    @AppStorage("aiImageProcessing") private var aiImageProcessing = false
    @AppStorage("denoiseEnabled") private var denoiseEnabled = false
    @AppStorage("noFilterMode") private var noFilterMode = false
    @AppStorage("translationMode") private var translationMode = false
    @AppStorage("translationLang") private var translationLang = "ja"
    @AppStorage("translationSourceLang") private var translationSourceLang = "auto"
    @AppStorage("readerDirection") private var userReaderDirection = 0 // 0:縦, 1:横
    @AppStorage("readingOrder") private var readingOrder = 1 // 0:左綴じ, 1:右綴じ
    @State private var horizontalPage: Int = 0
    /// 動画 WebP per-gallery モード解決結果。nil = 未解決（ダイアログ待ち）
    @State private var resolvedDirection: Int? = nil
    @State private var showAnimationDialog = false
    /// 一度ランタイム検知 dialog を出したら以降抑止（複数ページの動画で再度発火させない）
    @State private var animationDetectionHandled = false
    /// monitorAnimationDetection のハンドル。旧実装は `.task { Task { ... } }` の内側 Task に
    /// 外側 (.task) のキャンセルが伝播せず、閉鎖後も最大 30 秒 polling が viewModel を retain していた。
    @State private var animationMonitorTask: Task<Void, Never>?
    /// 縦リーダーの scrollTo リトライ Task (数百ページジャンプ吹き飛び対策)。
    /// 新ジャンプ要求/画面破棄時に必ず cancel して多重リトライを防ぐ。
    @State private var jumpRetryTask: Task<Void, Never>?
    // 2026-06-10: @ObservedObject を撤去。リーダーは downloadManager を関数内の単発参照
    // (resolve/override/cancel) でしか使わず body でのリアクティブ利用はゼロなのに、
    // BGDL 中はページ完了毎の @Published 更新でリーダー body 全体 (数百セルの LazyVStack
    // 含む) が毎秒数回再評価されていた = DL 中スクロールが重い構造的真因 (MainStall 実測)。
    private var downloadManager: DownloadManager { DownloadManager.shared }
    @State private var showAutoSavePrompt = false
    @State private var autoSaveInfo: (saved: Int, total: Int) = (0, 0)
    @AppStorage("autoSaveOnRead") private var autoSaveOnRead = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// リーダーからのお気に入りトグル (nh リーダーと UX 統一、2026-06-10)。
    /// 詳細ビューとリーダーの両方からトグルしても矛盾しないよう、
    /// 初期値は FavoritesCache 実体から読む (nh の NhentaiFavoritesCache.contains 初期化と同型)。
    @State private var isFavorited: Bool

    init(gallery: Gallery, host: GalleryHost, initialPage: Int = 0, thumbnails: [ThumbnailInfo] = []) {
        self.gallery = gallery
        self.host = host
        self._viewModel = StateObject(wrappedValue: ReaderViewModel(gallery: gallery, host: host, initialPage: initialPage, thumbnails: thumbnails))
        self._isFavorited = State(initialValue: FavoritesCache.shared.load().contains { $0.gid == gallery.gid })
    }

    /// 動画 WebP モード解決後の有効方向。未解決時は userReaderDirection (一瞬黒画面)
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

            // 翻訳マネージャー（非表示、画像処理のみ）
            TranslationManagerView(
                viewModel: viewModel,
                gid: gallery.gid,
                targetLang: translationLang,
                sourceLang: translationSourceLang,
                isActive: translationMode
            )

            if showControls && zoomImage == nil {
                controlsOverlay
            }

            // スライダー操作中のページ番号オーバーレイ
            // サムネプレビュー版は撤回 (田中指示 2026-06-10): オンラインビューワーは
            // スプライト未取得でプレビューが出ない。プレビューはライブラリ側だけの話。
            if showPageOverlay {
                Text("\(Int(sliderValue) + 1)")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 140, height: 140)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .transition(.opacity)
            }

            if showFilterPanel && zoomImage == nil {
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showFilterPanel = false
                        }
                    }

                VStack {
                    Spacer()
                    if EcoMode.shared.isEnabled {
                        ecoFilterPanel
                    } else {
                        onlineFilterPanel
                    }
                }
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let img = zoomImage {
                ZoomableImageOverlay(image: img) {
                    withAnimation(.easeOut(duration: 0.2)) { zoomImage = nil }
                }
            }

        }
        .offset(x: dragOffset)
        .opacity(dragOffset > 0 ? max(0, 1.0 - dragOffset / 400.0) : 1.0)
        .overlay(alignment: .leading) {
            // 横モード時は左エッジスワイプ無効（ページ送りと干渉防止）
            if zoomImage == nil && effectiveDirection == 0 {
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if value.translation.width > 0 {
                                    dragOffset = value.translation.width
                                }
                            }
                            .onEnded { value in
                                if value.translation.width > 120 {
                                    handleDismiss()
                                } else {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
            }
        }
        #if os(iOS)
        .persistentSystemOverlays(showControls && zoomImage == nil ? .automatic : .hidden)
        .statusBarHidden(!showControls || zoomImage != nil)
        .toolbar(showControls && zoomImage == nil ? .visible : .hidden, for: .tabBar)
        #endif
        .overlay(alignment: .bottom) {
            if showControls {
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
                    if autoSaveOnRead {
                        TipView(AutoSaveTip(), arrowEdge: .bottom)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 120)
            }
        }
        .task {
            // 再表示時 (onDisappear → 再 onAppear) に閉鎖フラグを解除。
            // これが無いと releaseAllForClose 後の再表示で全ロードが止まったままになる。
            viewModel.reopenForDisplay()

            // TipKit パラメータ更新
            RTLSliderTip.isRTLMode = (readingOrder == 1 && effectiveDirection == 1)
            AutoSaveTip.autoSaveEnabled = autoSaveOnRead

            await resolveReaderMode()
            // 純オンラインで heuristic 不発のときの保険: 最初の数ページの実バイト判定で dialog 発火。
            // loadImagePages を 30 秒ブロックしないよう別 Task だが、ハンドルを保持して
            // onDisappear で必ず cancel する (内側 Task には .task のキャンセルが伝播しないため)。
            animationMonitorTask?.cancel()
            animationMonitorTask = Task { await monitorAnimationDetection() }
            await viewModel.loadImagePages()
        }
        .animationModeDialog(isPresented: $showAnimationDialog) { mode, dontAskAgain in
            if dontAskAgain {
                downloadManager.setReaderModeOverride(gid: gallery.gid, mode: mode)
            }
            resolvedDirection = (mode == .horizontal) ? 1 : 0
        }
        .onDisappear {
            // 動画検知 polling を停止 (放置すると最大 30 秒 viewModel を retain し続ける)
            animationMonitorTask?.cancel()
            animationMonitorTask = nil
            // ジャンプリトライも停止 (proxy/viewModel を retain したまま scrollTo し続けない)
            jumpRetryTask?.cancel()
            jumpRetryTask = nil
            // reader close 時にこの reader 配下の再生を全停止 + 全 animated source cache 解放。
            // これをしないと SwiftUI が LazyVStack セルを即 unmount しない環境で
            // displayLink + rolling prefetch が reader 外で回り続け CPU 100% になる。
            // 加えて複数 animated source を開いた後 memory パンパンで戻る問題の回避も兼ねる。
            AnimatedPlaybackCoordinator.shared.closeReader("cell-\(gallery.gid)")
            // 田中要望 2026-04-28 (3度目指摘): 静画系メモリも完全解放。
            // 旧 resetAllState は dict removeAll するが pageHolders 構造を維持していた → 解放不足。
            // releaseAllForClose で pageHolders/imagePageURLs/thumbnails も含めて全 drop。
            viewModel.releaseAllForClose()
            // ehentai online reader でも ImageCache memory を flush (cover cache は維持)
            ImageCache.shared.purgeMemoryCache()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            guard effectiveDirection == 0 else { return .ignored }
            let target = max(0, viewModel.currentIndex - 1)
            viewModel.scrollTarget = target
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard effectiveDirection == 0 else { return .ignored }
            let maxPage = max(viewModel.totalPages - 1, 0)
            let target = min(maxPage, viewModel.currentIndex + 1)
            viewModel.scrollTarget = target
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard effectiveDirection == 1 else { return .ignored }
            horizontalPage = max(0, horizontalPage - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard effectiveDirection == 1 else { return .ignored }
            let maxPage = max(viewModel.totalPages - 1, 0)
            horizontalPage = min(maxPage, horizontalPage + 1)
            return .handled
        }
        .onChange(of: verticalSizeClass) { _, newClass in
            if newClass == .compact && zoomImage != nil {
                withAnimation(.easeOut(duration: 0.2)) { zoomImage = nil }
            }
        }
        .onChange(of: onlineQualityMode) { _, _ in
            viewModel.qualityModeChanged()
        }
        .onChange(of: imageEnhanceFilter) { _, _ in
            viewModel.filterSettingsChanged()
        }
        .onChange(of: hdrEnhancement) { _, _ in
            viewModel.filterSettingsChanged()
        }
        .onChange(of: aiImageProcessing) { _, _ in
            viewModel.filterSettingsChanged()
        }
        .onChange(of: denoiseEnabled) { _, _ in
            viewModel.filterSettingsChanged()
        }
        .alert("ページジャンプ", isPresented: $showPageJump) {
            TextField("ページ番号", text: $jumpPageText)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("ジャンプ") {
                if let page = Int(jumpPageText) {
                    viewModel.jumpTo(page: page - 1)
                }
                jumpPageText = ""
            }
            Button("キャンセル", role: .cancel) {
                jumpPageText = ""
            }
        } message: {
            Text("1〜\(viewModel.totalPages)のページ番号を入力")
        }
        .alert("標準画質で再読み込み", isPresented: $showStandardConfirm) {
            Button("再読み込み") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFilterPanel = false
                }
                viewModel.switchToStandardQuality()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("サーバーから高解像度画像を取得します。データ通信量が増加します。")
        }
        .alert("保存済みに登録", isPresented: $showAutoSavePrompt) {
            Button("残りをダウンロード") {
                let g = gallery
                let h = host
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    DownloadManager.shared.startDownload(gallery: g, host: h)
                }
            }
            Button("このまま閉じる") {
                // 保存済みデータを削除（DL一覧に残さない）
                DownloadManager.shared.deleteDownload(gid: gallery.gid)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(autoSaveInfo.saved)/\(autoSaveInfo.total) ページ保存済み。残りをダウンロードしますか？")
        }
    }

    // MARK: - 動画 WebP モード解決

    @MainActor
    private func resolveReaderMode() async {
        LogManager.shared.log("Anim", "Online resolve start gid=\(gallery.gid) userDir=\(userReaderDirection) hasMeta=\(downloadManager.downloads[gallery.gid] != nil)")
        guard userReaderDirection == 1 else {
            resolvedDirection = userReaderDirection
            return
        }
        // 1) DL 済み meta があれば実走査結果を優先 (確実)
        if downloadManager.downloads[gallery.gid] != nil {
            await downloadManager.ensureAnimatedWebpScanned(gid: gallery.gid)
            if let m = downloadManager.downloads[gallery.gid] {
                LogManager.shared.log("Anim", "Online resolve meta gid=\(gallery.gid) hasAnim=\(m.hasAnimatedWebp ?? false) override=\(m.readerModeOverride?.rawValue ?? "nil")")
                if let ov = m.readerModeOverride {
                    resolvedDirection = (ov == .horizontal) ? 1 : 0
                    return
                }
                if m.hasAnimatedWebp == true {
                    LogManager.shared.log("Anim", "Online resolve: SHOW DIALOG (meta) gid=\(gallery.gid)")
                    showAnimationDialog = true
                    return
                }
                if m.hasAnimatedWebp == false {
                    resolvedDirection = 1
                    return
                }
            }
        }
        // 2) DL 前のオンライン読みはタイトル/カテゴリ heuristic でフォールバック判定
        let title = gallery.title
        let isLikelyAnimated = title.contains("Animated") || title.contains("GIF") || title.contains("gif") || title.contains("🎥")
        LogManager.shared.log("Anim", "Online resolve heuristic gid=\(gallery.gid) titleHit=\(isLikelyAnimated) title=\(title.prefix(40))")
        if isLikelyAnimated {
            // online 状態では override 保存先がないので毎回ダイアログ (DL 後に override 永続化される)
            showAnimationDialog = true
        } else {
            resolvedDirection = 1
        }
    }

    /// オンライン読み中、最初の数ページ分のロード結果を polling して
    /// `animatedFileURL` / `animatedWebPData` が立ったら dialog 発火。
    /// 横モード設定 + 未解決 + override 無し のときだけ動く。
    @MainActor
    private func monitorAnimationDetection() async {
        guard userReaderDirection == 1 else { return }
        // 最大 30 秒 (500ms x 60) 監視。最初の 5 ページのいずれかでアニメ検知すれば dialog 発火。
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            // try? が CancellationError を吸収するため明示チェック (閉鎖後の polling 継続防止)
            if Task.isCancelled { return }
            if animationDetectionHandled { return }
            if showAnimationDialog { return }
            if let m = downloadManager.downloads[gallery.gid], m.readerModeOverride != nil { return }
            for page in 0..<min(5, viewModel.totalPages) {
                let h = viewModel.holder(for: page)
                if h.animatedWebPData != nil || h.animatedFileURL != nil {
                    animationDetectionHandled = true
                    LogManager.shared.log("Anim", "Online runtime detect: page=\(page) gid=\(gallery.gid) → SHOW DIALOG")
                    showAnimationDialog = true
                    return
                }
            }
        }
    }

    // MARK: - 自動保存チェック付きdismiss

    private func handleDismiss() {
        guard autoSaveOnRead else {
            dismiss()
            return
        }
        let info = DownloadManager.shared.checkAutoSaveCompletion(gid: gallery.gid, pageCount: viewModel.totalPages)
        if info.saved >= info.total && info.total > 0 {
            // 全ページ保存済み → そのまま閉じる
            dismiss()
        } else if info.saved > 0 {
            // 一部保存済み → 確認ダイアログ
            autoSaveInfo = info
            showAutoSavePrompt = true
        } else {
            dismiss()
        }
    }

    // MARK: - お気に入りトグル

    /// GalleryDetailView.toggleFavorite と同じ挙動 (リーダー逆輸入、2026-06-10)。
    /// サーバー反映が成功した時だけ状態とキャッシュを更新し、失敗時はログのみ
    /// (詳細ビューがアラートを出さないのでリーダーも出さない)。
    private func toggleFavorite() async {
        let action = isFavorited ? "remove" : "add"
        LogManager.shared.log("Favorite", "(reader) \(action) gid=\(gallery.gid) token=\(gallery.token)")
        do {
            if isFavorited {
                try await EhClient.shared.removeFavorite(host: host, gid: gallery.gid, token: gallery.token)
                isFavorited = false
                FavoritesCache.shared.removeFromCache(gid: gallery.gid)
                LogManager.shared.log("Favorite", "(reader) removed successfully")
            } else {
                // category は詳細ビューと同じデフォルト (= 0) を使う
                try await EhClient.shared.addFavorite(host: host, gid: gallery.gid, token: gallery.token)
                isFavorited = true
                FavoritesCache.shared.addToCache(gallery)
                LogManager.shared.log("Favorite", "(reader) added successfully")
            }
        } catch {
            LogManager.shared.log("Favorite", "(reader) \(action) FAILED: \(error)")
        }
    }

    // MARK: - 横ページめくりリーダー

    private var horizontalReader: some View {
        PagedReaderView(
            totalPages: viewModel.totalPages,
            currentPage: $horizontalPage,
            showControls: $showControls,
            readingOrder: readingOrder,
            imageForPage: { index in viewModel.holder(for: index).image },
            onPageAppear: { index in viewModel.onAppear(index: index) },
            onDismiss: { handleDismiss() },
            onZoomImage: { img in zoomImage = img }
        )
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            // 見開き/横モードの DL 進捗バー (田中要望 2026-06-09)。見開き時は左右両ページを監視
            // (片方読込済みでもう片方DL中だとバーが出ない問題対応、実機ログで確認)。
            let pairIdx = PagedReaderView.isSpreadMode ? min(horizontalPage + 1, max(0, viewModel.totalPages - 1)) : horizontalPage
            ReaderHProgressBar(holder: viewModel.holder(for: horizontalPage), pairHolder: viewModel.holder(for: pairIdx))
                .padding(.bottom, 34)
                // overlay が画面下部中央のタップを吸収して UIKit 側のページ送りゾーンに
                // 届かなくなるのを防ぐ (v02a-f12 検索履歴と同型の hit absorber 対策)
                .allowsHitTesting(false)
        }
        .onLongPressGesture(minimumDuration: 0.3) {
            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        }
        .onChange(of: horizontalPage) { _, newPage in
            if !isSliding { sliderValue = Double(newPage) }
        }
        .onChange(of: Int(sliderValue)) {
            #if canImport(UIKit)
            if isSliding {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: PagedReaderView.pageChangedNotification)) { notif in
            guard !isSliding, let page = notif.userInfo?["page"] as? Int else { return }
            if horizontalPage != page { horizontalPage = page }
            if viewModel.currentIndex != page { viewModel.currentIndex = page }
        }
        .onAppear {
            horizontalPage = viewModel.initialPage
        }
    }

    // MARK: - 縦スクロールリーダー

    private var verticalReader: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(0..<max(viewModel.totalPages, 1)), id: \.self) { index in
                        pageCell(index: index)
                            .id(index)
                            .frame(maxWidth: .infinity)
                            .onAppear { viewModel.onAppear(index: index) }
                            .onDisappear { viewModel.onDisappear(index: index) }
                    }
                }
            }
            .onChange(of: viewModel.totalPages) { _, total in
                if viewModel.initialPage > 0 && total > viewModel.initialPage {
                    scrollWithRetry(to: viewModel.initialPage, proxy: proxy, initialDelayMs: 100)
                }
            }
            .onAppear {
                if viewModel.initialPage > 0 && viewModel.totalPages > viewModel.initialPage {
                    scrollWithRetry(to: viewModel.initialPage, proxy: proxy, initialDelayMs: 200)
                }
            }
            .onChange(of: viewModel.scrollTarget) { _, target in
                if let target {
                    viewModel.scrollTarget = nil
                    scrollWithRetry(to: target, proxy: proxy, animatedFirst: true)
                }
            }
            .onChange(of: viewModel.currentIndex) { _, newIndex in
                if !isSliding {
                    sliderValue = Double(newIndex)
                    if effectiveDirection == 1 { horizontalPage = newIndex }
                }
                HistoryManager.shared.updateLastPage(gid: gallery.gid, page: newIndex)
            }
            .onChange(of: Int(sliderValue)) {
                #if canImport(UIKit)
                if isSliding {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                #endif
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
            }
        }
    }

    /// scrollTo 一発勝負だと、ジャンプ直後に周辺セルがロードされて高さが激変し、
    /// LazyVStack の推定レイアウトが崩れて目標から先頭側へ吹き飛ぶことがある
    /// (大ページ数作品で「数百ページ目へジャンプしても 1 ページ目のまま」の正体)。
    /// セル onAppear で更新される currentIndex が目標 ±3 に入るまで 0.3 秒間隔で
    /// 最大 5 回再 scrollTo する。距離が前回より「離れた」場合はユーザーの手動
    /// スクロールとみなして即中断 (奪い合い防止の安全弁)。
    private func scrollWithRetry(to target: Int, proxy: ScrollViewProxy, initialDelayMs: UInt64 = 0, animatedFirst: Bool = false) {
        jumpRetryTask?.cancel()
        jumpRetryTask = Task { @MainActor in
            if initialDelayMs > 0 {
                // 旧実装の asyncAfter 相当: LazyVStack のセル mount を待つ
                try? await Task.sleep(nanoseconds: initialDelayMs * 1_000_000)
                if Task.isCancelled { return }
            }
            var lastDistance = Int.max
            for attempt in 0..<5 {
                if animatedFirst && attempt == 0 {
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                } else {
                    // リトライは非アニメ即時 (アニメ中のセルロードで再度ズレるのを避ける)
                    proxy.scrollTo(target, anchor: .top)
                }
                // セル onAppear → currentIndex 反映を待ってから到達判定
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                let distance = abs(viewModel.currentIndex - target)
                if distance <= 3 { return }            // 到達
                if distance > lastDistance { return }  // 手動スクロールで離れていく → ユーザー優先
                lastDistance = distance
            }
        }
    }

    // MARK: - 各ページのセル

    private func pageCell(index: Int) -> some View {
        #if canImport(UIKit)
        PageCellView(
            holder: viewModel.holder(for: index),
            index: index,
            isPlaceholder: viewModel.isPlaceholder(index: index),
            qualityMode: onlineQualityMode,
            verticalSizeClass: verticalSizeClass,
            onTap: { img in zoomImage = img },
            onRetry: { viewModel.retry(index: index) },
            isHorizontalMode: effectiveDirection == 1,
            isActiveAnimation: index == viewModel.currentIndex,
            mp4Gid: gallery.gid,
            onToggleControls: {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            },
            manualPlayForAnimated: true,
            // 未ロードセルの高さを実ページ想定高さに安定化 (iOS 縦のみ有効、Catalyst は cell 側で除外)
            estimatedAspect: viewModel.pageAspect(for: index)
        )
        #else
        PageCellView(
            holder: viewModel.holder(for: index),
            index: index,
            isPlaceholder: viewModel.isPlaceholder(index: index),
            qualityMode: onlineQualityMode,
            verticalSizeClass: verticalSizeClass,
            onTap: { img in zoomImage = img },
            onRetry: { viewModel.retry(index: index) },
            isHorizontalMode: effectiveDirection == 1,
            estimatedAspect: viewModel.pageAspect(for: index)
        )
        #endif
    }

    // MARK: - ECO画質設定パネル

    private var ecoFilterPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "leaf.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text("ECOモード")
                    .font(.subheadline.bold())
                Spacer()
            }
            .foregroundStyle(.white)

            if isLowQualityMode {
                Button {
                    showStandardConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("標準画質で読み込み直す")
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
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showFilterPanel = false }
                    viewModel.switchToLowQualityMode()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("低画質モードに切り替え")
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

            Text("画像処理OFF・省電力動作中")
                .font(.caption2)
                .foregroundStyle(.green.opacity(0.7))
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .foregroundStyle(.white)
    }

    // MARK: - 画質設定パネル

    private var isLowQualityMode: Bool { onlineQualityMode <= 1 }

    private var onlineFilterPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline)
                Text("画質設定")
                    .font(.subheadline.bold())
                Spacer()
                if isLowQualityMode {
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
                .font(.subheadline)
                .tint(.green)
                .onChange(of: noFilterMode) {
                    viewModel.filterSettingsChanged()
                }

            if !noFilterMode {
                Toggle("画像補正フィルタ", isOn: $imageEnhanceFilter)
                    .font(.subheadline)
                    .tint(.blue)

                Toggle("ノイズ除去", isOn: $denoiseEnabled)
                    .font(.subheadline)
                    .tint(.blue)

            HStack {
                Toggle("HDR風補正（カラー作品推奨）", isOn: $hdrEnhancement)
                    .font(.subheadline)
                    .tint(.blue)
                if imageEnhanceFilter {
                    Text("(HDR統合済み)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

                Toggle("AI超解像", isOn: $aiImageProcessing)
                    .font(.subheadline)
                    .tint(.blue)
            } // end if !noFilterMode

            Divider().overlay(.gray.opacity(0.5))

            if isLowQualityMode {
                Toggle("超解像モード", isOn: Binding(
                    get: { onlineQualityMode == 1 },
                    set: { on in
                        if on {
                            viewModel.switchToUpscaleMode()
                        } else {
                            viewModel.switchToLowQualityMode()
                        }
                    }
                ))
                .font(.subheadline)
                .tint(.blue)

                Button {
                    showStandardConfirm = true
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
                    viewModel.switchToLowQualityMode()
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
                .font(.subheadline)
                .tint(.blue)

            if viewModel.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                    Text("読み込み中...")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .foregroundStyle(.white)
    }

    /// 見開き対応ページラベル
    private var spreadPageLabelText: String {
        let page = isSliding ? Int(sliderValue) : (effectiveDirection == 1 ? horizontalPage : viewModel.currentIndex)
        if effectiveDirection == 1 { // 横モード
            return PagedReaderView.spreadPageLabel(
                currentPage: page,
                totalPages: viewModel.totalPages,
                readingOrder: readingOrder,
                imageForPage: { viewModel.holder(for: $0).image }
            )
        }
        return "\(page + 1) / \(viewModel.totalPages)"
    }

    // MARK: - コントロール

    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button {
                    handleDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(gallery.title)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                // お気に入りボタン (nh リーダーと同じ並び: お気に入り → 翻訳 → 画質設定)
                // 挙動は GalleryDetailView.toggleFavorite と完全に同じ
                // (サーバー成功後に状態+キャッシュ更新、失敗はログのみ)
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Image(systemName: isFavorited ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(isFavorited ? .red : .white)
                }
                .buttonStyle(.plain)

                Button {
                    if translationMode {
                        // OFF時にキャッシュクリア（誤翻訳リセット）
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

            // ページスライダー + ジャンプ
            VStack(spacing: 6) {
                if viewModel.totalPages > 1 {
                    Slider(
                        value: $sliderValue,
                        in: 0...Double(max(viewModel.totalPages - 1, 1)),
                        step: 1
                    ) { editing in
                        isSliding = editing
                        if editing {
                            withAnimation(.easeIn(duration: 0.15)) {
                                showPageOverlay = true
                            }
                        } else {
                            let target = Int(sliderValue)
                            if effectiveDirection == 1 {
                                horizontalPage = target
                                viewModel.currentIndex = target
                            } else {
                                viewModel.jumpTo(page: target)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    showPageOverlay = false
                                }
                            }
                        }
                    }
                    .tint(.white)
                    .padding(.horizontal)
                    .environment(\.layoutDirection, readingOrder == 1 && effectiveDirection == 1 ? .rightToLeft : .leftToRight)
                }

                HStack {
                    Button {
                        showPageJump = true
                    } label: {
                        Text(spreadPageLabelText)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
            .background(.ultraThinMaterial.opacity(0.8))
        }
    }
}

/// 横/見開きモード用の DL 進捗バー (田中要望 2026-06-09)。現在ページの holder を
/// @ObservedObject で監視し、loadProgress があればクルクル+バー+% を表示。
private struct ReaderHProgressBar: View {
    @ObservedObject var holder: PageImageHolder
    /// 見開き時の右ページ holder (単独時は holder と同一インスタンスを渡す)。
    @ObservedObject var pairHolder: PageImageHolder
    private var activeProgress: Double? {
        if holder.loadProgress > 0 && holder.loadProgress < 1 { return holder.loadProgress }
        if pairHolder.loadProgress > 0 && pairHolder.loadProgress < 1 { return pairHolder.loadProgress }
        return nil
    }
    var body: some View {
        if let p = activeProgress {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6).tint(.white)
                ProgressView(value: p)
                    .progressViewStyle(.linear).frame(width: 130).tint(.white)
                Text("\(Int(p * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.black.opacity(0.6)).clipShape(Capsule())
        }
    }
}
