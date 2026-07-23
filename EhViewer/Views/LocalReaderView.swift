import SwiftUI
import TipKit
import ImageIO

struct LocalReaderView: View {
    let meta: DownloadedGallery
    var isLiveDownload: Bool = false
    let initialPage: Int
    /// 方向の強制指定。nil = 設定/override から解決。
    /// 「タイル起動=左右」は 2026-07-21 深夜に田中裁定で撤回 (縦設定を無視して横で開くのは誤り)。
    /// 現在 nil 以外を渡す呼び出し元は無い (配管のみ残置)。
    var forcedDirection: Int? = nil
    /// タイルタップ等の明示ページ指定で起動したか (真なら再開プロンプトを出さない)。
    var explicitPageLaunch: Bool = false
    /// 起動経路ラベル (2026-07-21 第21条: 経路を機械が記録する)
    let route: LaunchRoute

    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var showPageJump = false
    @State private var jumpPageText = ""
    // 自動栞 (Phase R-1): 続き/最初 選択ダイアログ用
    @State private var pendingResumePage: Int = 0
    @State private var showResumeDialog = false
    @State private var didOfferResume = false
    /// 田中報告 2026-07-21: モード解決ダイアログ/警告が繰り返し出る → 1リーダー1回に固定
    @State private var didResolveMode = false
    @State private var currentIndex: Int
    @State private var dragOffset: CGFloat = 0
    @State private var zoomImage: PlatformImage?
    @State private var sliderValue: Double
    @State private var isSliding = false
    /// isSliding 固着対策 (2026-07-02, Day14 iPad スライダー追従不具合): スライダー最終活動時刻
    @State private var lastSliderActivity = Date.distantPast

    /// iPadOS 26 で Slider の onEditingChanged(false) 直後に幽霊 (true) が届いて
    /// isSliding が固着する事象を実機ログで観測 (2026-07-02)。実ドラッグ中は
    /// sliderValue 更新で lastSliderActivity が刷新され続けるため、2 秒以上静止した
    /// ままスクロール由来のページ更新が来た場合のみ固着と判定し強制解除する。
    private func healStuckSliderIfNeeded() {
        guard isSliding, Date().timeIntervalSince(lastSliderActivity) > 2.0 else { return }
        LogManager.shared.log("iPadScroll", "Local isSliding auto-heal: quiescent → false")
        isSliding = false
    }
    // Phase R-6: シーク時サムネプレビュー用キャッシュ (page → 240px サムネ)
    @State private var seekThumbs: [Int: PlatformImage] = [:]
    // Phase R-6: プレビューパネルの常駐表示 (左右タップ移動/外側タップで閉じる)
    @State private var seekPreviewVisible = false
    @State private var sliderJumpTarget: Int?
    @State private var showPageOverlay = false
    @State private var enhancedImages: [Int: PlatformImage] = [:]
    @State private var showFilterPanel = false
    @State private var reprocessTrigger = 0
    @State private var availablePages: Set<Int> = []
    @State private var pageCheckTimer: Timer?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(UDKey.downloadQualityMode) private var storedDlMode = 2
    @AppStorage(UDKey.imageEnhanceFilter) private var storedEnhanceFilter = false
    @AppStorage(UDKey.hdrEnhancement) private var storedHDR = false
    @AppStorage(UDKey.aiImageProcessing) private var storedAI = false
    @AppStorage(UDKey.denoiseEnabled) private var storedDenoise = false
    @AppStorage(UDKey.noFilterMode) private var storedNoFilter = false
    @AppStorage(UDKey.boomerangMode) private var boomerangMode = true
    @AppStorage(UDKey.readerDirection) private var readerDirection = 0
    @AppStorage(UDKey.readingOrder) private var readingOrder = 1
    @AppStorage(UDKey.animPlaybackMode) private var animPlaybackMode = "webp"
    @State private var horizontalPage: Int
    /// 縦モードでトップに見えてるセル id を Apple 公式 .scrollPosition(id:) で追跡。
    /// 旧実装の ForEach.onAppear 上書きは mount 順非決定 → スライダー値が「明後日」になる欠陥があった。
    @State private var scrolledID: Int?
    /// 動画 WebP ギャラリーの per-gallery モード解決結果 (nil = 未解決、ダイアログ待ち or scan 中)
    @State private var resolvedDirection: Int? = nil
    @State private var showAnimationDialog = false
    /// WebP 動画の性能警告 (A17 以下端末のみ)。2026-07-21 SE2 実測より。
    @State private var showWebPPerfWarning = false

    // Phase E1.B 後追加 (2026-04-26、田中指示): 外部参照 ZIP gallery で大幅 jump 時の
    // background pre-cache + overlay。main thread SMB IO による freeze 回避。
    @State private var jumpPreCacheActive = false
    @State private var jumpPreCacheCurrent = 0
    @State private var jumpPreCacheTotal = 0
    /// 大幅 jump 判定閾値 (これ以上のページ移動で pre-cache overlay 起動)
    private let jumpThreshold = 10

    /// 自動栞 (Phase R-1): 栞ページへジャンプ (方向別・大ジャンプは pre-cache 経由)
    private func resumeToBookmark(_ target: Int) {
        if effectiveDirection == 0 {
            if target >= jumpThreshold { startJumpPreCache(target: target) { scrolledID = target } }
            else { scrolledID = target }
        } else {
            if target >= jumpThreshold { startJumpPreCache(target: target) { horizontalPage = target } }
            else { horizontalPage = target }
        }
        currentIndex = target
        sliderValue = Double(target)
    }

