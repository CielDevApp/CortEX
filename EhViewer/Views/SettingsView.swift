import SwiftUI
import UniformTypeIdentifiers
import TipKit

struct SettingsView: View {
    @ObservedObject var authVM: AuthViewModel
    @State private var readerCacheMB: Int = 0
    @State private var thumbsCacheMB: Int = 0
    @AppStorage("onlineQualityMode") private var onlineQualityMode = 2
    @AppStorage("downloadQualityMode") private var downloadQualityMode = 2
    @AppStorage("aiImageProcessing") private var aiImageProcessing = false
    @AppStorage("hdrEnhancement") private var hdrEnhancement = false
    @AppStorage("imageEnhanceFilter") private var imageEnhanceFilter = false
    @AppStorage("translationMode") private var translationMode = false
    @AppStorage("translationLang") private var translationLang = "ja"
    @AppStorage("translationSourceLang") private var translationSourceLang = "auto"
    @AppStorage("autoSaveOnRead") private var autoSaveOnRead = false
    @State private var favBackupURL: URL?
    @State private var showImportPicker = false
    @State private var phoenixImportCount = 0
    @State private var showClearConfirm = false
    @State private var showClearDownloads = false
    @State private var showFullRefresh = false
    @State private var showPINSetup = false
    @State private var isPINChange = false
    @AppStorage("useMetalPipeline") private var useMetalPipeline = false
    @AppStorage("appTheme") private var appTheme = 0
    @AppStorage("readerDirection") private var readerDirection = 0
    @AppStorage("readingOrder") private var readingOrder = 1
    @State private var showBenchmark = false
    @State private var showLogViewer = false
    @AppStorage("debugLogEnabled") private var debugLogEnabled = false
    @StateObject private var favVM = FavoritesViewModel()
    @ObservedObject private var extremeMode = ExtremeMode.shared
    @ObservedObject private var ecoMode = EcoMode.shared
    @State private var showExtremeConfirm = false
    @State private var showExtremeNeedBackup = false
    @State private var tipsReset = false
    @State private var showNhLogin = false
    @State private var showNhCDNVerify = false
    @State private var nhLoggedIn = NhentaiCookieManager.isLoggedIn()
    @AppStorage("showAdvancedSettings") private var showAdvanced = false
    // CORTEX PROTOCOL (hidden)
    @State private var versionTapCount = 0
    @AppStorage("cortexProtocolUnlocked") private var cortexUnlocked = false
    @State private var showCortexActivation = false
    @State private var cortexSearchURL: URL?

    private var maxMB: Int { ImageCache.shared.maxDiskBytes / 1_048_576 }
    private var isOverLimit: Bool { readerCacheMB > maxMB }

