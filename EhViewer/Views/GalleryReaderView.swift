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
    @AppStorage("readerDirection") private var readerDirection = 0 // 0:縦, 1:横
    @AppStorage("readingOrder") private var readingOrder = 1 // 0:左綴じ, 1:右綴じ
    @State private var horizontalPage: Int = 0
    @State private var showAutoSavePrompt = false
    @State private var autoSaveInfo: (saved: Int, total: Int) = (0, 0)
    @AppStorage("autoSaveOnRead") private var autoSaveOnRead = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(gallery: Gallery, host: GalleryHost, initialPage: Int = 0, thumbnails: [ThumbnailInfo] = []) {
        self.gallery = gallery
        self.host = host
        self._viewModel = StateObject(wrappedValue: ReaderViewModel(gallery: gallery, host: host, initialPage: initialPage, thumbnails: thumbnails))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if readerDirection == 0 {
                verticalReader
            } else {
                horizontalReader
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
            if zoomImage == nil && readerDirection == 0 {
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
                    if readerDirection == 1 {
                        TipView(ReaderSwipeDismissTip(), arrowEdge: .bottom)
                        TipView(HorizontalReaderTip(), arrowEdge: .bottom)
                    }
                    if readerDirection == 1 && readingOrder == 1 {
                        TipView(RTLSliderTip(), arrowEdge: .bottom)
                    }
                    if UIDevice.current.userInterfaceIdiom == .pad && readerDirection == 1 {
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
            // TipKit パラメータ更新
            RTLSliderTip.isRTLMode = (readingOrder == 1 && readerDirection == 1)
            AutoSaveTip.autoSaveEnabled = autoSaveOnRead

            await viewModel.loadImagePages()
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(viewModel.initialPage, anchor: .top)
                    }
                }
            }
            .onAppear {
                if viewModel.initialPage > 0 && viewModel.totalPages > viewModel.initialPage {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        proxy.scrollTo(viewModel.initialPage, anchor: .top)
                    }
                }
            }
            .onChange(of: viewModel.scrollTarget) { _, target in
                if let target {
                    withAnimation {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    viewModel.scrollTarget = nil
                }
            }
            .onChange(of: viewModel.currentIndex) { _, newIndex in
                if !isSliding {
                    sliderValue = Double(newIndex)
                    if readerDirection == 1 { horizontalPage = newIndex }
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
            isHorizontalMode: readerDirection == 1,
            isActiveAnimation: index == viewModel.currentIndex,
            mp4Gid: gallery.gid
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
            isHorizontalMode: readerDirection == 1
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
                Toggle("HDR風補正", isOn: $hdrEnhancement)
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
        let page = isSliding ? Int(sliderValue) : (readerDirection == 1 ? horizontalPage : viewModel.currentIndex)
        if readerDirection == 1 { // 横モード
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
                            if readerDirection == 1 {
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
                    .environment(\.layoutDirection, readingOrder == 1 && readerDirection == 1 ? .rightToLeft : .leftToRight)
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
