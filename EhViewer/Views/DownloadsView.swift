import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    /// Phase E1 (2026-04-26): 外部参照フォルダ配下の作品リスト (Mac Catalyst のみ表示)。
    @ObservedObject private var externalFolders = ExternalFolderManager.shared
    @State private var externalUnsupportedAlert: String?
    @State private var exportShareItem: ShareableURL?
    @State private var showImportPicker = false
    @State private var importMessage: String?
    @State private var highlightedGid: Int?
    @State private var readerMeta: DownloadedGallery?
    @State private var liveReaderMeta: DownloadedGallery?
    @State private var tabBarHidden = false
    /// 長押しプレビュー表示中のギャラリー（nil = 非表示）
    @State private var previewMeta: DownloadedGallery?
    /// 「この作品のページ詳細を見る」で開く DetailView 用 (nil = 非表示)。
    /// 田中指示 2026-04-25: 保存済み作品から server 詳細 (キャラ名/タグ等) を閲覧する経路。
    @State private var detailMeta: DownloadedGallery?
    /// Phase E1.B 後追加 (2026-04-26): 外部参照 ZIP gallery を Reader 開く前に
    /// budget (4GB or 全 pages) まで background pre-cache → Reader 起動後 SMB IO 0。
    /// 田中案 2026-04-26: cache 容量を完全に使い切ってから開く方針。
    @State private var preCacheMeta: DownloadedGallery?
    @State private var preCacheCurrent: Int = 0
    @State private var preCacheTotal: Int = 0
    @State private var preCacheBytesDone: UInt64 = 0
    @State private var preCacheBytesTotal: UInt64 = 0
    @State private var preCacheCancelled: Bool = false
    /// β-1 (2026-04-26): 外部参照 ZIP background materialize 完了通知でセル再描画 trigger
    @State private var externalCortexReadyCounter: Int = 0
    /// プレビューからリーダー起動する時の初期ページ（通常起動では 0）
    @State private var readerInitialPage: Int = 0
    /// エクスポート進行フェーズ（nil = idle）。
    /// - processing: ZIP streaming 中、進捗バー表示
    /// - preparingSheet: 100% 完了、iOS ActivityViewController 準備中（失敗と錯覚しないよう明示表示）
    @State private var exportPhase: ExportPhase?
    /// エクスポートエラーメッセージ（nil = 成功 or idle）。Alert 表示用。
    @State private var exportError: String?

    /// 田中要望 2026-04-28: NAS 転送中の overlay を「バックグラウンドで実行」で隠す機能。
    /// 隠した gid を保持し、同 gid の transfer 中は再表示しない。新規 transfer (異なる gid) は表示。
    @State private var hiddenTransferGid: Int?

    /// 田中要望 2026-04-27: 「保存済み」section のソート方式 (全プラットフォーム共通)。
    /// 外部参照側 (Mac Catalyst のみ) は ExternalFolderManager 側で独立管理、enum は共有。
    @AppStorage("downloadsCompletedSortOrderRaw") private var completedSortOrderRaw: String = ExternalFolderManager.ExternalSortOrder.dateAdded.rawValue
    private var completedSortOrder: ExternalFolderManager.ExternalSortOrder {
        get { ExternalFolderManager.ExternalSortOrder(rawValue: completedSortOrderRaw) ?? .dateAdded }
    }

    private var activeList: [(gid: Int, progress: DownloadManager.DownloadProgress)] {
        manager.activeDownloads.sorted(by: { $0.key < $1.key }).map { (gid: $0.key, progress: $0.value) }
    }

    /// 田中要望 2026-04-26: 外部参照を「一覧から削除した gid」と「ソート順」でフィルタ + sort。
    private var visibleSortedExternal: [DownloadedGallery] {
        let visible = externalFolders.externalGalleries
            .filter { !externalFolders.hiddenExternalGids.contains($0.gid) }
        switch externalFolders.externalSortOrder {
        case .dateAdded:
            return visible.sorted { $0.downloadDate > $1.downloadDate }
        case .nameAsc:
            return visible.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .nameDesc:
            return visible.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
    }

    private var completedList: [DownloadedGallery] {
        // 田中要望 2026-04-26: Mac で DL 保存先が外部 (NAS 等) に設定されている場合、
        // 同作品が「外部参照」section にも (別 gid で) 表示されて重複するため
        // 「保存済み」section は非表示。DL 保存先を default に戻すと再表示。
        #if targetEnvironment(macCatalyst)
        if externalFolders.activeDLSaveDestinationURL != nil {
            return []
        }
        #endif
        let filtered = manager.downloads.values.filter { $0.isComplete }
        switch completedSortOrder {
        case .dateAdded:
            return filtered.sorted { $0.downloadDate > $1.downloadDate }
        case .nameAsc:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .nameDesc:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
    }

    private var incompleteList: [DownloadedGallery] {
        manager.downloads.values
            .filter { !$0.isComplete && manager.activeDownloads[$0.gid] == nil }
            .sorted(by: { $0.downloadDate > $1.downloadDate })
    }

    var body: some View {
        NavigationStack {
            List {
                // ダウンロード中
                if !activeList.isEmpty {
                    Section("ダウンロード中") {
                        ForEach(activeList, id: \.gid) { item in
                            downloadingRow(gid: item.gid, progress: item.progress)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let meta = manager.downloads[item.gid] {
                                        liveReaderMeta = meta
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        manager.cancelDownload(gid: item.gid)
                                    } label: {
                                        Label("ダウンロード中止", systemImage: "stop.circle")
                                    }
                                    Button(role: .destructive) {
                                        manager.cancelDownload(gid: item.gid)
                                        manager.deleteDownload(gid: item.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }

                // ダウンロード済み
                if !completedList.isEmpty {
                    Section {
                        ForEach(completedList) { meta in
                            completedRow(meta: meta)
                                .contextMenu {
                                    Button {
                                        previewMeta = meta
                                    } label: {
                                        Label("プレビュー表示", systemImage: "rectangle.grid.3x2")
                                    }
                                    Button {
                                        detailMeta = meta
                                    } label: {
                                        Label("この作品のページ詳細を見る", systemImage: "doc.text.magnifyingglass")
                                    }
                                    Button {
                                        performExport(meta: meta)
                                    } label: {
                                        Label("エクスポート", systemImage: "square.and.arrow.up")
                                    }
                                    .disabled(exportPhase != nil)
                                    Button(role: .destructive) {
                                        manager.deleteDownload(gid: meta.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        manager.deleteDownload(gid: meta.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        // 田中要望 2026-04-27: 「保存済み」section にソート Menu (全プラットフォーム)
                        HStack {
                            Text("保存済み (\(completedList.count))")
                            Spacer()
                            Menu {
                                Picker("ソート", selection: Binding(
                                    get: { completedSortOrder },
                                    set: { completedSortOrderRaw = $0.rawValue }
                                )) {
                                    Text("追加日順").tag(ExternalFolderManager.ExternalSortOrder.dateAdded)
                                    Text("名前昇順").tag(ExternalFolderManager.ExternalSortOrder.nameAsc)
                                    Text("名前降順").tag(ExternalFolderManager.ExternalSortOrder.nameDesc)
                                }
                            } label: {
                                Label("ソート", systemImage: "arrow.up.arrow.down.circle")
                                    .labelStyle(.iconOnly)
                            }
                        }
                    }
                }

                // Phase E1 (2026-04-26): 外部参照フォルダ配下の作品 (Mac Catalyst のみ)
                #if targetEnvironment(macCatalyst)
                if !externalFolders.disconnectedFolderIDs.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("NAS 未接続: \(externalFolders.disconnectedFolderIDs.count) 件のフォルダにアクセス不可")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !visibleSortedExternal.isEmpty {
                    Section {
                        // 田中要望 2026-04-26: cover pre-warm 中なら header に進捗表示
                        if externalFolders.isWarmingCovers {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("読み込み中... \(externalFolders.warmCoverCurrent) / \(externalFolders.warmCoverTotal)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(visibleSortedExternal) { meta in
                            externalRow(meta: meta)
                        }
                    } header: {
                        // 田中要望 2026-04-26: ソート Menu (追加日 / 名前 昇降)
                        HStack {
                            Text("外部参照 (\(visibleSortedExternal.count))")
                            Spacer()
                            Menu {
                                Picker("ソート", selection: Binding(
                                    get: { externalFolders.externalSortOrder },
                                    set: { externalFolders.externalSortOrder = $0 }
                                )) {
                                    Text("追加日順").tag(ExternalFolderManager.ExternalSortOrder.dateAdded)
                                    Text("名前昇順").tag(ExternalFolderManager.ExternalSortOrder.nameAsc)
                                    Text("名前降順").tag(ExternalFolderManager.ExternalSortOrder.nameDesc)
                                }
                            } label: {
                                Label("ソート", systemImage: "arrow.up.arrow.down.circle")
                                    .labelStyle(.iconOnly)
                            }
                        }
                    }
                }
                #endif

                // 未完了
                if !incompleteList.isEmpty {
                    Section {
                        ForEach(incompleteList) { meta in
                            incompleteRow(meta: meta)
                                .contextMenu {
                                    Button {
                                        manager.markAsCompleteIgnoringMissing(gid: meta.gid)
                                    } label: {
                                        Label("強制完了（欠落ページを無視）", systemImage: "checkmark.circle")
                                    }
                                    Button(role: .destructive) {
                                        manager.deleteDownload(gid: meta.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        manager.deleteDownload(gid: meta.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("未完了")
                            Spacer()
                            Button {
                                manager.resumeAllIncomplete()
                            } label: {
                                Label("すべて再開", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                        }
                    }
                }

                if manager.downloads.isEmpty && manager.activeDownloads.isEmpty {
                    ContentUnavailableView {
                        Label("保存済みギャラリーがありません", systemImage: "arrow.down.circle")
                    } description: {
                        Text("ギャラリー詳細画面からダウンロードできます")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            // 田中要望 2026-04-26: ライブラリ pull-to-refresh で外部参照フォルダ rescan。
            // staging → NAS bulk move 完了後、新しい gallery を即取得可能。
            .refreshable {
                await externalFolders.rescanAll()
            }
            .navigationTitle("ライブラリ")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(tabBarHidden ? .hidden : .visible, for: .tabBar)
            .animation(.smooth(duration: 0.25), value: tabBarHidden)
            #endif
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { oldVal, newVal in
                let delta = newVal - oldVal
                if abs(delta) > 100 { return }
                if delta > 8 { tabBarHidden = true }
                else if delta < -5 { tabBarHidden = false }
            }
            .toolbar {
                // 田中要望 2026-04-28: NAS 転送中の mini indicator (バックグラウンド時のみ表示)。
                // タップで overlay 再表示。転送自体は overlay 表示と無関係に進行する。
                if let t = manager.currentTransfer, t.gid == hiddenTransferGid {
                    ToolbarItem(placement: .automatic) {
                        transferMiniIndicator(transfer: t)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showImportPicker = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            // DL 進行中かつ保存済みタブ表示中は画面スリープ防止。
            // タブ離脱 or DL 全完了で即復帰 (isIdleTimerDisabled=false)。
            #if os(iOS)
            .onChange(of: manager.activeDownloadCount, initial: true) { _, newCount in
                let shouldHold = newCount > 0
                if UIApplication.shared.isIdleTimerDisabled != shouldHold {
                    UIApplication.shared.isIdleTimerDisabled = shouldHold
                    LogManager.shared.log("App", "idleTimerDisabled=\(shouldHold) (activeDownloads=\(newCount))")
                }
            }
            .onDisappear {
                if UIApplication.shared.isIdleTimerDisabled {
                    UIApplication.shared.isIdleTimerDisabled = false
                    LogManager.shared.log("App", "idleTimerDisabled=false (tab left)")
                }
            }
            #endif
            .fileImporter(
                isPresented: $showImportPicker,
                allowedContentTypes: [.zip, .archive, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    // 大容量 ZIP の main thread ブロック回避のため background 実行
                    importMessage = "インポート中..."
                    Task.detached(priority: .userInitiated) {
                        let ok = GalleryExporter.importFromZip(url: url) != nil
                        await MainActor.run {
                            importMessage = ok ? "インポート完了" : "インポート失敗"
                        }
                    }
                }
            }
            .sheet(item: $exportShareItem) { item in
                // 共有完了（AirDrop/Save to Files/キャンセル等すべて）で tmp の .cortex を削除。
                // 次の起動 or 次の export を待たずに即掃除して容量圧迫を防ぐ。
                ActivityView(activityItems: [item.url]) {
                    let url = item.url
                    try? FileManager.default.removeItem(at: url)
                    LogManager.shared.log("Export", "tmp cleanup after share: \(url.lastPathComponent)")
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $readerMeta, onDismiss: { readerInitialPage = 0 }) { meta in
                LocalReaderView(meta: meta, initialPage: readerInitialPage)
            }
            .fullScreenCover(item: $liveReaderMeta) { meta in
                LocalReaderView(meta: meta, isLiveDownload: true)
            }
            #endif
            // 「この作品のページ詳細を見る」(田中指示 2026-04-25)
            // E-Hentai/EXhentai は GalleryDetailView (host=.exhentai 固定、ログイン中前提)、
            // nhentai (gid<0) は NhentaiDetailView (stub NhGallery、サーバから refetch)。
            .sheet(item: $detailMeta) { meta in
                DetailSheetNavStack(dismiss: { detailMeta = nil }) {
                    if meta.isNhentai {
                        NhentaiDetailView(gallery: stubNhGallery(from: meta))
                    } else {
                        GalleryDetailView(gallery: stubGallery(from: meta), host: .exhentai)
                    }
                }
            }
            .overlay {
                if let m = previewMeta {
                    LocalPreviewOverlay(
                        meta: m,
                        onDismiss: { previewMeta = nil },
                        onTapPage: { page in
                            // 田中要望 2026-04-26: external_zip 以外 (internal DL / external subfolder)
                            // も pre-cache 経路に統一。non-animated WebP / 大容量 internal DL でも
                            // ensureAnimatedWebpScanned 等の主処理を background 完了させて Reader 起動。
                            readerInitialPage = page
                            previewMeta = nil
                            startPreCacheAndOpenReader(meta: m, count: 0)
                        }
                    )
                    .transition(.opacity)
                }
                if exportPhase != nil {
                    exportProgressOverlay
                }
                if let m = preCacheMeta {
                    preCacheOverlay(meta: m)
                }
                if let t = manager.currentTransfer, t.gid != hiddenTransferGid {
                    transferOverlay(transfer: t)
                }
            }
            .onChange(of: manager.currentTransfer?.gid) { _, newGid in
                // 新しい transfer が来た or transfer が終わった (nil) → hide フラグ解除
                if newGid != hiddenTransferGid { hiddenTransferGid = nil }
            }
            .alert("インポート", isPresented: .constant(importMessage != nil)) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
            .alert("エクスポート失敗", isPresented: .constant(exportError != nil)) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
            // Phase E1: 外部参照作品タップ時 (Reader 抽象化未対応で alert)
            .alert("外部参照", isPresented: .constant(externalUnsupportedAlert != nil)) {
                Button("OK") { externalUnsupportedAlert = nil }
            } message: {
                Text(externalUnsupportedAlert ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .externalCortexImageReady)) { _ in
                // β-1: cell サムネ更新 trigger (any external ZIP の materialize 完了で再描画)
                externalCortexReadyCounter += 1
            }
            .onChange(of: manager.lastImportedGid) { _, gid in
                guard let gid else { return }
                withAnimation(.easeInOut(duration: 0.4)) { highlightedGid = gid }
                // 3秒後にハイライト解除
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeOut(duration: 0.6)) { highlightedGid = nil }
                    manager.lastImportedGid = nil
                }
            }
            .onAppear {
                // タブ遷移後にハイライト開始
                if let gid = manager.lastImportedGid {
                    withAnimation(.easeInOut(duration: 0.4)) { highlightedGid = gid }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation(.easeOut(duration: 0.6)) { highlightedGid = nil }
                        manager.lastImportedGid = nil
                    }
                }
            }
        }
    }

    // MARK: - ダウンロード中の行

    @ViewBuilder
    private func downloadingRow(gid: Int, progress: DownloadManager.DownloadProgress) -> some View {
        let title = manager.downloads[gid]?.title ?? String(localized: "ダウンロード中...")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                coverThumbnail(gid: gid)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline)
                            .lineLimit(2)
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    // phase 別表示切替
                    switch progress.phase {
                    case .preparing:
                        // URL 解決中: got/expected が入ってれば具体値表示、未開始ならスピナーのみ
                        if progress.total > 0 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("URL解決中 \(progress.current)/\(progress.total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("アプリをアクティブのままにしてください")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("DL準備中…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .cooling:
                        coolingInfo(progress: progress)
                    case .active:
                        activeProgressDetails(gid: gid, progress: progress)
                    case .retrying:
                        retryingInfo(gid: gid, progress: progress)
                    }
                }
                Spacer()
                Button {
                    manager.cancelDownload(gid: gid)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            // preparing 中でも URL 解決進捗が入ってれば bar 出す（0% 張り付き対策）
            if progress.phase != .preparing || progress.total > 0 {
                ProgressView(value: progress.fraction)
                    .tint({
                        switch progress.phase {
                        case .retrying: return .orange
                        case .cooling: return .orange
                        case .preparing: return .gray
                        case .active: return .blue
                        }
                    }())
            }
        }
        .padding(.vertical, 4)
    }

    /// .active 時の詳細 (枚数/速度/ETA): 従来の UI
    @ViewBuilder
    private func activeProgressDetails(gid: Int, progress: DownloadManager.DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(progress.current) / \(progress.total) ページ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let remainingPages = max(progress.total - progress.current, 0)
                if remainingPages > 0 {
                    Text("残り\(remainingPages)枚")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let live = manager.liveDownloadedBytes(gid: gid)
                let estimated = manager.estimatedTotalBytes(gid: gid, totalPages: progress.total, currentPages: progress.current)
                let bps = BackgroundDownloadManager.shared.sampleBytesPerSecond(for: gid)
                HStack(spacing: 6) {
                    if let est = estimated, est > live {
                        let remaining = est - live
                        Text("残り ~\(formatByteSize(remaining))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.primary)
                        if bps > 0 {
                            let etaSec = Int(Double(remaining) / Double(bps))
                            Text(formatETA(etaSec))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                    if bps > 0 {
                        Text(formatSpeed(bps))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    /// .cooling 時の info + 残り秒カウントダウン (1s 毎)
    @ViewBuilder
    private func coolingInfo(progress: DownloadManager.DownloadProgress) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = max(Int((progress.coolingUntil ?? timeline.date).timeIntervalSince(timeline.date)), 0)
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("URL解決中 \(progress.current)/\(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("アプリをアクティブのままにしてください")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("BAN 回避中 残り\(remaining)秒 — 設定からセーフティ OFF で強制再開")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    /// .retrying 時の info マーク + 説明文 + 残り枚数
    @ViewBuilder
    private func retryingInfo(gid: Int, progress: DownloadManager.DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(progress.current) / \(progress.total) ページ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let remainingPages = max(progress.total - progress.current, 0)
                if remainingPages > 0 {
                    Text("残り\(remainingPages)枚")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            // 2ndpass (mirror DL) 中も 1stpass と同じ速度 / ETA 表示
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let live = manager.liveDownloadedBytes(gid: gid)
                let estimated = manager.estimatedTotalBytes(gid: gid, totalPages: progress.total, currentPages: progress.current)
                let bps = BackgroundDownloadManager.shared.sampleBytesPerSecond(for: gid)
                HStack(spacing: 6) {
                    if let est = estimated, est > live {
                        let remaining = est - live
                        Text("残り ~\(formatByteSize(remaining))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.primary)
                        if bps > 0 {
                            let etaSec = Int(Double(remaining) / Double(bps))
                            Text(formatETA(etaSec))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                    if bps > 0 {
                        Text(formatSpeed(bps))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.blue)
                    }
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("別ミラーから再試行中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - 完了済みの行

    @ViewBuilder
    private func completedRow(meta: DownloadedGallery) -> some View {
        let isHighlighted = highlightedGid == meta.gid
        Button {
            // 田中要望 2026-04-26: internal DL も pre-cache 経路に統一、ensureAnimatedWebpScanned
            // を background 完了させてから Reader 起動 (1000+ ページ初回 scan の freeze 回避)。
            startPreCacheAndOpenReader(meta: meta, count: 0)
        } label: {
            HStack(spacing: 10) {
                coverThumbnail(gid: meta.gid)
                    .overlay(alignment: .bottomTrailing) {
                        if meta.isAnimatedGallery {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.65))
                                .clipShape(Circle())
                                .padding(2)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(meta.title)
                            .font(.subheadline)
                            .lineLimit(2)
                        if isHighlighted {
                            Text("NEW")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 4) {
                        Text("\(meta.pageCount) ページ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if meta.isNhentai {
                            Text("NH")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text(meta.downloadDate, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            isHighlighted ? Color.green.opacity(0.12) : nil
        )
        .onAppear {
            // 未 scan で、かつタグからも動画判定できない作品のみバックグラウンド scan。
            // タグに "animated" を含めばその時点で確定マーク表示できるので scan 起動不要
            // (田中指示 2026-04-25 二重判定排除)。
            if meta.hasAnimatedWebp == nil && !meta.hasAnimatedTag {
                Task { await DownloadManager.shared.ensureAnimatedWebpScanned(gid: meta.gid) }
            }
        }
    }

    // MARK: - 外部参照の行 (Phase E1, 2026-04-26)
    // 外部フォルダ配下の作品。Reader 経路の抽象化 (Step 8) 未実装のため、現状タップで
    // 「リーダー対応は次フェーズ」alert を出す。サムネ表示は security-scoped resource
    // 経由で重いので Phase E1 内で別 step で対応 (今は アイコン プレースホルダ)。

    @ViewBuilder
    private func externalRow(meta: DownloadedGallery) -> some View {
        Button {
            // Phase E1.B 後追加 (2026-04-26、田中指示): 外部参照 ZIP は最初の N ページを
            // background pre-cache してから Reader を開く (main thread freeze 回避)。
            // pre-cache 済 = imageFilePath が cache hit を返す → Reader 内 SMB IO 無し。
            startPreCacheAndOpenReader(meta: meta, count: 3)
        } label: {
            HStack(spacing: 10) {
                // 田中要望 2026-04-26: サムネ表示 (cover.* or page_0001 を ZIP から materialize)
                coverThumbnail(gid: meta.gid)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title)
                        .font(.subheadline)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Text("\(meta.pageCount) ページ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("EXT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.purple)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(meta.downloadDate, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        // 田中要望 2026-04-26: 長押し (Mac 右クリック) で プレビュー / 詳細 / 一覧から削除
        // 詳細は originalGid (元 server gid) があれば有効、無ければ disabled (旧 .cortex)
        .contextMenu {
            Button {
                previewMeta = meta
            } label: {
                Label("プレビュー表示", systemImage: "rectangle.grid.3x2")
            }
            if meta.originalGid != nil {
                Button {
                    detailMeta = meta
                } label: {
                    Label("この作品のページ詳細を見る", systemImage: "doc.text.magnifyingglass")
                }
            } else {
                Button {} label: {
                    Label("ページ詳細を見る (旧 .cortex 非対応)", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(true)
            }
            // 一覧から削除 (NAS 実 .cortex は残す、表示のみ非表示)
            Button(role: .destructive) {
                externalFolders.hideExternal(gid: meta.gid)
            } label: {
                Label("一覧から削除 (NAS は残す)", systemImage: "eye.slash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                externalFolders.hideExternal(gid: meta.gid)
            } label: {
                Label("一覧から削除", systemImage: "eye.slash")
            }
        }
    }

    // MARK: - 未完了の行

    @ViewBuilder
    private func incompleteRow(meta: DownloadedGallery) -> some View {
        HStack(spacing: 10) {
            coverThumbnail(gid: meta.gid)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(meta.downloadedPages.count) / \(meta.pageCount) ページ")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button {
                let gallery = Gallery(
                    gid: meta.gid, token: meta.token,
                    title: meta.title, category: nil, coverURL: nil,
                    rating: 0, pageCount: meta.pageCount,
                    postedDate: "", uploader: nil, tags: []
                )
                manager.startDownload(gallery: gallery, host: .exhentai)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: - エクスポート処理（自前 ZIP streaming + 実進捗）

    private func performExport(meta: DownloadedGallery) {
        let gid = meta.gid
        let totalPages = meta.pageCount
        exportPhase = .processing(ExportProgress(done: 0, total: totalPages))

        Task.detached(priority: .userInitiated) {
            do {
                let url = try GalleryExporter.exportAsZipStreaming(
                    gid: gid,
                    progress: { done, total in
                        Task { @MainActor in
                            exportPhase = .processing(ExportProgress(done: done, total: total))
                        }
                    }
                )
                // 100% 到達 → シート準備中表示に切替 (iOS ActivityViewController 表示まで数秒)
                await MainActor.run { exportPhase = .preparingSheet }
                // overlay 消滅アニメと sheet 提示の同 tick 衝突回避
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run {
                    exportShareItem = ShareableURL(url: url)
                    exportPhase = nil
                }
            } catch {
                await MainActor.run {
                    exportPhase = nil
                    exportError = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private func transferOverlay(transfer: DownloadManager.TransferProgress) -> some View {
        let total = max(transfer.totalBytes, 1)
        let ratio = Double(transfer.doneBytes) / Double(total)
        return ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("NAS に転送中…")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(transfer.title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 280)
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 240)
                Text("\(formatByteSize(Int64(transfer.doneBytes))) / \(formatByteSize(Int64(transfer.totalBytes))) (\(Int(ratio * 100))%)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                // 田中要望 2026-04-28: 転送中ユーザー操作不能だったため、バックグラウンド継続ボタンを追加
                Button {
                    hiddenTransferGid = transfer.gid
                } label: {
                    Label("バックグラウンドで実行", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.top, 4)
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 12)
        }
        .transition(.opacity)
    }

    /// バックグラウンド転送中の mini indicator (toolbar item 用)。タップで overlay 再表示。
    @ViewBuilder
    private func transferMiniIndicator(transfer: DownloadManager.TransferProgress) -> some View {
        let total = max(transfer.totalBytes, 1)
        let ratio = Double(transfer.doneBytes) / Double(total)
        Button {
            hiddenTransferGid = nil  // 再表示
        } label: {
            HStack(spacing: 6) {
                ProgressView(value: ratio)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.orange)
                Text("転送中 \(Int(ratio * 100))%")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var exportProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 14) {
                switch exportPhase {
                case .processing(let progress):
                    let done = progress.done
                    let total = max(progress.total, 1)
                    let ratio = Double(done) / Double(total)
                    Text("エクスポート中…")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    ProgressView(value: ratio)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 240)
                    Text("\(done) / \(total) ページ (\(Int(ratio * 100))%)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                case .preparingSheet:
                    ProgressView()
                        .scaleEffect(1.3)
                        .tint(.white)
                    Text("共有シートを準備中…")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                case .none:
                    EmptyView()
                }
            }
            .padding(24)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 12)
        }
        .transition(.opacity)
    }

    // MARK: - 速度フォーマット

    private func formatSpeed(_ bytesPerSec: Int64) -> String {
        let b = Double(bytesPerSec)
        if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0f KB/s", b / 1_000) }
        return "\(bytesPerSec) B/s"
    }

    private func formatByteSize(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1_073_741_824 { return String(format: "%.2f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1_024 { return String(format: "%.0f KB", b / 1_024) }
        return "\(bytes) B"
    }

    // MARK: - 詳細ページ stub 生成 (田中指示 2026-04-25)
    // 保存済み作品から DetailView を開く時、DownloadedGallery に無いフィールド (rating /
    // postedDate / category / coverURL 等) は default 値で埋める。サーバ refetch で実値が入る。

    @ViewBuilder
    private func preCacheOverlay(meta: DownloadedGallery) -> some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: Double(preCacheCurrent), total: Double(max(1, preCacheTotal)))
                    .progressViewStyle(.linear)
                    .frame(width: 280)
                Text("ロード中... \(preCacheCurrent) / \(preCacheTotal) ページ")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text("\(formatMB(preCacheBytesDone)) / \(formatMB(preCacheBytesTotal))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
                Text(meta.title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("キャンセル") {
                    preCacheCancelled = true
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(24)
            .background(Color.black.opacity(0.75))
            .cornerRadius(12)
        }
    }

    private func formatMB(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Pre-cache (Phase E1.B 後追加, 田中指示 2026-04-26)
    //
    // 外部参照 ZIP gallery の最初の N ページを background materialize してから
    // Reader を開く。pre-cache 中は overlay で "準備中... K/N" 進捗表示、
    // 完了で readerMeta = meta セット → Reader 起動時には cache hit のため
    // main thread の SMB IO ブロックが発生しない。

    private func startPreCacheAndOpenReader(meta: DownloadedGallery, count: Int) {
        // 田中要望 2026-04-27: 1000+ ページ作品で precache が 401/937 ページで止まる件。
        //   旧 budget = 3.5GB / 8GB 固定 → 1112 page 動画作品 (UnityNay 10GB) の全 page
        //   が入らない。cache budget も含め SSD 空きから動的算出 (空き - 4GB headroom、
        //   上限 32GB、下限 8GB) → ExternalCortexZipReader.cacheBudget と整合。
        _ = count
        let dmFree = DownloadManager.shared.ssdFreeBytes()
        let headroom: UInt64 = 4_294_967_296  // 4GB
        let dynamic: UInt64 = dmFree > headroom ? dmFree - headroom : 0
        let cap: UInt64 = 34_359_738_368   // 32GB
        let floor: UInt64 = 8_589_934_592   // 8GB
        let budget: UInt64 = min(cap, max(floor, dynamic))

        // external_zip → ZIP entry materialize loop。それ以外 (internal DL / external subfolder) は
        // ensureAnimatedWebpScanned を background 完了させてから Reader 起動 (田中要望 2026-04-26)。
        // どちらも同じ overlay UI で「ロード中」表示、main は完全解放。
        let isExternalZip = (meta.source == "external_zip")
        let plan = isExternalZip
            ? ExternalCortexZipReader.shared.maxPagesWithinBudget(gid: meta.gid, budget: budget)
            : (pages: 1, totalBytes: UInt64(0))
        let target = max(plan.pages, 1)

        preCacheMeta = meta
        preCacheCurrent = 0
        preCacheTotal = target
        preCacheBytesDone = 0
        preCacheBytesTotal = plan.totalBytes
        preCacheCancelled = false
        let gid = meta.gid

        Task.detached(priority: .userInitiated) {
            if isExternalZip {
                for i in 0..<target {
                    let cancelled = await MainActor.run { preCacheCancelled }
                    if cancelled { break }
                    _ = ExternalCortexZipReader.shared.materializedImageURL(gid: gid, page: i)
                    let cacheURL = ExternalCortexZipReader.shared.cachedImageURL(gid: gid, page: i)
                    let pageBytes: UInt64 = {
                        guard let u = cacheURL,
                              let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
                              let s = attrs[.size] as? UInt64 else { return 0 }
                        return s
                    }()
                    await MainActor.run {
                        preCacheCurrent = i + 1
                        preCacheBytesDone += pageBytes
                    }
                }
            } else {
                // internal DL / external subfolder: ensureAnimatedWebpScanned を完了させる
                // (1000+ ページで初回 scan 数十秒 → Reader 開いてから走ると freeze)
                await DownloadManager.shared.ensureAnimatedWebpScanned(gid: gid)
                await MainActor.run { preCacheCurrent = 1 }
            }
            await MainActor.run {
                let cancelled = preCacheCancelled
                preCacheMeta = nil
                preCacheCancelled = false
                if !cancelled {
                    readerMeta = meta  // cancel じゃなければ Reader 起動
                }
            }
        }
    }

    private func stubGallery(from meta: DownloadedGallery) -> Gallery {
        // 田中要望 2026-04-26: external_zip では originalGid を優先 (元 server fetch 用)。
        // 通常 internal DL では meta.gid そのまま (originalGid は nil)。
        let serverGid = meta.originalGid ?? meta.gid
        return Gallery(
            gid: serverGid,
            token: meta.token,
            title: meta.title,
            category: nil,
            coverURL: nil,
            rating: 0,
            pageCount: meta.pageCount,
            postedDate: "",
            uploader: nil,
            tags: meta.tags ?? []
        )
    }

    private func stubNhGallery(from meta: DownloadedGallery) -> NhentaiClient.NhGallery {
        // nhentai は元 ID を originalGid (負数) → 絶対値で渡す
        let serverGid = meta.originalGid ?? meta.gid
        let id = serverGid < 0 ? -serverGid : abs(serverGid)
        return NhentaiClient.NhGallery(
            id: id,
            media_id: "",
            title: NhentaiClient.NhTitle(english: nil, japanese: meta.title, pretty: nil),
            images: nil,
            num_pages: meta.pageCount,
            tags: nil,
            thumbnailPath: nil
        )
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "約\(h)h\(m)m"
        }
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return "約\(m)分\(s)秒"
        }
        return "約\(seconds)秒"
    }

    // MARK: - カバーサムネイル

    @ViewBuilder
    private func coverThumbnail(gid: Int) -> some View {
        AsyncCoverThumbnail(gid: gid)
    }
}

// ライブラリ行の cover を main thread を塞がず非同期ロード。
// 旧実装は body 内で loadCoverImage を sync 呼出 → cache miss 時に
// fileExists + CGImageSource decode が main で走り、行数 N でフリーズ。
private struct AsyncCoverThumbnail: View {
    let gid: Int
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 50, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard image == nil else { return }
        let gid = gid
        Task.detached(priority: .userInitiated) {
            let img = DownloadManager.shared.loadCoverImage(gid: gid)
            await MainActor.run {
                self.image = img
            }
        }
    }
}

// MARK: - ヘルパー

struct ShareableURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// エクスポート進捗（SwiftUI @State 要件で Equatable 必須）
struct ExportProgress: Equatable {
    let done: Int
    let total: Int
}

/// エクスポートの段階的フェーズ。
/// 100% 到達 → `preparingSheet` で「共有シートを準備中…」を数秒表示、
/// iOS ActivityViewController の準備遅延で「失敗したかと思った」錯覚を防ぐ。
enum ExportPhase: Equatable {
    case processing(ExportProgress)
    case preparingSheet
}

#if canImport(UIKit)
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    /// activity 完了（成功 / キャンセル両方）で発火。tmp ファイル削除用。
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - 保存済みギャラリーの長押しプレビュー

/// 保存済み作品の全ページサムネグリッド。既存 GalleryPreviewOverlay / NhentaiPreviewOverlay と
/// 同じ UI 骨格だが、サムネ源がディスク画像（ネット取得 URL 不要）な点が違う。
struct LocalPreviewOverlay: View {
    let meta: DownloadedGallery
    let onDismiss: () -> Void
    /// タップされたページ index (0-indexed) を親に返す
    let onTapPage: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 6)]

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack {
                    Text(meta.title)
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
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(0..<meta.pageCount, id: \.self) { index in
                            LocalThumbCell(gid: meta.gid, index: index) {
                                onTapPage(index)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
            .frame(maxWidth: 600, maxHeight: 600)
            .padding()
        }
    }
}

/// 保存済みギャラリーの 1 ページサムネセル。
/// ディスクから CGImageSourceCreateThumbnailAtIndex で 240px 縮小し、
/// アニメ WebP なら紫枠 + ▶アイコンで識別可能にする。
struct LocalThumbCell: View {
    let gid: Int
    let index: Int
    let onTap: () -> Void

    /// セル高さ（縦長固定）。adaptive(80-120px) の列幅に対して 140 高で portrait 比率になる。
    /// 縦長/横長どちらの元画像も .aspectRatio(.fill) + .clipped() で中心クロップし統一。
    static let cellHeight: CGFloat = 140

    @State private var thumbImage: PlatformImage?
    @State private var isAnimated: Bool = false

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let img = thumbImage {
                        Image(platformImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: Self.cellHeight, maxHeight: Self.cellHeight)
                            .clipped()
                    } else {
                        Color.gray.opacity(0.2)
                            .frame(height: Self.cellHeight)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                    if isAnimated {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.cellHeight, maxHeight: Self.cellHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if isAnimated {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.purple, lineWidth: 2)
                    }
                }

                Text("\(index + 1)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .buttonStyle(.plain)
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        guard thumbImage == nil else { return }
        let url = DownloadManager.shared.imageFilePath(gid: gid, page: index)
        Task.detached(priority: .userInitiated) {
            let animated = WebPFileDetector.isAnimatedWebP(url: url)
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 240
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                await MainActor.run { self.isAnimated = animated }
                return
            }
            #if canImport(UIKit)
            let img = UIImage(cgImage: cg)
            #else
            let img = NSImage(cgImage: cg, size: .zero)
            #endif
            await MainActor.run {
                self.thumbImage = img
                self.isAnimated = animated
            }
        }
    }
}

/// ライブラリ → 作品詳細 sheet 用の NavigationStack ラッパー。
/// FavoritesView と同じく navPathBox + Gallery/NhGallery destination 一式を備え、
/// タグ検索結果からの作品タップで詳細を push できるようにする。
private struct DetailSheetNavStack<Content: View>: View {
    var dismiss: () -> Void
    @ViewBuilder var content: () -> Content
    @StateObject private var navPathBox = NavigationPathBox()

    var body: some View {
        NavigationStack(path: $navPathBox.path) {
            content()
                .navigationDestination(for: Gallery.self) { gallery in
                    GalleryDetailView(gallery: gallery, host: .exhentai)
                }
                .navigationDestination(for: NhentaiClient.NhGallery.self) { nh in
                    NhentaiDetailView(gallery: nh)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる", action: dismiss)
                    }
                }
        }
        .environment(\.navPathBox, navPathBox)
    }
}