    // MARK: - Phase R-6: シーク時サムネプレビュー (ローカル作品限定)
    private var seekThumbnailStrip: some View {
        let v = Int(sliderValue)
        let rtl = readingOrder == 1 && isHorizontal   // 右綴じ横読み
        return HStack(spacing: 5) {
            seekThumbCell(v - 2, big: false)
            seekThumbCell(v - 1, big: false)
            seekThumbCell(v, big: true)
            seekThumbCell(v + 1, big: false)
            seekThumbCell(v + 2, big: false)
        }
        // 右綴じは次ページ(v+1,v+2)を左側に並べる。スライダーと同じ layoutDirection 方式。
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { }  // 帯内余白タップは閉じない (cell tap が優先)
        .gesture(
            // Phase R-6: プレビューを左右スワイプでページ送り (右綴じは方向反転=右スワイプで次)
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    let dx = value.translation.width
                    if dx <= -24 { navigateSeek(to: rtl ? v - 1 : v + 1) }      // 左スワイプ
                    else if dx >= 24 { navigateSeek(to: rtl ? v + 1 : v - 1) }  // 右スワイプ
                }
        )
    }

    /// Phase R-6: 常駐プレビューパネル (暗幕外タップで閉じる)
    @ViewBuilder
    private var seekPreviewLayer: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { hideSeekPreview() }
            VStack(spacing: 4) {
                Spacer()
                seekThumbnailStrip
                Text("中央=決定 / 左右=移動 / 外側=閉じる")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer().frame(height: 130)
            }
        }
        .transition(.opacity)
    }

    /// Phase R-6: 指定ページへ移動しプレビューを更新 (パネルは閉じない)
    private func navigateSeek(to p: Int) {
        guard p >= 0 && p < meta.pageCount else { return }
        sliderValue = Double(p)
        if isHorizontal { horizontalPage = p } else { sliderJumpTarget = p }
        loadSeekThumbs(around: p)
    }

    /// Phase R-6: プレビューを閉じてサムネ解放
    private func hideSeekPreview() {
        withAnimation(.easeOut(duration: 0.15)) { seekPreviewVisible = false }
        seekThumbs = [:]
        showPageOverlay = false
    }

    @ViewBuilder
    private func seekThumbCell(_ page: Int, big: Bool) -> some View {
        let valid = page >= 0 && page < meta.pageCount
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12))
            if valid, let img = seekThumbs[page] {
                Image(uiImage: img).resizable().scaledToFill()
            }
        }
        .frame(width: big ? 86 : 54, height: big ? 128 : 82)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { if big { RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2) } }
        .opacity(valid ? 1 : 0.2)
        .contentShape(Rectangle())
        .onTapGesture {
            if big { hideSeekPreview() }       // 中央=決定して閉じる
            else if valid { navigateSeek(to: page) }  // 左右=そのページへ移動
        }
    }

    /// シーク位置前後3枚の 240px サムネを背景ロードしてキャッシュ (ディスク上のローカル画像のみ)
    private func loadSeekThumbs(around v: Int) {
        let gid = meta.gid
        let total = meta.pageCount
        for p in [v - 2, v - 1, v, v + 1, v + 2] where p >= 0 && p < total && seekThumbs[p] == nil {
            Task.detached(priority: .userInitiated) {
                guard let data = DownloadManager.shared.loadLocalImageData(gid: gid, page: p),
                      let src = CGImageSourceCreateWithData(data as CFData, nil) else { return }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 240,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
                let img = PlatformImage(cgImage: cg)
                await MainActor.run { seekThumbs[p] = img }
            }
        }
    }
    /// β-1 (2026-04-26): 外部参照 ZIP background materialize 完了通知で incrément、body 再描画 trigger
    @State private var externalCortexReadyCounter: Int = 0

    init(meta: DownloadedGallery, isLiveDownload: Bool = false, initialPage: Int = 0,
         forcedDirection: Int? = nil, explicitPageLaunch: Bool = false, route: LaunchRoute) {
        self.meta = meta
        self.isLiveDownload = isLiveDownload
        self.initialPage = initialPage
        self.forcedDirection = forcedDirection
        self.explicitPageLaunch = explicitPageLaunch
        self.route = route
        self._currentIndex = State(initialValue: initialPage)
        self._sliderValue = State(initialValue: Double(initialPage))
        self._horizontalPage = State(initialValue: initialPage)
        self._scrolledID = State(initialValue: initialPage)
    }

    /// 動画 WebP migration / override 解決後の有効モード。未解決なら一瞬黒画面。
    private var effectiveDirection: Int { resolvedDirection ?? readerDirection }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if resolvedDirection != nil {
                if effectiveDirection == 0 {
                    verticalReader
                } else {
                    localHorizontalReader
                }
            }

            // Phase R-6: シークサムネプレビュー (常駐・タップ移動・外側タップで閉じる)
            // controlsOverlay より「下層」に置く → シークバーは最前面のまま操作可能、
            // 中央の透明領域タップは暗幕に抜けて dismiss、サムネタップはセルが拾う。
            if seekPreviewVisible {
                seekPreviewLayer
            }

            if showControls && zoomImage == nil {
                controlsOverlay
            }

            // Tips
            if showControls {
                VStack(spacing: 8) {
                    TipView(ReaderControlsTip(), arrowEdge: .bottom)
                    if isHorizontal {
                        TipView(ReaderSwipeDismissTip(), arrowEdge: .bottom)
                        TipView(HorizontalReaderTip(), arrowEdge: .bottom)
                    }
                    if isHorizontal && readingOrder == 1 {
                        TipView(RTLSliderTip(), arrowEdge: .bottom)
                    }
                    if UIDevice.current.userInterfaceIdiom == .pad && isHorizontal {
                        TipView(SpreadModeTip(), arrowEdge: .bottom)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 120)
                .frame(maxHeight: .infinity, alignment: .bottom)
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

            if showFilterPanel && zoomImage == nil && !EcoMode.shared.isEnabled {
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showFilterPanel = false
                        }
                    }

                VStack {
                    Spacer()
                    downloadFilterPanel
                }
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let img = zoomImage {
                ZoomableImageOverlay(image: img) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        zoomImage = nil
                    }
                }
            }
        }
        .offset(x: dragOffset)
        .opacity(dragOffset > 0 ? max(0, 1.0 - dragOffset / 400.0) : 1.0)
        .overlay(alignment: .leading) {
            // 横モード時は左エッジスワイプ無効（ページ送りと干渉防止）
            if zoomImage == nil && !isHorizontal {
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
                                    LogManager.shared.log("Tap", "local dismiss: edge-swipe")
                                    dismiss()
                                } else {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
            }
            // Phase E1.B 後追加 (2026-04-26): 大幅 jump pre-cache overlay (external_zip / internal DL 共通)
            if jumpPreCacheActive {
                jumpPreCacheOverlay
                    .transition(.opacity)
            }
        }
        #if os(iOS)
        .persistentSystemOverlays(showControls && zoomImage == nil ? .automatic : .hidden)
        .statusBarHidden(!showControls || zoomImage != nil)
        .toolbar(showControls && zoomImage == nil ? .visible : .hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .externalCortexImageReady)) { notif in
            // β-1 (2026-04-26): 外部参照 ZIP background materialize 完了で body 再描画 trigger。
            // counter 増分 → SwiftUI body 再評価 → loadLocalImage 再呼出 → 新画像反映。
            guard let gid = notif.userInfo?["gid"] as? Int, gid == meta.gid else { return }
            externalCortexReadyCounter += 1
        }
        .onChange(of: verticalSizeClass) { _, newClass in
            if newClass == .compact && zoomImage != nil {
                withAnimation(.easeOut(duration: 0.2)) { zoomImage = nil }
            }
        }
        .onChange(of: storedDlMode) { _, _ in reprocessVisiblePages() }
        .onChange(of: storedEnhanceFilter) { _, _ in reprocessVisiblePages() }
        .onChange(of: storedHDR) { _, _ in reprocessVisiblePages() }
        .onChange(of: storedAI) { _, _ in reprocessVisiblePages() }
        .onChange(of: storedDenoise) { _, _ in reprocessVisiblePages() }
        .onChange(of: storedNoFilter) { _, _ in reprocessVisiblePages() }
        .onAppear {
                ShikigamiEngine.shared.currentScreen = "Reader-Local"
            if isLiveDownload {
                scanAvailablePages()
                startPageCheckTimer()
            }
            // 自動栞 (Phase R-1): 明示ページ未指定 & 非ライブ & 栞あり → 続き/最初 選択ダイアログ
            // 田中報告 2026-07-21: タイルタップはページ 0 タイルでも明示ページ指定なので
            // 再開プロンプトを出さない (explicitPageLaunch)。forced 指定時も同様。
            if initialPage == 0 && !explicitPageLaunch && forcedDirection == nil
                && !isLiveDownload && !didOfferResume {
                didOfferResume = true
                let saved = UserDefaults.standard.integer(forKey: UDKey.localReaderBookmark(gid: meta.gid))
                if saved > 0 && saved < meta.pageCount {
                    pendingResumePage = saved
                    showResumeDialog = true
                }
            }
        }
        .task {
            ShikigamiEngine.shared.currentScreen = "R:\(route.rawValue)"
            LogManager.shared.log("Route", "ROUTE \(route.rawValue) reader=Local gid=\(meta.gid) pages=\(meta.pageCount) dirSetting=\(readerDirection) forced=\(forcedDirection.map(String.init) ?? "nil")")
            await resolveReaderMode()
        }
        .confirmationDialog("前回の続きから読みますか？", isPresented: $showResumeDialog, titleVisibility: .visible) {
            Button("\(pendingResumePage + 1)ページ目から再開") { resumeToBookmark(pendingResumePage) }
            Button("最初から見る", role: .cancel) { }
        }
        // 田中報告 2026-07-21: 左右綴じでページめくりスワイプが zoom 遷移 (B3) の
        // インタラクティブ dismiss に食われてリーダーが閉じる。横モードのみ無効化し、
        // 縦モードのピンチ/ドラッグ閉じは残す。
        .interactiveDismissDisabled(isHorizontal)
        .webpPerfWarning(isPresented: $showWebPPerfWarning)
        .animationModeDialog(isPresented: $showAnimationDialog) { mode, dontAskAgain in
            if dontAskAgain {
                downloadManager.setReaderModeOverride(gid: meta.gid, mode: mode)
            }
            resolvedDirection = (mode == .horizontal) ? 1 : 0
        }
        .onDisappear {
            ShikigamiEngine.shared.clearScreen("Reader-Local")
            pageCheckTimer?.invalidate()
            pageCheckTimer = nil
            // reader close 時にこの reader 配下の再生を全停止 + 全 animated source cache 解放。
            // これをしないと SwiftUI が LazyVStack セルを即 unmount しない環境で displayLink +
            // rolling prefetch が reader 外で回り続け CPU 100% になる。
            // 加えて複数 animated source を開いた後 memory パンパンで戻る問題の回避も兼ねる。
            AnimatedPlaybackCoordinator.shared.closeReader("local-\(meta.gid)")
            // 静画フィルタ済みキャッシュも全解放: 400 ページ gallery で enhancedImages が
            // 数百 MB 居座る (田中報告 2026-04-25 二度目)。
            enhancedImages.removeAll()
            // 田中要望 2026-04-30 (4 度目指摘): リーダー閉じてもメモリ残存。
            // 残 State も全 drop で解放を確実にする (zoomImage は frame 全展開済 UIImage で大容量)。
            zoomImage = nil
            availablePages.removeAll()
            // 田中要望 2026-04-26: reader close 時のメモリパンパン対策、page image cache 強制 flush
            // cover cache は flush しない (Library 戻り時に NAS sync 再読込 → 5s freeze の原因)
            ImageCache.shared.purgeMemoryCache()
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            guard effectiveDirection == 0 else { return .ignored }
            let target = max(0, currentIndex - 1)
            scrolledID = target
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard effectiveDirection == 0 else { return .ignored }
            let maxPage = max(meta.pageCount - 1, 0)
            let target = min(maxPage, currentIndex + 1)
            scrolledID = target
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard effectiveDirection == 1 else { return .ignored }
            horizontalPage = max(0, horizontalPage - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard effectiveDirection == 1 else { return .ignored }
            let maxPage = max(meta.pageCount - 1, 0)
            horizontalPage = min(maxPage, horizontalPage + 1)
            return .handled
        }
    }

    // MARK: - 動画 WebP モード解決

    @MainActor
    private func resolveReaderMode() async {
        // 負債返済ユニット2 (2026-07-23): 判定ラダーは ReaderModeResolver に一元化。
        // ここは結果の反映と性能警告 (ローカル固有) だけを持つ。
        LogManager.shared.log("Anim", "Local resolve start gid=\(meta.gid) userDir=\(readerDirection)")
        let outcome = await ReaderModeResolver.resolve(.init(
            gid: meta.gid,
            userDirection: readerDirection,
            forcedDirection: forcedDirection,
            localMeta: meta,
            logPrefix: "Local"
        ))
        // 性能警告 (2026-07-21 SE2 実測): A17 以下は WebP 動画の実時間再生に CPU が足りない。
        // 未来の端末には出ない (DeviceCapability は世代番号の閾値判定)。1度きり + 抑止可能。
        if outcome.hasAnimatedConfirmed,
           DeviceCapability.isAnimatedWebPUnderpowered,
           !UserDefaults.standard.bool(forKey: UDKey.webpPerfWarningSuppressed) {
            showWebPPerfWarning = true
        }
        switch outcome.resolution {
        case .direction(let dir): resolvedDirection = dir
        case .askUser: showAnimationDialog = true
        }
    }

    // MARK: - ライブDL監視

    private func scanAvailablePages() {
        var pages = Set<Int>()
        let dm = DownloadManager.shared
        for i in 0..<meta.pageCount {
            if dm.loadLocalImage(gid: meta.gid, page: i) != nil {
                pages.insert(i)
            }
        }
        availablePages = pages
    }

    private func startPageCheckTimer() {
        pageCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let dm = DownloadManager.shared
            var changed = false
            for i in 0..<meta.pageCount {
                if !availablePages.contains(i) {
                    let filePath = dm.imageFilePath(gid: meta.gid, page: i)
                    if FileManager.default.fileExists(atPath: filePath.path) {
                        availablePages.insert(i)
                        changed = true
                    }
                }
            }
            // DL完了でタイマー停止
            if availablePages.count >= meta.pageCount {
                pageCheckTimer?.invalidate()
                pageCheckTimer = nil
            }
            // 横モードの更新
            if changed && effectiveDirection == 1 {
                reprocessTrigger += 1
            }
        }
    }

    // MARK: - 横ページめくりリーダー

    private var localHorizontalReader: some View {
        PagedReaderView(
            totalPages: meta.pageCount,
            currentPage: $horizontalPage,
            showControls: $showControls,
            readingOrder: readingOrder,
            imageForPage: { index in
                enhancedImages[index] ?? DownloadManager.shared.loadLocalImage(gid: meta.gid, page: index)
            },
            onPageAppear: { index in
                currentIndex = index
                // 田中要望 2026-04-27: 大ジャンプ中は通過する中間 cells で processPage を走らせない
                // (CoreML enhancement が main を詰まらせ ScrollView が target に到達できない fix)
                if let target = sliderJumpTarget, index != target { return }
                if enhancedImages[index] == nil { processPage(index) }
            },
            onDismiss: {
                LogManager.shared.log("Tap", "local dismiss: paged-reader callback")
                dismiss()
            },
            onZoomImage: { img in zoomImage = img }
        )
        // 田中報告 2026-04-30: `.id(reprocessTrigger)` は ScrollView ごと再生成 → 暗転原因。
        //   reprocess は enhancedImages の上書きだけで実現するように移行 (reprocessVisiblePages 参照)。
        .ignoresSafeArea()
        .onChange(of: horizontalPage) { _, newPage in
            currentIndex = newPage
            healStuckSliderIfNeeded()
            if !isSliding { sliderValue = Double(newPage) }
        }
        .onChange(of: Int(sliderValue)) {
            #if canImport(UIKit)
            if isSliding {
                lastSliderActivity = Date()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                horizontalPage = Int(sliderValue)
            }
            #endif
        }
        .alert("ページジャンプ", isPresented: $showPageJump) {
            TextField("ページ番号", text: $jumpPageText)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("ジャンプ") {
                if let page = Int(jumpPageText), page >= 1, page <= meta.pageCount {
                    let target = page - 1
                    if abs(target - currentIndex) >= jumpThreshold {
                        startJumpPreCache(target: target) {
                            horizontalPage = target
                        }
                    } else {
                        horizontalPage = target
                    }
                }
                jumpPageText = ""
            }
            Button("キャンセル", role: .cancel) { jumpPageText = "" }
        } message: {
            Text("1〜\(meta.pageCount)のページ番号を入力")
        }
    }

    // MARK: - 縦スクロールリーダー

    private var verticalReader: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<meta.pageCount, id: \.self) { index in
                        localPageCell(index: index)
                            .id(index)
                            .frame(maxWidth: .infinity)
                            #if canImport(UIKit)
                            .background(
                                Group {
                                    if UIDevice.current.userInterfaceIdiom == .pad {
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: PagePositionKey.self,
                                                value: [index: geo.frame(in: .named("localReaderScroll")).midY]
                                            )
                                        }
                                    }
                                }
                            )
                            #endif
                    }
                }
                .scrollTargetLayout()
            }
            .coordinateSpace(name: "localReaderScroll")
            .scrollPosition(id: $scrolledID, anchor: .top)
            #if canImport(UIKit)
            .onPreferenceChange(PagePositionKey.self) { positions in
                LogManager.shared.log("iPadScroll", "preference update: \(positions.count) positions, keys=\(positions.keys.sorted())")
                guard UIDevice.current.userInterfaceIdiom == .pad, !positions.isEmpty else { return }
                // 田中要望 2026-04-27: ジャンプフリーズ修正。
                // (1) 大ジャンプ (例 page 6 → 634) 直後、ScrollView が target に到達する前は
                //     LazyVStack が古い viewport の cells (6, 7) を preference で報告し続ける。
                //     このまま closest.key = 6 を currentIndex に書き戻すと jump がキャンセルされ、
                //     scrolledID=634 と currentIndex=6 が衝突してフリーズ症状になる。
                //     → scrolledID が positions.keys から大きく離れている場合は mid-scroll と判定し
                //       preference 由来の currentIndex 更新を skip する。
                // (2) ジャンプ完了判定: target cell が実際に viewport に現れたら sliderJumpTarget をクリア
                //     (これ以降は通常通り processPage が走る)
                if let target = sliderJumpTarget, positions.keys.contains(target) {
                    LogManager.shared.log("iPadScroll", "jump arrived target=\(target), clearing sliderJumpTarget")
                    sliderJumpTarget = nil
                }
                if let sid = scrolledID, !positions.keys.contains(sid) {
                    let nearest = positions.keys.min(by: { abs($0 - sid) < abs($1 - sid) }) ?? sid
                    if abs(nearest - sid) > 5 {
                        LogManager.shared.log("iPadScroll", "preference skipped (mid-scroll): scrolledID=\(sid) keys=\(positions.keys.sorted())")
                        return
                    }
                }
                let screenMid = UIScreen.main.bounds.height / 2
                if let closest = positions.min(by: { abs($0.value - screenMid) < abs($1.value - screenMid) }) {
                    LogManager.shared.log("iPadScroll", "closest to center=\(Int(screenMid)): index=\(closest.key) midY=\(Int(closest.value))")
                    if currentIndex != closest.key {
                        LogManager.shared.log("iPadScroll", "currentIndex change via preference: \(currentIndex) → \(closest.key)")
                        currentIndex = closest.key
                    }
                }
            }
            #endif
            .onChange(of: scrolledID) { _, newID in
                LogManager.shared.log("iPadScroll", "scrolledID changed: \(newID ?? -1) idiom=\(UIDevice.current.userInterfaceIdiom.rawValue)")
                if let newID {
                    currentIndex = newID
                    // jump 完了判定は scrolledID == target ではなく、preference で target cell が
                    // 実際に viewport に現れた時点 (onPreferenceChange 内で行う) に統一する。
                    // ScrollView は scrolledID を即値で受け取るがアニメーション中は viewport に
                    // target がまだ無いため、ここでのクリアは早すぎる (intermediate cells で
                    // processPage が走り main を詰まらせフリーズの原因になる)。
                }
            }
            .onChange(of: currentIndex) { old, new in
                LogManager.shared.log("iPadScroll", "currentIndex: \(old) → \(new) isSliding=\(isSliding)")
                healStuckSliderIfNeeded()
                if !isSliding {
                    sliderValue = Double(new)
                    // 自動栞 (Phase R-1): ライブラリ作品の最終閲覧ページを保存 (gid キー)
                    UserDefaults.standard.set(new, forKey: UDKey.localReaderBookmark(gid: meta.gid))
                }
                // enhancedImages LRU: 400 ページスクロールで dict 無制限膨張 → メモリ圧迫。
                // currentIndex 前後 ±30 ページ外のエントリを削除して常時 ~60 entry に抑制。
                let keepLo = max(0, new - 30)
                let keepHi = new + 30
                let before = enhancedImages.count
                enhancedImages = enhancedImages.filter { $0.key >= keepLo && $0.key <= keepHi }
                if before - enhancedImages.count > 0 {
                    LogManager.shared.log("Mem", "enhancedImages LRU: evicted=\(before - enhancedImages.count) kept=\(enhancedImages.count)")
                }
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
            .alert("ページジャンプ", isPresented: $showPageJump) {
                TextField("ページ番号", text: $jumpPageText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("ジャンプ") {
                    if let page = Int(jumpPageText), page >= 1, page <= meta.pageCount {
                        // .scrollPosition(id:) と ScrollViewReader.scrollTo の併用で
                        // scrolledID と実スクロール位置が乖離するため、scrolledID 直接代入に統一。
                        let target = page - 1
                        if abs(target - currentIndex) >= jumpThreshold {
                            // 田中要望 2026-04-27: 大ジャンプは animation 無し + processPage skip
                            // sliderJumpTarget 設定で onPageAppear の中間 cell processPage 抑制
                            sliderJumpTarget = target
                            startJumpPreCache(target: target) {
                                scrolledID = target  // 即値、アニメ無し
                            }
                        } else {
                            withAnimation { scrolledID = target }
                        }
                    }
                    jumpPageText = ""
                }
                Button("キャンセル", role: .cancel) {
                    jumpPageText = ""
                }
            } message: {
                Text("1〜\(meta.pageCount)のページ番号を入力")
            }
            .onChange(of: sliderJumpTarget) { _, target in
                if let target {
                    LogManager.shared.log("iPadScroll", "slider set: target=\(target)")
                    // 田中要望 2026-04-26: 大幅 jump (external_zip / internal DL 両方) で
                    // background pre-cache + loading overlay 表示。
                    if abs(target - currentIndex) >= jumpThreshold {
                        startJumpPreCache(target: target) {
                            // 田中要望 2026-04-27: 大ジャンプは animation 切って即時 scroll。
                            // withAnimation 経由だと ScrollView が中間 600+ cells を順次 render
                            // しようとして 10 秒級フリーズの原因になる。即値スクロールなら
                            // target 周辺数 cell だけ render すれば済む。
                            scrolledID = target
                        }
                        return
                    }
                    // 小幅 jump (< jumpThreshold) はアニメーション維持で滑らかに
                    withAnimation {
                        scrolledID = target
                    }
                    sliderJumpTarget = nil
                }
            }
        }
    }

    // MARK: - 画質再処理

    /// 設定変更時に表示中ページを再処理
    /// 田中報告 2026-04-30: HDR/ノイズ除去 toggle で瞬間暗転 →
    ///   `enhancedImages.removeAll()` で全 cell が nil 化 + `.id(reprocessTrigger)` で
    ///   ScrollView 再生成 → 全 cell が placeholder (Color.clear) に。
    ///   修正: 古い画像を保持したまま processPage が同 index に上書き → atomic 置換で暗転なし。
    ///   visible 範囲外だけ破棄して後の onAppear で再処理。
    private func reprocessVisiblePages() {
        let center = currentIndex
        let lo = max(0, center - 2)
        let hi = min(meta.pageCount - 1, center + 2)
        let visibleSet = Set(lo...hi)
        enhancedImages = enhancedImages.filter { visibleSet.contains($0.key) }
        for i in lo...hi {
            processPage(i)
        }
    }

    /// ページを現在の設定で処理してenhancedImagesに格納
    private func processPage(_ index: Int) {
        // ECOモード: フィルタ全スキップ
        if EcoMode.shared.isEnabled { return }
        let mode = storedDlMode
        let enhanceFilterOn = storedEnhanceFilter
        let hdrOn = storedHDR
        let useAI = storedAI && CoreMLImageProcessor.shared.modelAvailable
        let denoiseOn = storedDenoise
        let noFilter = storedNoFilter

        // 無補正モード: フィルタは一切かけないが、`enhancedImages[index]` に raw 画像を入れないと
        // アニメ WebP セル (line 578) の `staticPlaceholder: enhancedImages[index]` が nil になり
        // BoomerangWebPView が Color.clear を出す = 「ポスター表示されない」バグ。
        // raw 画像を detached で読んで格納、UI への表示経路を他設定と揃える。
        if noFilter {
            let capturedIndex = index
            let capturedGid = meta.gid
            Task.detached(priority: .userInitiated) {
                guard let image = DownloadManager.shared.loadLocalImage(gid: capturedGid, page: capturedIndex) else { return }
                await MainActor.run {
                    enhancedImages[capturedIndex] = image
                }
            }
            return
        }

        // ダウンロード画像は常にフル画質 → 常にNE人物セグメンテーション適用
        let usePersonSeg = !enhanceFilterOn && !hdrOn && !useAI && !denoiseOn

        let capturedIndex = index
        let capturedGid = meta.gid
        Task.detached(priority: .userInitiated) {
            // disk I/O + WebP decode も detached へ。400 ページ gallery でスクロール中に
            // 各セルの onAppear から processPage が呼ばれても main thread を block しない。
            guard let image = DownloadManager.shared.loadLocalImage(gid: capturedGid, page: capturedIndex) else { return }
            let original = image
            var result: PlatformImage = image

            // CoreML 4x超解像
            if useAI {
                if let upscaled = await CoreMLImageProcessor.shared.process(result) {
                    result = upscaled
                }
            }

            // モード別CIFilter処理
            if mode == 2 {
                result = LanczosUpscaler.shared.enhanceUltimate(result) ?? result
            } else if mode >= 1 {
                result = LanczosUpscaler.shared.sharpenOnly(result) ?? result
            }

            // ノイズ除去
            if denoiseOn {
                result = ReaderViewModel.applyDenoiseStatic(result) ?? result
            }

            // 画像補正フィルタ
            if enhanceFilterOn {
                result = LanczosUpscaler.shared.enhanceFilter(result) ?? result
            }

            // HDR排他
            if hdrOn && !enhanceFilterOn {
                result = HDREnhancer.shared.enhance(result) ?? result
            }

            // NE人物セグメンテーション（常時適用、他フィルタ未使用時）
            #if canImport(UIKit)
            if usePersonSeg {
                if let enhanced = LanczosUpscaler.shared.applyPersonSegmentation(result) {
                    result = enhanced
                }
            }
            #endif

            // 安全チェック
            if result.cgImage == nil { result = original }

            await MainActor.run {
                enhancedImages[capturedIndex] = result
            }
        }
    }

    // MARK: - ページセル

    private var isHorizontal: Bool { effectiveDirection == 1 }

    @ViewBuilder
    private func localPageCell(index: Int) -> some View {
        #if canImport(UIKit)
        // アニメGIF/WebP: 再生方式は animPlaybackMode で分岐。
        //   "webp": CGImageSource + CADisplayLink 逐次再生 (Boomerang 対応、変換なし)
        //   "mp4" : 旧来 HEVC MP4 変換 + AVPlayer (HDR 全域対応、▶ 手動再生)
        let fileURL = DownloadManager.shared.imageFilePath(gid: meta.gid, page: index)
        // 田中判断 2026-04-26 final: external_zip は scan flag が信頼できない (post-DL scan が
        // false 返してても実際は動画 WebP の場合あり) → 常に animated render 試行 (BoomerangWebPView が
        // static にも fallback する)。internal DL は scan 済 flag を信頼 (post-DL scan reliable)、
        // 未 scan のみ legacy isAnimatedFile fallback。
        let isAnimated: Bool = {
            // external_zip は gallery-level scan flag が不正確なので per-page で実ファイル判定。
            if meta.source == "external_zip" {
                return AnimatedImageDecoder.isAnimatedFile(url: fileURL)
            }
            // 田中要望 2026-05-01: 混在作品 (動画 + 静画) で静画ページにも ▶ 付く問題対応。
            // gallery-level `hasAnimatedWebp` は「1 ページでも動画があれば true」のフラグなので
            // internal DL の混在作品では静画ページにも ▶ が出てしまう (再発)。
            // hasAnimatedWebp == false (全ページ静画) ならショートサーキット可、
            // それ以外 (混在 or 全動画 or 未 scan) は per-page で実ファイル判定。
            if meta.hasAnimatedWebp == false { return false }
            return AnimatedImageDecoder.isAnimatedFile(url: fileURL)
        }()
        if FileManager.default.fileExists(atPath: fileURL.path), isAnimated {
            if animPlaybackMode == "mp4" {
                // staticImage は enhancedImages のみ参照 (sync loadLocalImage は動画 WebP の
                // 全フレーム展開で main thread 14秒級に固まるため使わない)。processPage 完了で nil → 画像。
                GalleryAnimatedWebPView(
                    source: .url(fileURL),
                    staticImage: enhancedImages[index],
                    gid: meta.gid,
                    page: index,
                    onToggleControls: {
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    },
                    autoPlayIfActive: currentIndex == index,
                    isHDREnabled: storedHDR
                )
                .frame(maxWidth: .infinity, maxHeight: isHorizontal ? .infinity : nil, alignment: isHorizontal ? .center : .top)
                .onAppear {
                    if enhancedImages[index] == nil { processPage(index) }
                }
            } else {
                // 400 ページスクロールで ?? DownloadManager.shared.loadLocalImage が
                // main thread で sync disk 読込+decode → 累積で重くなる元凶。
                // 非同期 processPage の結果 (enhancedImages[index]) が入るまで nil で OK、
                // BoomerangWebPView 内は Color.clear + aspectRatio で placeholder 表示される。
                BoomerangWebPView(
                    sourceURL: fileURL,
                    readerID: "local-\(meta.gid)",
                    pageIndex: index,
                    staticPlaceholder: enhancedImages[index]
                )
                .frame(maxWidth: .infinity, maxHeight: isHorizontal ? .infinity : nil, alignment: isHorizontal ? .center : .top)
                .onAppear {
                    if enhancedImages[index] == nil { processPage(index) }
                }
            }
        } else {
            animatedOrStaticBody(index: index)
        }
        #else
        animatedOrStaticBody(index: index)
        #endif
    }

    @ViewBuilder
    private func animatedOrStaticBody(index: Int) -> some View {
        // 静画ジャンプ freeze fix (2026-04-26): sync `loadLocalImage` を View body から削除。
        // LRU 直後等で enhancedImages[index] が nil の時、main で UIImage(contentsOfFile:) +
        // WebP decode が走り 14 秒級フリーズしてた。動画経路 (Boomerang/GalleryAnimatedWebPView)
        // は staticPlaceholder=nil で Color.clear fallback する設計と揃える。
        // processPage が detached で完了 → enhancedImages 更新 → 再描画で実画像表示。
        if let displayImage = enhancedImages[index] {
            Image(platformImage: displayImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: isHorizontal ? .infinity : nil, alignment: isHorizontal ? .center : .top)
                .contentShape(Rectangle())
                .onTapGesture { if verticalSizeClass == .regular { zoomImage = displayImage } }
                .onAppear {
                    if enhancedImages[index] == nil {
                        processPage(index)
                    }
                }
                .onDisappear {
                    if abs(index - currentIndex) > 10 {
                        enhancedImages.removeValue(forKey: index)
                    }
                }
        } else if isLiveDownload && !availablePages.contains(index) {
            // ダウンロード中のページ
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)
                Text("ページ \(index + 1) をダウンロード中...")
                    .font(.caption)
                    .foregroundStyle(.gray)
                if let progress = downloadManager.activeDownloads[meta.gid] {
                    Text("\(progress.current) / \(progress.total)")
                        .font(.caption2)
                        .foregroundStyle(.gray.opacity(0.6))
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: isHorizontal ? .infinity : nil, alignment: .center)
            .frame(minHeight: 300)
        } else if FileManager.default.fileExists(atPath: DownloadManager.shared.imageFilePath(gid: meta.gid, page: index).path)
                  || ExternalCortexZipReader.shared.isExternalGallery(gid: meta.gid) {
            // 静画ジャンプ freeze fix: enhancedImages 未充填時は placeholder 表示 + processPage trigger。
            // sync UIImage(contentsOfFile:) を main から外して main thread を解放する。
            Color.clear
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: isHorizontal ? .infinity : nil, alignment: isHorizontal ? .center : .top)
                .frame(minHeight: 300)
                .onAppear {
                    if enhancedImages[index] == nil { processPage(index) }
                }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("ページ \(index + 1) が見つかりません")
                    .font(.caption)
                    .foregroundStyle(.gray)
                Button {
                    DownloadManager.shared.retryMissingPages(gid: meta.gid)
                } label: {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                        .font(.footnote.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(DownloadManager.shared.activeDownloadCount > 0 && DownloadManager.shared.downloads[meta.gid] != nil && DownloadManager.shared.downloads[meta.gid]?.isComplete == false)
            }
            .frame(maxWidth: .infinity, maxHeight: isHorizontal ? .infinity : nil, alignment: .center)
            .frame(minHeight: 300)
        }
    }

    // MARK: - 画質設定パネル

    private var downloadFilterPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline)
                Text("画質設定")
                    .font(.subheadline.bold())
                Spacer()
            }
            .foregroundStyle(.white)

            Toggle("無補正モード", isOn: $storedNoFilter)
                .font(.subheadline)
                .tint(.green)

            if !storedNoFilter {
                VStack(alignment: .leading, spacing: 4) {
                    Text("画質モード")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Picker("画質モード", selection: $storedDlMode) {
                        Text("標準").tag(0)
                        Text("フィルタ").tag(1)
                        Text("究極画質").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("画像補正フィルタ", isOn: $storedEnhanceFilter)
                    .font(.subheadline)
                    .tint(.blue)

                HStack {
                    Toggle("HDR風補正（カラー作品推奨）", isOn: $storedHDR)
                        .font(.subheadline)
                        .tint(.blue)
                    if storedEnhanceFilter {
                        Text("(HDR統合済み)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Toggle("ノイズ除去", isOn: $storedDenoise)
                    .font(.subheadline)
                    .tint(.blue)

                Toggle("AI超解像", isOn: $storedAI)
                    .font(.subheadline)
                    .tint(.blue)
            }

            // 田中要望 2026-07-11: アプリ設定から移設。再生挙動なので無補正モードとは独立。
            Toggle("繰り返し再生 (Boomerang)", isOn: $boomerangMode)
                .font(.subheadline)
                .tint(.purple)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .foregroundStyle(.white)
    }

    private var localSpreadLabel: String {
        let page = isSliding ? Int(sliderValue) : currentIndex
        if isHorizontal {
            return PagedReaderView.spreadPageLabel(
                currentPage: page,
                totalPages: meta.pageCount,
                readingOrder: readingOrder,
                imageForPage: { enhancedImages[$0] ?? DownloadManager.shared.loadLocalImage(gid: meta.gid, page: $0) }
            )
        }
        return "\(page + 1) / \(meta.pageCount)"
    }

    // MARK: - コントロール

    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button {
                    LogManager.shared.log("Tap", "local dismiss: close-button")
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(meta.title)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                if !EcoMode.shared.isEnabled {
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
            }
            .padding()
            .background(.ultraThinMaterial.opacity(0.8))

            Spacer()

            VStack(spacing: 6) {
                if meta.pageCount > 1 {
                    Slider(
                        value: $sliderValue,
                        in: 0...Double(max(meta.pageCount - 1, 1)),
                        step: 1
                    ) { editing in
                        // 診断 2026-07-02: 幽霊 editing(true) の発火順序を実証するためのログ
                        LogManager.shared.log("iPadScroll", "Local slider editing=\(editing)")
                        lastSliderActivity = Date()
                        isSliding = editing
                        if editing {
                            withAnimation(.easeIn(duration: 0.15)) {
                                showPageOverlay = true
                                seekPreviewVisible = true   // Phase R-6: プレビュー常駐表示
                            }
                            loadSeekThumbs(around: Int(sliderValue))  // Phase R-6
                        } else {
                            if isHorizontal {
                                horizontalPage = Int(sliderValue)
                            } else {
                                sliderJumpTarget = Int(sliderValue)
                            }
                            // Phase R-6: 離してもプレビューは残す (左右タップ移動 / 外側タップで閉じる)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    showPageOverlay = false
                                }
                            }
                        }
                    }
                    .tint(.white)
                    .padding(.horizontal)
                    .environment(\.layoutDirection, readingOrder == 1 && isHorizontal ? .rightToLeft : .leftToRight)
                    .onChange(of: sliderValue) { _, nv in
                        if isSliding {
                            lastSliderActivity = Date()
                            loadSeekThumbs(around: Int(nv))  // Phase R-6
                        }
                    }
                }

                HStack {
                    Button {
                        showPageJump = true
                    } label: {
                        Text(localSpreadLabel)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if isLiveDownload, let progress = downloadManager.activeDownloads[meta.gid] {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(.orange)
                            Text("\(progress.current)/\(progress.total)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .monospacedDigit()
                        }
                    } else {
                        Text("オフライン")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
            .background(.ultraThinMaterial.opacity(0.8))
        }
    }

    // MARK: - Jump pre-cache (Phase E1.B 後追加, 田中指示 2026-04-26)
    //
    // 外部参照 ZIP gallery で slider 大幅 jump 時、target ± N ページを background で
    // materialize → 完了で実 scroll 実行。pre-cache 中は overlay 表示 (タップで cancel)。
    // 内部 DL gallery には影響させない (source == "external_zip" 限定)。

    private func startJumpPreCache(target: Int, onCompleted: @escaping () -> Void) {
        // 田中要望 2026-04-26: 静画 (internal DL) の jump も重いから loading 表示。
        // - external_zip: ZIP entry を materialize (NAS SMB IO)
        // - internal DL: loadLocalImage で disk 読込 + WebP decode (大画像で重い)
        // どちらも background で済ませてから scroll、loading overlay 共通表示。
        let isExternal = (meta.source == "external_zip")
        let lo = max(0, target - 1)
        let hi = min(meta.pageCount, target + (isExternal ? 3 : 2))
        let total = hi - lo
        guard total > 0 else { onCompleted(); return }

        jumpPreCacheActive = true
        jumpPreCacheCurrent = 0
        jumpPreCacheTotal = total
        let gid = meta.gid

        Task.detached(priority: .userInitiated) {
            // 各 page を並列 materialize、完了順で progress 更新。
            // 直列だと 5 ページ × SMB IO で 10〜25 秒級になるため。
            await withTaskGroup(of: Void.self) { group in
                for page in lo..<hi {
                    group.addTask {
                        if isExternal {
                            _ = ExternalCortexZipReader.shared.materializedImageURL(gid: gid, page: page)
                        } else {
                            _ = DownloadManager.shared.loadLocalImage(gid: gid, page: page)
                        }
                    }
                }
                var done = 0
                for await _ in group {
                    done += 1
                    let snapshot = done
                    await MainActor.run {
                        if jumpPreCacheActive {
                            jumpPreCacheCurrent = snapshot
                        }
                    }
                }
            }
            await MainActor.run {
                // internal DL: filter pipeline を target page 分だけ trigger (背景で processPage 走る)
                if !isExternal && enhancedImages[target] == nil {
                    processPage(target)
                }
                if jumpPreCacheActive {
                    jumpPreCacheActive = false
                    onCompleted()
                }
                // cancel 済 (jumpPreCacheActive == false) なら scroll しない、background cache だけ完了
            }
        }
    }

    @ViewBuilder
    private var jumpPreCacheOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture {
                    // cancel: overlay 消す + scroll 中止 (background materialize は完走、cache は populate)
                    jumpPreCacheActive = false
                }
            VStack(spacing: 16) {
                ProgressView(value: Double(jumpPreCacheCurrent), total: Double(max(1, jumpPreCacheTotal)))
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text("ジャンプ先を準備中... \(jumpPreCacheCurrent) / \(jumpPreCacheTotal)")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text("タップでキャンセル")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(24)
            .background(Color.black.opacity(0.7))
            .cornerRadius(12)
        }
    }
}

/// iPad 限定の scroll 位置追跡用 PreferenceKey。
/// LazyVStack の各セルから GeometryReader 経由で自 index → midY マップを親に通知、
/// 画面中央に最も近いセルを currentIndex に反映する目的。
struct PagePositionKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
