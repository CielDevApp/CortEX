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
    /// タイル起動=左右モード (forcedDirection=1) は 2026-07-21 深夜に田中裁定で撤回:
    /// 「静止画をリストのサムネから開くと縦設定なのに横で開く」= 設定より強制が勝つのは誤り。
    /// タイル起動も readerDirection 設定に従う。forcedDirection の配管は残すが常に nil。
    @State private var readerForcedDirection: Int? = nil
    /// タイルタップ = 明示ページ指定の印 (ページ0タイルでも再開プロンプトを出さないため)。
    @State private var readerExplicitPage = false
    @ViewBuilder
    private func readerCover(_ meta: DownloadedGallery) -> some View {
        // 診断 2026-07-21 (iPad 1.5秒自動クローズ): zoom 遷移が犯人かの A/B レバー。
        // cortex://debug/set-default?key=zoomTransitionDisabled&value=true で遠隔切替。
        if UserDefaults.standard.bool(forKey: "zoomTransitionDisabled") {
            LocalReaderView(meta: meta, initialPage: readerInitialPage, forcedDirection: readerForcedDirection,
                            explicitPageLaunch: readerExplicitPage, route: .libraryCardTile)
        } else {
            LocalReaderView(meta: meta, initialPage: readerInitialPage, forcedDirection: readerForcedDirection,
                            explicitPageLaunch: readerExplicitPage, route: .libraryCardTile)
                // B3: タップしたタイルから zoom。source 不一致時は既定遷移に自然フォールバック。
                .navigationTransition(.zoom(sourceID: zoomSourceKey, in: zoomNS))
        }
    }

    private func resetReaderLaunchState() {
        LogManager.shared.log("Tap", "readerCover onDismiss (launch state reset)")
        readerInitialPage = 0
        readerForcedDirection = nil
        readerExplicitPage = false
    }
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
    @AppStorage(UDKey.downloadsCompletedSortOrderRaw) private var completedSortOrderRaw: String = ExternalFolderManager.ExternalSortOrder.dateAdded.rawValue
    /// 田中要望 2026-05-01: ライブラリのグリッド/リスト切替 (ギャラリーリストと同じ仕様)。
    @AppStorage(UDKey.libraryListLayout) private var libraryListLayout: String = "list"
    private var isLibraryGrid: Bool { libraryListLayout == "grid" }

    /// 監査B3 (apple-design §7 空間的一貫性): タイル → リーダーの zoom 遷移。
    /// タップしたタイルの位置から画像が拡大して開き、閉じると同じ場所へ縮む。
    @Namespace private var zoomNS
    /// 直近タップの source id ("gid-p<page>")。「読む」経由や不一致時は空 = 既定遷移。
    @State private var zoomSourceKey: String = ""

    /// ライブラリ内検索 (2026-07-20 田中要望)。タイトル部分一致 (大小無視)。
    /// 4セクション全部の computed prop 側で絞るので、件数表示も検索結果の数になる。
    @State private var librarySearchText = ""
    private func searchFiltered(_ items: [DownloadedGallery]) -> [DownloadedGallery] {
        let q = librarySearchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
    private var completedSortOrder: ExternalFolderManager.ExternalSortOrder {
        get { ExternalFolderManager.ExternalSortOrder(rawValue: completedSortOrderRaw) ?? .dateAdded }
    }

    private var activeList: [(gid: Int, progress: DownloadManager.DownloadProgress)] {
        manager.activeDownloads.sorted(by: { $0.key < $1.key }).map { (gid: $0.key, progress: $0.value) }
    }

    /// 田中要望 2026-04-26: 外部参照を「一覧から削除した gid」と「ソート順」でフィルタ + sort。
    /// 田中要望 2026-04-30: 同名作品が大量に並ぶ問題 (rescan で別 gid 重複登録) に対し
    ///   title (大小無視) ベースで dedup。表示は downloadDate が新しい方を残す。
    private var visibleSortedExternal: [DownloadedGallery] {
        let visible = externalFolders.externalGalleries
            .filter { !externalFolders.hiddenExternalGids.contains($0.gid) }
        let deduped = searchFiltered(Self.dedupeByTitle(visible))
        switch externalFolders.externalSortOrder {
        case .dateAdded:
            return deduped.sorted { $0.downloadDate > $1.downloadDate }
        case .nameAsc:
            return deduped.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .nameDesc:
            return deduped.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
    }

    /// title (大小無視 + 前後空白除去) で同一視。downloadDate 最新を代表として残す。
    private static func dedupeByTitle(_ items: [DownloadedGallery]) -> [DownloadedGallery] {
        var byKey: [String: DownloadedGallery] = [:]
        for item in items {
            let key = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let existing = byKey[key] {
                if item.downloadDate > existing.downloadDate {
                    byKey[key] = item
                }
            } else {
                byKey[key] = item
            }
        }
        return Array(byKey.values)
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
        // 田中要望 2026-04-30: 同名作品が大量に並ぶ問題に対し title ベース dedup (downloadDate 最新を残す)。
        // 田中要望 2026-06-10: 自動保存由来 (DL 意思なし) は「自動保存」セクションへ分離
        let filtered = searchFiltered(Self.dedupeByTitle(manager.downloads.values.filter { $0.isComplete && $0.autoSaveOnly != true }))
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
        searchFiltered(manager.downloads.values
            .filter { !$0.isComplete && manager.activeDownloads[$0.gid] == nil && $0.autoSaveOnly != true }
            .sorted(by: { $0.downloadDate > $1.downloadDate }))
    }

    /// 自動保存由来 (DL 意思なし) の作品。完了/未完了問わずここに分離して、
    /// 意図的な DL と混ざらないようにする (田中要望 2026-06-10)。
    private var autoSavedList: [DownloadedGallery] {
        searchFiltered(manager.downloads.values
            .filter { $0.autoSaveOnly == true && manager.activeDownloads[$0.gid] == nil }
            .sorted(by: { $0.downloadDate > $1.downloadDate }))
    }

    /// 「自動保存」セクション (List 用)。body 直書きだと type-check タイムアウトするため分離。
    @ViewBuilder
    private var autoSavedSection: some View {
        if !autoSavedList.isEmpty {
            Section {
                ForEach(autoSavedList) { meta in
                    autoSavedRow(meta: meta)
                }
            } header: {
                Text("自動保存 (\(autoSavedList.count))")
            } footer: {
                Text("読んだページが自動保存された作品です。ライブラリに残したい場合は長押しから「正式にダウンロード登録」")
            }
        }
    }

    @ViewBuilder
    private func autoSavedRow(meta: DownloadedGallery) -> some View {
        Group {
            if meta.isComplete {
                completedRow(meta: meta)
            } else {
                incompleteRow(meta: meta)
            }
        }
        .contextMenu {
            Button {
                manager.promoteAutoSavedToDownload(gid: meta.gid)
            } label: {
                Label("正式にダウンロード登録", systemImage: "arrow.down.circle")
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

                // 自動保存 (読んだページの保存のみ = DL 意思なし)。意図的な DL と混ざらない
                // よう分離 (田中要望 2026-06-10)。「正式にダウンロード登録」で昇格可能。
                // body の type-check タイムアウト回避のためヘルパーに分離。
                autoSavedSection

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
            .overlay {
                // 田中要望 2026-05-01: グリッド表示。List の上に overlay で覆う方式
                // (既存セル/swipeActions/refreshable をそのまま温存するため)。
                if isLibraryGrid {
                    libraryGridContent
                        .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            // 田中要望 2026-04-26: ライブラリ pull-to-refresh で外部参照フォルダ rescan。
            // staging → NAS bulk move 完了後、新しい gallery を即取得可能。
            .refreshable {
                await externalFolders.rescanAll()
            }
            .navigationTitle("ライブラリ")
            .searchable(text: $librarySearchText, prompt: "タイトルで検索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(tabBarHidden ? .hidden : .visible, for: .tabBar)
            .animation(.smooth(duration: 0.25), value: tabBarHidden)
            #endif
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }, action: handleListScrollDelta)
            // レイアウト切替時は必ずタブバーを復帰 (空ライブラリでスクロール不能 = 詰み対策)
            .onChange(of: isLibraryGrid, resetTabBarOnLayoutToggle)
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
                        libraryListLayout = isLibraryGrid ? "list" : "grid"
                    } label: {
                        Image(systemName: isLibraryGrid ? "list.bullet" : "square.grid.2x2")
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
            // 診断 2026-07-21 (iPad 1.5秒自動クローズ): item が nil にされたのか外部要因 dismiss かの切り分け
            .onChange(of: readerMeta?.gid) { oldValue, newValue in
                LogManager.shared.log("Tap", "readerMeta \(oldValue.map(String.init) ?? "nil")→\(newValue.map(String.init) ?? "nil")")
            }
            .fullScreenCover(item: $readerMeta, onDismiss: resetReaderLaunchState, content: readerCover)
            .fullScreenCover(item: $liveReaderMeta) { meta in
                LocalReaderView(meta: meta, isLiveDownload: true, route: .libraryLiveDL)
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

                            readerExplicitPage = true   // 明示ページ指定 (横強制は2026-07-21撤回、設定に従う)
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
            // SSD 残量不足で DL を開始できなかった時の通知 (DownloadManager.storageAlertMessage)
            .alert("ストレージ不足", isPresented: .constant(manager.storageAlertMessage != nil)) {
                Button("OK") { manager.storageAlertMessage = nil }
            } message: {
                Text(manager.storageAlertMessage ?? "")
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
                ShikigamiEngine.shared.currentScreen = "Library"
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
        // 田中要望 2026-04-28: 同 gid の NAS 転送が走っている間は DL 進捗ではなく
        // 「NAS 転送中…」表記に丸ごと切り替える (DL 完了→転送の境界が紛らわしいため)。
        let activeTransfer: DownloadManager.TransferProgress? = (manager.currentTransfer?.gid == gid) ? manager.currentTransfer : nil
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
                    if let t = activeTransfer {
                        // NAS 転送中表記 (DL は完了済み、staging → NAS へ ZIP stream 中)
                        let total = max(t.totalBytes, 1)
                        let ratio = Double(t.doneBytes) / Double(total)
                        Text("NAS に転送中…")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Text("\(formatByteSize(Int64(t.doneBytes))) / \(formatByteSize(Int64(t.totalBytes))) (\(Int(ratio * 100))%)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
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
                }
                Spacer()
                // 転送中は cancel 不可 (DL は完了済、転送 task は別レーンで走ってる)
                if activeTransfer == nil {
                    Button {
                        manager.cancelDownload(gid: gid)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            // 進捗 bar: 転送中は転送 ratio + 橙、それ以外は phase 別
            if let t = activeTransfer {
                let total = max(t.totalBytes, 1)
                ProgressView(value: Double(t.doneBytes) / Double(total))
                    .tint(.orange)
            } else if progress.phase != .preparing || progress.total > 0 {
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
            // 2ndpass (mirror DL) 中: 田中指示 2026-04-28 残り時間/残り容量を表示
            // 既存 1stpass の est-live 方式は残 page が large animated WebP の場合 live > est で
            // 表示されないため、retrying では「残 page 数 × 平均 page サイズ」ベースで計算する。
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let bps = BackgroundDownloadManager.shared.sampleBytesPerSecond(for: gid)
                let remainingBytes = manager.estimatedRemainingBytes(gid: gid, totalPages: progress.total, currentPages: progress.current) ?? 0
                HStack(spacing: 6) {
                    if remainingBytes > 0 {
                        Text("残り ~\(formatByteSize(remainingBytes))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.primary)
                        if bps > 0 {
                            let etaSec = Int(Double(remainingBytes) / Double(bps))
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
    // 統合指示書 v2 機能B (2026-07-20): App Store 風カードに完全置換。
    // 旧クラシック行 (小サムネ + タイトル密行) は田中確定で廃止、設定トグルも作らない。
    private func completedRow(meta: DownloadedGallery) -> some View {
        let isHighlighted = highlightedGid == meta.gid
        LibraryCardView(meta: meta, onCover: {
            // 診断 2026-07-21 (iPad タップ無反応): タップがハンドラまで届いているかの計測器
            LogManager.shared.log("Tap", "jacket gid=\(meta.gid)")
            detailMeta = meta
        }, zoomNamespace: zoomNS) {
            coverThumbnail(gid: meta.gid)
        } onRead: {
            LogManager.shared.log("Tap", "read gid=\(meta.gid)")
            // 田中要望 2026-04-26: internal DL も pre-cache 経路に統一、ensureAnimatedWebpScanned
            // を background 完了させてから Reader 起動 (1000+ ページ初回 scan の freeze 回避)。
            zoomSourceKey = ""   // 読むは既定遷移 (B3: zoom はタイル経路のみ)
            // 田中報告 2026-07-21: タイル起動の forced=1 が残留して「読む」経由でも横で開く。
            // onDismiss リセット頼みをやめ、起動サイトごとに launch 状態を毎回明示する。
            readerInitialPage = 0
            readerForcedDirection = nil
            readerExplicitPage = false
            startPreCacheAndOpenReader(meta: meta, count: 0)
        } onTapPage: { page in
            LogManager.shared.log("Tap", "tile gid=\(meta.gid) page=\(page)")
            // タイルタップ → リーダーで該当ページ直接 (ワープ)。戻るはリストへ (fullScreenCover dismiss)
            zoomSourceKey = "\(meta.gid)-p\(page)"   // B3: このタイルから zoom
            readerInitialPage = page

            readerExplicitPage = true   // 明示ページ指定 (横強制は2026-07-21撤回、設定に従う)
            startPreCacheAndOpenReader(meta: meta, count: 0)
        } onMore: {
            LogManager.shared.log("Tap", "more gid=\(meta.gid)")
            // 続きを見る → 既存ページ詳細 (LocalPreviewOverlay)
            previewMeta = meta
        }
        .overlay(alignment: .topTrailing) {
            if isHighlighted {
                Text("NEW")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green)
                    .clipShape(Capsule())
                    .padding(8)
            }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .listRowBackground(
            isHighlighted ? Color.green.opacity(0.12) : Color.clear
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
    // 外部フォルダ配下の作品。タップで先頭ページを background pre-cache してから
    // Reader を開く (startPreCacheAndOpenReader)。サムネは ZIP から materialize した
    // cover を表示する (Phase E1.B で実装済み。「次フェーズ alert」時代の記述は廃止)。

    @ViewBuilder
    private func externalRow(meta: DownloadedGallery) -> some View {
        // 統合指示書 v2 機能B (2026-07-20): App Store 風カードに置換。
        // Phase E1.B (2026-04-26): 外部参照 ZIP は最初の N ページを background pre-cache
        // してから Reader を開く (main thread freeze 回避) — カードの onRead/onTapPage も同経路。
        // SMB 未 materialize のタイルは placeholder のまま (Transport-Agnostic、指示書 共通条件4)。
        // ジャケットタップの詳細遷移は originalGid がある作品のみ (旧 .cortex は contextMenu と同じく不可)
        LibraryCardView(meta: meta, showExtBadge: true,
                        onCover: meta.originalGid != nil ? { detailMeta = meta } : nil,
                        zoomNamespace: zoomNS) {
            // 田中要望 2026-04-26: サムネ表示 (cover.* or page_0001 を ZIP から materialize)
            coverThumbnail(gid: meta.gid)
        } onRead: {
            zoomSourceKey = ""
            // 田中報告 2026-07-21: 残留 forced 対策 (completedRow 側と同じ)
            readerInitialPage = 0
            readerForcedDirection = nil
            readerExplicitPage = false
            startPreCacheAndOpenReader(meta: meta, count: 3)
        } onTapPage: { page in
            zoomSourceKey = "\(meta.gid)-p\(page)"
            readerInitialPage = page

            readerExplicitPage = true   // 明示ページ指定 (横強制は2026-07-21撤回、設定に従う)
            startPreCacheAndOpenReader(meta: meta, count: 3)
        } onMore: {
            previewMeta = meta
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .listRowBackground(Color.clear)
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

    // MARK: - グリッド表示 (田中要望 2026-05-01)

    /// idiom 別グリッド列数 (ギャラリーリストと同じ仕様: iPad=4, iPhone=3, Mac Catalyst=adaptive(180+))
    private var libraryGridColumns: [GridItem] {
        #if targetEnvironment(macCatalyst)
        return GalleryGridColumns.macColumns()
        #elseif canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .phone {
            return GalleryGridColumns.iPhoneColumns()
        }
        return GalleryGridColumns.iPadColumns(horizontalSizeClass: nil)
        #else
        return [GridItem(.adaptive(minimum: 160), spacing: 8)]
        #endif
    }

    @ViewBuilder
    private var libraryGridContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // 田中報告 2026-06-22: グリッド表示だと DL 進捗が見えない (list 表示には
                // グリッド導入前から downloadingRow があった)。list と同じ進捗行をグリッドの
                // 先頭にも出す。downloadingRow を流用 (第19条・車輪の再発明禁止)。
                if !activeList.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "ダウンロード中 (\(activeList.count))"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
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
                if !completedList.isEmpty {
                    libraryGridSection(
                        title: String(localized: "保存済み (\(completedList.count))"),
                        items: completedList
                    )
                }
                if !visibleSortedExternal.isEmpty {
                    libraryGridSection(
                        title: String(localized: "外部参照 (\(visibleSortedExternal.count))"),
                        items: visibleSortedExternal
                    )
                }
                if !incompleteList.isEmpty {
                    libraryGridSection(
                        title: String(localized: "未完了 (\(incompleteList.count))"),
                        items: incompleteList
                    )
                }
                if !autoSavedList.isEmpty {
                    libraryGridSection(
                        title: String(localized: "自動保存 (\(autoSavedList.count))"),
                        items: autoSavedList
                    )
                }
                if activeList.isEmpty && completedList.isEmpty && visibleSortedExternal.isEmpty && incompleteList.isEmpty && autoSavedList.isEmpty {
                    ContentUnavailableView {
                        Label("保存済みギャラリーがありません", systemImage: "arrow.down.circle")
                    } description: {
                        Text("ギャラリー詳細画面からダウンロードできます")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        // グリッド専用のタブバー隠しハンドラ (外側の List 用ハンドラはグリッド中 no-op)。
        // overlay 方式で ScrollView が2つ並存するため、混線しないよう自分の分だけ担当する。
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }, action: applyScrollDelta)
        // スクラブプレビュー (機能A): 透明1枚 + 指座標追跡。hitTest 常時 nil なので
        // スクロール/タップ/長押しは構造的に阻害しない。ライブラリ (保存済み) グリッド限定。
        .overlay { ScrubTouchOverlay().allowsHitTesting(false) }
    }

    /// タブバー隠し共通ロジック (delta > 8 で隠す / delta < -5 で出す)
    private func applyScrollDelta(_ oldVal: CGFloat, _ newVal: CGFloat) {
        let delta = newVal - oldVal
        if abs(delta) > 100 { return }
        if delta > 8 { tabBarHidden = true }
        else if delta < -5 { tabBarHidden = false }
    }

    /// List 用ハンドラ。田中報告 2026-07-02: グリッド表示中は overlay 側 ScrollView と
    /// List のオフセットがこの1個のハンドラに混線し、タブバー (iPadOS 26 は上部表示) が
    /// 隠れたまま復帰しない。グリッド中は overlay 側の専用ハンドラに任せて no-op にする。
    private func handleListScrollDelta(_ oldVal: CGFloat, _ newVal: CGFloat) {
        guard !isLibraryGrid else { return }
        applyScrollDelta(oldVal, newVal)
    }

    private func resetTabBarOnLayoutToggle() {
        tabBarHidden = false
    }

    @ViewBuilder
    private func libraryGridSection(title: String, items: [DownloadedGallery]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            LazyVGrid(columns: libraryGridColumns, spacing: 10) {
                ForEach(items) { meta in
                    libraryGridCell(meta: meta)
                        .contextMenu {
                            // 自動保存作品の救済: 昇格すれば上限(5作品)の自動削除対象から外れる
                            if meta.autoSaveOnly == true {
                                Button {
                                    manager.promoteAutoSavedToDownload(gid: meta.gid)
                                } label: {
                                    Label("正式にダウンロード登録", systemImage: "arrow.down.circle")
                                }
                            }
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
                }
            }
        }
    }

    @ViewBuilder
    private func libraryGridCell(meta: DownloadedGallery) -> some View {
        Button {
            // プレビュー発動後の指離しはタップ扱いにしない (機能A A-3)
            guard !ScrubPreviewController.shared.consumeSwallowTap() else {
                LogManager.shared.log("Tap", "grid cell SWALLOWED gid=\(meta.gid)")
                return
            }
            LogManager.shared.log("Tap", "grid cell gid=\(meta.gid)")
            startPreCacheAndOpenReader(meta: meta, count: meta.source == "external_zip" ? 3 : 0)
        } label: {
            // UI 刷新 Phase 1.9 (2026-07-03): 一覧グリッドと同じカバー主役カード型
            VStack(alignment: .leading, spacing: 0) {
                Color.gray.opacity(0.15)
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .overlay {
                        AsyncCoverThumbnailFlexible(gid: meta.gid)
                    }
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if meta.isAnimatedGallery {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.65))
                                .clipShape(Circle())
                                .padding(4)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if meta.pageCount > 0 {
                            CoverPagesBadge(pages: meta.pageCount, fontSize: 8)
                        }
                    }
                    // スクラブプレビューのコマ表示 (frame=nil の間は透過でカバーが見える)
                    .overlay { ScrubFrameView(gid: meta.gid) }

                VStack(alignment: .leading, spacing: 4) {
                    Text(meta.title)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // NH バッジは 2026-07-20 田中指示で削除 (セル高さが不揃いになるため)
                }
                .padding(8)
            }
            .background(CardDesign.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CardDesign.cardCorner, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.98))   // 大きめセルは浅い沈み込み (監査 B1)
        .scrubPressEffect(gid: meta.gid)        // スクラブ発動時の沈み込み (監査 A2)
        // スクラブプレビュー: 指下セル特定用に window 座標の frame を常時登録 (機能A A-6)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
            ScrubPreviewController.shared.updateCell(gid: meta.gid, pageCount: meta.pageCount, frame: rect)
        }
        .onDisappear { ScrubPreviewController.shared.cellGone(meta.gid) }
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
                } else {
                    // 田中報告 2026-07-21: cancel だと cover が開かず onDismiss リセットも
                    // 走らないため forced=1/initialPage が残留し、以後の「読む」起動が
                    // 横強制で汚染される (縦設定なのに横のまま事件の機序)
                    resetReaderLaunchState()
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
                    // r010 (2026-07-22): .fill あふれは不可視タップ吸収体になる。装飾画像は hit 対象外
                    .allowsHitTesting(false)
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
        // coverImage(gid:) は完了を直接返す (2026-06-11): 旧 loadCoverImage は miss 時 nil +
        // publish 頼みで、onAppear 一回きりのこのセルでは再取得されず空のままだった
        Task { self.image = await DownloadManager.shared.coverImage(gid: gid) }
    }
}

/// Grid セル用 (frame 制約なし)。親の aspectRatio に従って fill 表示。
private struct AsyncCoverThumbnailFlexible: View {
    let gid: Int
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // r010 (2026-07-22): .fill あふれは不可視タップ吸収体になる。装飾画像は hit 対象外
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard image == nil else { return }
        let gid = gid
        Task { self.image = await DownloadManager.shared.coverImage(gid: gid) }
    }
}

