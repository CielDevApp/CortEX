import SwiftUI
import TipKit

struct LocalReaderView: View {
    let meta: DownloadedGallery
    var isLiveDownload: Bool = false

    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var showPageJump = false
    @State private var jumpPageText = ""
    @State private var currentIndex = 0
    @State private var dragOffset: CGFloat = 0
    @State private var zoomImage: PlatformImage?
    @State private var sliderValue: Double = 0
    @State private var isSliding = false
    @State private var sliderJumpTarget: Int?
    @State private var showPageOverlay = false
    @State private var enhancedImages: [Int: PlatformImage] = [:]
    @State private var showFilterPanel = false
    @State private var reprocessTrigger = 0
    @State private var availablePages: Set<Int> = []
    @State private var pageCheckTimer: Timer?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("downloadQualityMode") private var storedDlMode = 2
    @AppStorage("imageEnhanceFilter") private var storedEnhanceFilter = false
    @AppStorage("hdrEnhancement") private var storedHDR = false
    @AppStorage("aiImageProcessing") private var storedAI = false
    @AppStorage("denoiseEnabled") private var storedDenoise = false
    @AppStorage("noFilterMode") private var storedNoFilter = false
    @AppStorage("readerDirection") private var readerDirection = 0
    @AppStorage("readingOrder") private var readingOrder = 1
    @State private var horizontalPage: Int = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if readerDirection == 0 {
                verticalReader
            } else {
                localHorizontalReader
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
                                    dismiss()
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
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
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
            if isLiveDownload {
                scanAvailablePages()
                startPageCheckTimer()
            }
        }
        .onDisappear {
            pageCheckTimer?.invalidate()
            pageCheckTimer = nil
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
            if changed && readerDirection == 1 {
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
                if enhancedImages[index] == nil { processPage(index) }
            },
            onDismiss: { dismiss() },
            onZoomImage: { img in zoomImage = img }
        )
        .id(reprocessTrigger)
        .ignoresSafeArea()
        .onChange(of: horizontalPage) { _, newPage in
            currentIndex = newPage
            if !isSliding { sliderValue = Double(newPage) }
        }
        .onChange(of: Int(sliderValue)) {
            #if canImport(UIKit)
            if isSliding {
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
                    horizontalPage = page - 1
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
                            .onAppear { currentIndex = index }
                    }
                }
            }
            .onChange(of: currentIndex) { _, newIndex in
                if !isSliding {
                    sliderValue = Double(newIndex)
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
                        withAnimation {
                            proxy.scrollTo(page - 1, anchor: .top)
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
                    proxy.scrollTo(target, anchor: .top)
                    sliderJumpTarget = nil
                }
            }
        }
    }

    // MARK: - 画質再処理

    /// 設定変更時に表示中ページを再処理
    private func reprocessVisiblePages() {
        enhancedImages.removeAll()
        reprocessTrigger += 1
        let center = currentIndex
        let lo = max(0, center - 2)
        let hi = min(meta.pageCount - 1, center + 2)
        for i in lo...hi {
            processPage(i)
        }
    }

    /// ページを現在の設定で処理してenhancedImagesに格納
    private func processPage(_ index: Int) {
        // ECOモード: フィルタ全スキップ
        if EcoMode.shared.isEnabled { return }

        guard let image = DownloadManager.shared.loadLocalImage(gid: meta.gid, page: index) else { return }
        let mode = storedDlMode
        let enhanceFilterOn = storedEnhanceFilter
        let hdrOn = storedHDR
        let useAI = storedAI && CoreMLImageProcessor.shared.modelAvailable
        let denoiseOn = storedDenoise
        let noFilter = storedNoFilter

        // 無補正モード
        if noFilter { return }

        // ダウンロード画像は常にフル画質 → 常にNE人物セグメンテーション適用
        let usePersonSeg = !enhanceFilterOn && !hdrOn && !useAI && !denoiseOn

        let capturedIndex = index
        Task.detached(priority: .utility) {
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

    private var isHorizontal: Bool { readerDirection == 1 }

    @ViewBuilder
    private func localPageCell(index: Int) -> some View {
        let displayImage = enhancedImages[index] ?? DownloadManager.shared.loadLocalImage(gid: meta.gid, page: index)
        if let displayImage {
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
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("ページ \(index + 1) が見つかりません")
                    .font(.caption)
                    .foregroundStyle(.gray)
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
                    Toggle("HDR風補正", isOn: $storedHDR)
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
                        isSliding = editing
                        if editing {
                            withAnimation(.easeIn(duration: 0.15)) {
                                showPageOverlay = true
                            }
                        } else {
                            if isHorizontal {
                                horizontalPage = Int(sliderValue)
                            } else {
                                sliderJumpTarget = Int(sliderValue)
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
                    .environment(\.layoutDirection, readingOrder == 1 && isHorizontal ? .rightToLeft : .leftToRight)
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
}