    var body: some View {
        NavigationStack {
            Form {
                // 1. 情報
                Section("情報") {
                    HStack {
                        Text("バージョン"); Spacer()
                        Text("Cort:EX ver.02a f2")
                            .font(.caption.monospaced())
                            .foregroundStyle(cortexUnlocked ? Color(red: 0.85, green: 0.1, blue: 0.15) : .secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if cortexUnlocked { return }
                        versionTapCount += 1
                        if versionTapCount >= 7 {
                            cortexUnlocked = true
                            showCortexActivation = true
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            #endif
                        } else if versionTapCount >= 4 {
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            #endif
                        }
                    }
                    .contextMenu {
                        if cortexUnlocked {
                            Button(role: .destructive) {
                                cortexUnlocked = false
                                versionTapCount = 0
                            } label: {
                                Label("CORTEX PROTOCOL 無効化", systemImage: "lock.fill")
                            }
                        }
                    }
                }

                Section {
                    Button {
                        #if canImport(UIKit)
                        if let url = URL(string: "https://www.patreon.com/c/Cielchan") {
                            UIApplication.shared.open(url)
                        }
                        #endif
                    } label: {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                            Text("開発を支援する（Patreon）")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 2. アカウント
                Section("E-Hentai") {
                    if authVM.isLoggedIn {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("ログイン済み")
                        }
                        Button("ログアウト", role: .destructive) { authVM.logout() }
                    } else {
                        HStack {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text("未ログイン")
                        }
                        Button("ログイン") { authVM.showingLogin = true }
                    }
                }

                nhentaiSection

                // 3. テーマ
                Section("テーマ") {
                    Picker("テーマ", selection: $appTheme) {
                        Text("システム").tag(0)
                        Text("ダーク").tag(1)
                        Text("ライト").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                // 4. 表示
                Section("表示") {
                    Picker("読み方向", selection: $readerDirection) {
                        Text("縦スクロール").tag(0)
                        Text("横ページめくり").tag(1)
                    }
                    .pickerStyle(.segmented)

                    if readerDirection == 1 {
                        Picker("綴じ方向", selection: $readingOrder) {
                            Text("左綴じ").tag(0)
                            Text("右綴じ").tag(1)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // 5. お気に入り
                Section("お気に入り") {
                    let favCount = FavoritesCache.shared.load().count
                    HStack { Text("キャッシュ件数"); Spacer(); Text("\(favCount)件").foregroundStyle(.secondary) }
                    Button("お気に入り全件再取得") { showFullRefresh = true }
                    Text("全ページをサーバーから取得します。時間がかかり、BANされる可能性があります。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // 6. 画質設定（統合）
                Section("画質設定") {
                    Picker("オンライン画質", selection: $onlineQualityMode) {
                        Text("低画質").tag(0)
                        Text("低画質+超解像").tag(1)
                        Text("標準").tag(2)
                        Text("標準+フィルタ").tag(3)
                    }
                    Picker("ダウンロード済み画質", selection: $downloadQualityMode) {
                        Text("標準").tag(0)
                        Text("標準+フィルタ").tag(1)
                        Text("究極").tag(2)
                    }
                    Toggle("画像補正フィルタ", isOn: $imageEnhanceFilter)
                    Toggle("HDR風補正", isOn: $hdrEnhancement)
                    Toggle("AI超解像", isOn: $aiImageProcessing)

                    if !CoreMLImageProcessor.shared.modelAvailable {
                        Text("AI超解像: モデル未検出").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // 7. リアルタイム翻訳
                Section("リアルタイム翻訳") {
                    Toggle("翻訳モード", isOn: $translationMode)
                    Picker("翻訳先（母国語）", selection: $translationLang) {
                        Text("日本語").tag("ja")
                        Text("English").tag("en")
                        Text("中文").tag("zh")
                        Text("한국어").tag("ko")
                    }
                    Picker("翻訳元（作品の言語）", selection: $translationSourceLang) {
                        Text("Auto").tag("auto")
                        Text("English").tag("en")
                        Text("中文（簡体）").tag("zh-Hans")
                        Text("中文（繁体）").tag("zh-Hant")
                        Text("日本語").tag("ja")
                        Text("한국어").tag("ko")
                    }
                    HStack {
                        Text("言語パック"); Spacer()
                        Text(languagePackStatus()).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("翻訳キャッシュをリセット", role: .destructive) {
                        TranslationService.shared.clearCache()
                    }
                }

                // 8. セキュリティ
                Section("セキュリティ") {
                    Toggle("生体認証ロック", isOn: Binding(
                        get: { BiometricAuth.shared.isEnabled },
                        set: { BiometricAuth.shared.isEnabled = $0 }
                    ))
                    if PINManager.shared.hasPIN {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("PINコード設定済み")
                        }
                        Button("PINコードを変更") { showPINSetup = true; isPINChange = true }
                        Button("PINコードを削除", role: .destructive) { PINManager.shared.removePIN() }
                    } else {
                        Button("PINコードを設定") { showPINSetup = true; isPINChange = false }
                        Text("Face ID失敗時のフォールバック認証").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // 9. ECOモード
                Section {
                    Toggle(isOn: Binding(
                        get: { ecoMode.isEnabled },
                        set: { ecoMode.isEnabled = $0 }
                    )) {
                        Label("ECOモード", systemImage: "leaf.fill")
                    }
                    .tint(.green)
                    if ecoMode.isEnabled {
                        HStack {
                            Image(systemName: "leaf.fill").foregroundStyle(.green)
                            Text("ECO MODE ENABLED").font(.caption.bold()).foregroundStyle(.green)
                        }
                    }
                    Toggle("iOS低電力モード連動", isOn: Binding(
                        get: { ecoMode.linkToLowPower },
                        set: { ecoMode.linkToLowPower = $0 }
                    ))
                    .font(.subheadline).tint(.green)
                } header: {
                    if ecoMode.isEnabled {
                        Label("ECO MODE", systemImage: "leaf.fill").foregroundStyle(.green)
                    } else { Text("ECO") }
                }

                // 操作方法
                Section("操作方法") {
                    Button {
                        try? Tips.resetDatastore()
                        tipsReset = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tipsReset = false }
                    } label: {
                        Label("操作ヒントを再表示", systemImage: "lightbulb.fill")
                    }
                    if tipsReset {
                        Text("次回各画面を開いた時にヒントが表示されます")
                            .font(.caption2).foregroundStyle(.green)
                    }
                    Text("リーダーの操作方法やお気に入り同期などのヒントを再表示します。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // 高度な設定トグル
                Section {
                    Toggle("高度な設定を表示", isOn: $showAdvanced.animation(.easeInOut(duration: 0.3)))
                }

                if showAdvanced {

                // 1. PHOENIX MODE
                Section {
                    let ehCount = FavoritesCache.shared.load().count
                    let nhCount = NhentaiFavoritesCache.shared.load().count
                    Button { favBackupURL = FavoritesBackup.export() } label: {
                        Label("バックアップ作成", systemImage: "arrow.down.doc")
                    }
                    if let backupURL = favBackupURL {
                        ShareLink(item: backupURL) { Label("エクスポート", systemImage: "square.and.arrow.up") }
                        Text(backupURL.lastPathComponent).font(.caption2).foregroundStyle(.green)
                    }
                    Button { showImportPicker = true } label: {
                        Label("バックアップから復元", systemImage: "arrow.up.doc")
                    }
                    if phoenixImportCount > 0 {
                        Text("\(phoenixImportCount)件を復元しました").font(.caption2).foregroundStyle(.green)
                    }
                    Text("E-H: \(ehCount)件 / nhentai: \(nhCount)件のインデックスをJSON保存。BANされても手元にデータが残ります。")
                        .font(.caption2).foregroundStyle(.secondary)
                } header: {
                    Label("PHOENIX MODE", systemImage: "flame.fill").foregroundStyle(.orange)
                }

                // 2. 自動保存
                Section {
                    Toggle("閲覧時自動保存", isOn: $autoSaveOnRead).tint(.blue)
                    Text("オンライン閲覧した画像を自動的にローカルに保存します。リーダーを閉じた時に保存済みに登録されます。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if autoSaveOnRead {
                        Label("ストレージ容量にご注意ください", systemImage: "externaldrive.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                } header: { Text("自動保存") }

                // 3. 画像処理エンジン
                Section("画像処理エンジン") {
                    Picker("エンジン", selection: $useMetalPipeline) {
                        Text("CIFilter (標準)").tag(false)
                        Text("Metal (GPU直叩き)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("現在"); Spacer()
                        Text(useMetalPipeline ? "Metal Compute Shader" : "CIFilter チェーン").foregroundStyle(.secondary)
                    }
                }

                // 4. 検索
                Section("検索") {
                    Toggle("タグ自動翻訳", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "tagTranslation") },
                        set: { UserDefaults.standard.set($0, forKey: "tagTranslation") }
                    )).tint(.blue)
                    Text("日本語で検索すると自動的にE-Hentaiのタグに変換します（例: 巨乳 → female:big breasts）")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // 5. ネットワーク
                Section("ネットワーク") {
                    Toggle("モバイルデータでDL許可", isOn: Binding(
                        get: { NetworkMonitor.shared.allowCellularDownload },
                        set: { NetworkMonitor.shared.allowCellularDownload = $0 }
                    )).tint(.blue)
                    Text("OFFの場合、WiFi→セルラー切替時に確認ダイアログが表示されます。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // 6. デバッグ
                Section("デバッグ") {
                    Toggle("デバッグログ", isOn: $debugLogEnabled)
                    Button("ログを表示") { showLogViewer = true }
                    Button("ログをクリア", role: .destructive) { LogManager.shared.clear() }
                    Text("\(LogManager.shared.logs.count)件のログ").font(.caption2).foregroundStyle(.secondary)
                }

                // 7. キャッシュ管理
                Section("キャッシュ管理") {
                    HStack { Text("リーダーキャッシュ"); Spacer()
                        Text("\(readerCacheMB)MB / \(maxMB)MB").foregroundStyle(isOverLimit ? .red : .secondary)
                    }
                    HStack { Text("サムネキャッシュ"); Spacer()
                        Text("\(thumbsCacheMB)MB").foregroundStyle(.secondary)
                    }
                    if isOverLimit {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text("リーダーキャッシュが上限を超えています").font(.caption).foregroundStyle(.red)
                        }
                    }
                    Button("リーダーキャッシュを削除", role: .destructive) { showClearConfirm = true }
                    Button("サムネキャッシュも削除", role: .destructive) { ImageCache.shared.clearThumbsCache(); updateCacheSize() }
                    let dlCount = DownloadManager.shared.downloads.count
                    HStack { Text("保存済みギャラリー"); Spacer(); Text("\(dlCount)件").foregroundStyle(.secondary) }
                    Button("全ダウンロードデータを削除", role: .destructive) { showClearDownloads = true }
                }

                // 8. ベンチマーク
                Section("ベンチマーク") {
                    Button("ベンチマーク実行") { showBenchmark = true }
                    Text("CIFilter vs Metal の処理速度を計測します。").font(.caption2).foregroundStyle(.secondary)
                }

                // 9. EXTREME MODE（最下部）
                Section {
                    Toggle("エクストリームモード", isOn: Binding(
                        get: { extremeMode.isEnabled },
                        set: { newValue in
                            if newValue {
                                if FavoritesBackup.hasBackup {
                                    showExtremeConfirm = true
                                } else {
                                    showExtremeNeedBackup = true
                                }
                            } else {
                                extremeMode.isEnabled = false
                            }
                        }
                    )).tint(.red)
                    if extremeMode.isEnabled {
                        HStack {
                            Image(systemName: "bolt.fill").foregroundStyle(.red)
                            Text("EXTREME MODE ENABLED").font(.caption.bold()).foregroundStyle(.red)
                            Text("‼︎").foregroundStyle(.red)
                        }
                        TipView(ExtremeAutoOffTip(), arrowEdge: .top)
                    }
                    Text("""
                    EXTREME MODE を有効にすると全リミッターが解除されます:
                    • Delay: ALL DISABLED（閲覧・DL・お気に入り）
                    • Download: NO SPEED LIMIT
                    • Connections: 6 → 20 parallel
                    • Prefetch: ±1 → ±5 pages
                    • Gallery Preview: FULL IMAGE PRELOAD
                    • OCR Batch: 3 → 6 parallel
                    • URL Cache: EXPIRY CHECK DISABLED

                    ⚠️ BAN RISK. Auto-OFF on restart.
                    """).font(.caption2).foregroundStyle(.secondary)
                } header: {
                    if extremeMode.isEnabled {
                        Label("EXTREME MODE", systemImage: "bolt.fill").foregroundStyle(.red)
                    } else { Text("EXTREME") }
                }

                } // end advanced settings
            }
            .navigationTitle("設定")
            .onAppear {
                updateCacheSize()
            }
            .alert("リーダーキャッシュを削除", isPresented: $showClearConfirm) {
                Button("削除", role: .destructive) {
                    ImageCache.shared.clearReaderCache()
                    updateCacheSize()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("リーダーキャッシュ(\(readerCacheMB)MB)を削除しますか？サムネキャッシュは残ります。")
            }
            .alert("ダウンロードデータを削除", isPresented: $showClearDownloads) {
                Button("全て削除", role: .destructive) {
                    let dm = DownloadManager.shared
                    for gid in dm.downloads.keys {
                        dm.deleteDownload(gid: gid)
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("全てのダウンロード済みギャラリーとメタデータを削除しますか？")
            }
            .alert("お気に入り全件再取得", isPresented: $showFullRefresh) {
                Button("実行") {
                    Task { await favVM.fullRefreshFromServer() }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("サーバーから全ページ取得します。BANされる可能性があります。続行しますか？")
            }
            .alert("⚠️ エクストリームモード", isPresented: $showExtremeConfirm) {
                Button("有効化する", role: .destructive) {
                    extremeMode.isEnabled = true
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("BAN対策（リクエストディレイ・レート制限）を全て無効化します。アカウントBANのリスクがあります。自己責任で使用してください。")
            }
            .alert("バックアップが必要です", isPresented: $showExtremeNeedBackup) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("エクストリームモードはBANリスクがあります。先にPHOENIX MODEでお気に入りのバックアップを作成してください。")
            }
            .overlay {
                if favVM.isLoading {
                    VStack {
                        ProgressView("お気に入り取得中... \(favVM.totalLoaded)件")
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .sheet(isPresented: $showPINSetup) {
            PINSetupView(isChange: isPINChange) {}
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showBenchmark) {
            BenchmarkView()
        }
        #endif
        .sheet(isPresented: $showLogViewer) {
            LogViewerView()
        }
        #if os(iOS)
        .sheet(isPresented: $showNhLogin) {
            NhentaiLoginView()
                .onDisappear { nhLoggedIn = NhentaiCookieManager.isLoggedIn() }
        }
        .sheet(isPresented: $showNhCDNVerify) {
            NhentaiCDNVerifyView()
        }
        #endif
        .alert("CORTEX PROTOCOL", isPresented: $showCortexActivation) {
            Button("ACKNOWLEDGE") {}
        } message: {
            Text(">> HIDDEN SUBSYSTEM UNLOCKED\n>> AGE VERIFICATION: ONLINE\n>> ACCESS LEVEL: ELEVATED\n\n// キャラクター管理に年齢機能が追加されました")
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                phoenixImportCount = FavoritesBackup.importBackup(from: url)
            }
        }
    }

    private func updateCacheSize() {
        readerCacheMB = ImageCache.shared.readerCacheSize() / 1_048_576
        thumbsCacheMB = ImageCache.shared.thumbsCacheSize() / 1_048_576
    }

    @ViewBuilder
    private var nhentaiSection: some View {
        Section("nhentai") {
            if nhLoggedIn {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
                    Text("ログイン済み")
                }
                Button("ログアウト", role: .destructive) {
                    NhentaiCookieManager.clearCookies()
                    nhLoggedIn = false
                }
            } else {
                HStack {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    Text("未ログイン")
                }
                Button("nhentaiにログイン") { showNhLogin = true }
                if UserDefaults.standard.string(forKey: "lastNhCookies") != nil {
                    Button("前回のログイン情報で復元") {
                        if NhentaiCookieManager.restoreFromBackup() {
                            nhLoggedIn = true
                        }
                    }
                }
            }

            // CDN Cloudflare認証（画像DLに必要）
            let hasCf = NhentaiCookieManager.hasCfClearance()
            HStack {
                Image(systemName: hasCf ? "shield.checkered" : "exclamationmark.shield")
                    .foregroundStyle(hasCf ? .green : .orange)
                Text(hasCf ? "CDN認証済み" : "CDN未認証")
            }
            Button("CDN認証（画像DL用）") { showNhCDNVerify = true }
                .foregroundColor(hasCf ? .secondary : .orange)
        }
    }

    private func languagePackStatus() -> String {
        let src = translationSourceLang
        let tgt = translationLang
        let srcName: String
        switch src {
        case "auto": srcName = "Auto"
        case "en": srcName = "English"
        case "zh-Hans": srcName = "中文(簡)"
        case "zh-Hant": srcName = "中文(繁)"
        case "ja": srcName = "日本語"
        case "ko": srcName = "한국어"
        default: srcName = src
        }
        let tgtName: String
        switch tgt {
        case "en": tgtName = "English"
        case "zh": tgtName = "中文"
        case "ja": tgtName = "日本語"
        case "ko": tgtName = "한국어"
        default: tgtName = tgt
        }
        return "\(srcName) → \(tgtName)"
    }
}

// MARK: - CHARACTER CENSUS View

struct CharacterCensusView: View {
    @Binding var stats: [(name: String, count: Int)]
    @Binding var ages: [String: Int]
    @Binding var ehTagCount: Int
    @Binding var nhTagCount: Int
    @Binding var isAnalyzing: Bool

    @AppStorage("cortexProtocolUnlocked") private var cortexUnlocked = false
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedCharacter: String?
    @State private var cortexSearchURL: URL?
    @State private var ageInputs: [String: String] = [:]
    @State private var showResetConfirm = false
    @State private var ageExportURL: URL?
    @State private var showAgeImport = false

    // キャッシュ: キャラ名 → 代表coverURL（初回アクセス時に構築）
    @State private var coverURLCache: [String: URL] = [:]

    private var filteredStats: [(name: String, count: Int)] {
        if searchText.isEmpty { return stats }
        return stats.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func coverURL(for characterName: String) -> URL? {
        if let cached = coverURLCache[characterName] { return cached }
        // E-Hentaiキャッシュから探す
        let ehFavs = FavoritesCache.shared.load()
        if let gallery = ehFavs.first(where: {
            $0.tags.contains(where: { $0.hasPrefix("character:") && $0.dropFirst("character:".count).localizedCaseInsensitiveContains(characterName) })
        }), let url = gallery.coverURL {
            DispatchQueue.main.async { coverURLCache[characterName] = url }
            return url
        }
        return nil
    }

    private func exportAges() -> URL? {
        guard !ages.isEmpty else { return nil }
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("cortex_character_ages.json")
        guard let data = try? JSONSerialization.data(withJSONObject: ages, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        try? data.write(to: file)
        return file
    }

    private func importAges(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let imported = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return }
        ages.merge(imported) { _, new in new }
    }

    private var averageAge: Double? {
        let entered = ages.values.filter { $0 > 0 }
        guard !entered.isEmpty else { return nil }
        return Double(entered.reduce(0, +)) / Double(entered.count)
    }

    var body: some View {
        NavigationStack {
            List {
                // Stats header
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(stats.count)")
                                .font(.title.monospaced().bold())
                                .foregroundStyle(.cyan)
                            Text("CHARACTERS")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if cortexUnlocked {
                            VStack(alignment: .trailing, spacing: 2) {
                                if let avg = averageAge {
                                    Text(String(format: "%.1f", avg))
                                        .font(.title.monospaced().bold())
                                        .foregroundStyle(.green)
                                    Text("AVG AGE (\(ages.count)/\(stats.count))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("---")
                                        .font(.title.monospaced().bold())
                                        .foregroundStyle(.secondary)
                                    Text("AVG AGE")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if isAnalyzing {
                        HStack {
                            ProgressView().tint(.cyan)
                            Text("E-Hentai APIからタグ取得中...")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.cyan)
                        }
                    }
                    Text("E-H: \(ehTagCount)件にキャラタグ / nh: \(nhTagCount)件にキャラタグ")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                // Character list
                Section {
                    ForEach(Array(filteredStats.enumerated()), id: \.element.name) { i, stat in
                        VStack(spacing: 0) {
                            HStack {
                                Text("\(i + 1).")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)

                                // 代表作サムネ
                                CachedImageView(url: coverURL(for: stat.name), host: KeychainService.load(key: "igneous") != nil ? .exhentai : .ehentai)
                                    .frame(width: 32, height: 45)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))

                                Button {
                                    selectedCharacter = stat.name
                                } label: {
                                    Text(stat.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                }

                                Spacer()

                                Text("x\(stat.count)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.cyan)

                                // Age badge (CORTEX PROTOCOL only)
                                if cortexUnlocked, let age = ages[stat.name] {
                                    Text("\(age)")
                                        .font(.caption.monospaced().bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.2))
                                        .foregroundStyle(.green)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .onTapGesture {
                                            ages.removeValue(forKey: stat.name)
                                        }
                                }

                                // Age search (CORTEX PROTOCOL only)
                                if cortexUnlocked {
                                    Button {
                                        let q = "\(stat.name) Animecharacter Age".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stat.name
                                        if let url = URL(string: "https://www.google.com/search?q=\(q)") {
                                            cortexSearchURL = url
                                        }
                                    } label: {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 10))
                                            .padding(4)
                                            .background(Color.cyan.opacity(0.15))
                                            .foregroundStyle(.cyan)
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // Age input (CORTEX PROTOCOL only)
                            if cortexUnlocked && ages[stat.name] == nil {
                                HStack {
                                    Spacer()
                                    TextField("Age", text: Binding(
                                        get: { ageInputs[stat.name] ?? "" },
                                        set: { ageInputs[stat.name] = $0 }
                                    ))
                                    .font(.caption.monospaced())
                                    .keyboardType(.numberPad)
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        if let val = ageInputs[stat.name], let age = Int(val), age > 0 {
                                            ages[stat.name] = age
                                            ageInputs.removeValue(forKey: stat.name)
                                        }
                                    }

                                    Button {
                                        if let val = ageInputs[stat.name], let age = Int(val), age > 0 {
                                            ages[stat.name] = age
                                            ageInputs.removeValue(forKey: stat.name)
                                        }
                                    } label: {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(Int(ageInputs[stat.name] ?? "") == nil)
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                } header: {
                    Text("RANKING")
                        .font(.caption.monospaced())
                }
            }
            .searchable(text: $searchText, prompt: "キャラクター検索")
            .navigationTitle("CHARACTER CENSUS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if cortexUnlocked && !ages.isEmpty {
                    ToolbarItemGroup(placement: .primaryAction) {
                        // エクスポート
                        if let url = ageExportURL {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        } else {
                            Button {
                                ageExportURL = exportAges()
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        // インポート
                        Button {
                            showAgeImport = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        // リセット
                        Button("リセット") { showResetConfirm = true }
                            .foregroundStyle(.red)
                    }
                }
            }
            .fileImporter(isPresented: $showAgeImport, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    importAges(from: url)
                }
            }
            .alert("年齢データをリセット", isPresented: $showResetConfirm) {
                Button("全削除", role: .destructive) { ages.removeAll() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("登録済みの年齢データ(\(ages.count)件)を全て削除しますか？")
            }
            .sheet(item: $cortexSearchURL) { url in
                InAppBrowserView(url: url)
            }
            .sheet(item: $selectedCharacter) { name in
                CharacterWorksView(characterName: name)
            }
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Character Works View

struct CharacterWorksView: View {
    let characterName: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEhGallery: Gallery?
    @State private var selectedNhGallery: NhentaiClient.NhGallery?

    private var ehWorks: [Gallery] {
        FavoritesCache.shared.load().filter { gallery in
            gallery.tags.contains(where: {
                $0.hasPrefix("character:") && $0.dropFirst("character:".count).localizedCaseInsensitiveContains(characterName)
            })
        }
    }

    private var nhWorks: [NhentaiClient.NhGallery] {
        NhentaiFavoritesCache.shared.load().filter { gallery in
            (gallery.tags ?? []).contains {
                $0.type == "character" && $0.name.localizedCaseInsensitiveContains(characterName)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !ehWorks.isEmpty {
                    Section("E-Hentai (\(ehWorks.count))") {
                        ForEach(ehWorks) { gallery in
                            Button {
                                selectedEhGallery = gallery
                            } label: {
                                HStack(spacing: 10) {
                                    CachedImageView(url: gallery.coverURL, host: KeychainService.load(key: "igneous") != nil ? .exhentai : .ehentai)
                                        .frame(width: 45, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(gallery.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text("GID: \(gallery.gid)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if !nhWorks.isEmpty {
                    Section("nhentai (\(nhWorks.count))") {
                        ForEach(nhWorks) { gallery in
                            Button {
                                selectedNhGallery = gallery
                            } label: {
                                HStack(spacing: 10) {
                                    if let cover = gallery.images?.cover {
                                        AsyncImage(url: NhentaiClient.coverURL(mediaId: gallery.media_id, ext: cover.ext, path: cover.path)) { image in
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        } placeholder: {
                                            Color.gray.opacity(0.2)
                                        }
                                        .frame(width: 45, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(gallery.displayTitle)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text("ID: \(gallery.id)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if ehWorks.isEmpty && nhWorks.isEmpty {
                    Text("作品が見つかりません")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(characterName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(item: $selectedEhGallery) { gallery in
                NavigationStack {
                    GalleryDetailView(gallery: gallery, host: KeychainService.load(key: "igneous") != nil ? .exhentai : .ehentai)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("閉じる") { selectedEhGallery = nil }
                            }
                        }
                }
            }
            #if canImport(UIKit)
            .fullScreenCover(item: $selectedNhGallery) { nh in
                NhentaiDetailView(gallery: nh)
            }
            #endif
        }
    }
}
