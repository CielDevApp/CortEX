import SwiftUI
import UniformTypeIdentifiers
import TipKit

struct SettingsView: View {
    @ObservedObject var authVM: AuthViewModel
    @State private var readerCacheMB: Int = 0
    @State private var thumbsCacheMB: Int = 0
    @State private var animatedCacheMB: Int = 0
    @State private var showClearAnimatedConfirm = false
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
    @State private var showAnimationModeResetConfirm = false
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
    @ObservedObject private var safetyMode = SafetyMode.shared
    @ObservedObject private var ecoMode = EcoMode.shared
    @State private var showDisableSafetyConfirm = false
    @State private var tipsReset = false
    @State private var showNhLogin = false
    @State private var showNhCDNVerify = false
    @State private var nhLoggedIn = NhentaiCookieManager.isLoggedIn()
    // nhentai ID/PW フォーム自動入力用
    @State private var nhUsername: String = KeychainService.load(key: "nh_username") ?? ""
    @State private var nhPassword: String = KeychainService.load(key: "nh_password") ?? ""
    @State private var showPasswordField: Bool = false
    @State private var nhCredSaved: Bool = false
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
                        Text("Cort:EX ver.02a f5")
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

                    Button("動画ギャラリーのモード選択をリセット") {
                        showAnimationModeResetConfirm = true
                    }
                    .foregroundStyle(.orange)
                    Text("動画 WebP を含むギャラリー毎に保存した「横/縦」選択を全て消去します。")
                        .font(.caption2).foregroundStyle(.secondary)
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
                    HStack { Text("動画キャッシュ"); Spacer()
                        Text("\(animatedCacheMB)MB").foregroundStyle(.secondary)
                    }
                    if isOverLimit {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text("リーダーキャッシュが上限を超えています").font(.caption).foregroundStyle(.red)
                        }
                    }
                    Button("リーダーキャッシュを削除", role: .destructive) { showClearConfirm = true }
                    Button("サムネキャッシュも削除", role: .destructive) { ImageCache.shared.clearThumbsCache(); updateCacheSize() }
                    Button("動画キャッシュを削除", role: .destructive) { showClearAnimatedConfirm = true }
                    let dlCount = DownloadManager.shared.downloads.count
                    HStack { Text("保存済みギャラリー"); Spacer(); Text("\(dlCount)件").foregroundStyle(.secondary) }
                    Button("全ダウンロードデータを削除", role: .destructive) { showClearDownloads = true }
                }

                // 8. ベンチマーク
                Section("ベンチマーク") {
                    Button("ベンチマーク実行") { showBenchmark = true }
                    Text("CIFilter vs Metal の処理速度を計測します。").font(.caption2).foregroundStyle(.secondary)
                }

                // 9. SAFETY MODE (最下部)
                Section {
                    Toggle("セーフティモード", isOn: Binding(
                        get: { safetyMode.isEnabled },
                        set: { newValue in
                            if newValue {
                                safetyMode.isEnabled = true
                            } else {
                                showDisableSafetyConfirm = true
                            }
                        }
                    )).tint(.green)
                    if !safetyMode.isEnabled {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text("セーフティモード OFF — BAN リスクあり").font(.caption.bold()).foregroundStyle(.red)
                        }
                    } else {
                        HStack {
                            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                            Text("セーフティモード ON — BAN 予防機能が有効").font(.caption.bold()).foregroundStyle(.green)
                        }
                    }
                    Text("""
                    セーフティモード ON 時の動作:
                    • サムネ並列接続: 6 (OFF: 20)
                    • サムネ prefetch: 50 件上限 (OFF: 100)
                    • DL URL 解決: 50 画面毎に 60s cooldown
                    • fetchThumbData に BAN 検知
                    • 全ネットワークに 2s delay 適用

                    画像 DL 本体 (H@H 経由) はモードに関わらず通常速度を維持。
                    """).font(.caption2).foregroundStyle(.secondary)
                } header: {
                    if !safetyMode.isEnabled {
                        Label("セーフティモード", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else { Text("セーフティモード") }
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
            .alert("動画キャッシュを削除", isPresented: $showClearAnimatedConfirm) {
                Button("削除", role: .destructive) {
                    WebPToMP4Converter.clearAnimatedCache()
                    updateCacheSize()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("変換済みMP4キャッシュ(\(animatedCacheMB)MB)を削除しますか？次回リーダー表示時に再変換されます。")
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
            .alert("動画ギャラリーのモード選択をリセット", isPresented: $showAnimationModeResetConfirm) {
                Button("リセット", role: .destructive) {
                    DownloadManager.shared.resetAllReaderModeOverrides()
                    UserDefaults.standard.set(true, forKey: "animationDialogDontAskDefault")
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("動画 WebP を含む全ギャラリーで保存した「横/縦」選択を削除します。次回 Reader 起動時に再度ダイアログが表示されます。")
            }
            .alert("セーフティモードを OFF にしますか？", isPresented: $showDisableSafetyConfirm) {
                Button("OFF にする (自己責任)", role: .destructive) {
                    safetyMode.isEnabled = false
                }
                Button("ON のまま維持", role: .cancel) {}
            } message: {
                Text("セーフティモードを OFF にすると BAN 対策ディレイとレート制限が無効化されます。E-Hentai アカウントで BAN を踏むと 1 時間 (2 回目同日は 5 時間) サービスが使えなくなります。\n\n画像本体 DL は影響を受けませんが、サムネ取得・URL 解決・お気に入り取得などで BAN リスクが大幅に増えます。自己責任で進めてください。")
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
        .onReceive(NotificationCenter.default.publisher(for: .nhentaiLoginStateChanged)) { _ in
            nhLoggedIn = NhentaiCookieManager.isLoggedIn()
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
        animatedCacheMB = Int(WebPToMP4Converter.animatedCacheSize() / 1_048_576)
    }

    @ViewBuilder
    private var nhentaiSection: some View {
        Group {
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

        nhCredentialsSection
        }
    }

    // MARK: - nhentai ID/PW 保存（自動入力 + クリップボードコピー）

    private var nhCredentialsSection: some View {
        Section {
            TextField("ユーザー名 or メール", text: $nhUsername)
                .textContentType(.username)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            HStack {
                if showPasswordField {
                    TextField("パスワード", text: $nhPassword)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } else {
                    SecureField("パスワード", text: $nhPassword)
                        .textContentType(.password)
                }
                Button {
                    showPasswordField.toggle()
                } label: {
                    Image(systemName: showPasswordField ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Button(nhCredSaved ? "保存済み ✓" : "保存") {
                    KeychainService.save(key: "nh_username", value: nhUsername)
                    KeychainService.save(key: "nh_password", value: nhPassword)
                    nhCredSaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { nhCredSaved = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(nhUsername.isEmpty && nhPassword.isEmpty)

                Button("クリア", role: .destructive) {
                    KeychainService.delete(key: "nh_username")
                    KeychainService.delete(key: "nh_password")
                    nhUsername = ""
                    nhPassword = ""
                    nhCredSaved = false
                }
                .disabled(nhUsername.isEmpty && nhPassword.isEmpty)
            }

            // クリップボードコピー
            #if canImport(UIKit)
            if !nhUsername.isEmpty {
                Button {
                    UIPasteboard.general.string = nhUsername
                } label: {
                    Label("ユーザー名をコピー", systemImage: "doc.on.doc")
                }
            }
            if !nhPassword.isEmpty {
                Button {
                    UIPasteboard.general.string = nhPassword
                } label: {
                    Label("パスワードをコピー", systemImage: "key")
                }
            }
            #endif
        } header: {
            Text("nhentai ログイン情報")
        } footer: {
            Text("保存するとログイン画面を開いた時にフォームへ自動入力されます。Cloudflare突破とログインボタン押下は手動です。")
                .font(.caption2)
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

    // キャッシュ: キャラ名 → (代表coverURL, gid) をまとめてプリコンピュート (O(N*M) を一回で済ます)。
    // stats / FavoritesCache が変わるまでスクロール中は使い回し。
    @State private var coverURLCache: [String: URL] = [:]
    @State private var coverGidCache: [String: Int] = [:]
    /// KeychainService.load の結果も毎 cell 読まないようにキャッシュ。
    @State private var cachedIsExhentai: Bool = false

    private var filteredStats: [(name: String, count: Int)] {
        if searchText.isEmpty { return stats }
        return stats.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// stats が更新された時に一度だけ全キャラの coverURL / gid を構築する。
    /// ForEach 内で毎回 FavoritesCache.shared.load() を叩くとスクロール重くなるため。
    private func rebuildCoverCache() {
        let ehFavs = FavoritesCache.shared.load()
        var urlMap: [String: URL] = [:]
        var gidMap: [String: Int] = [:]
        for stat in stats {
            let lowerName = stat.name
            if let g = ehFavs.first(where: {
                $0.tags.contains(where: { $0.hasPrefix("character:") && $0.dropFirst("character:".count).localizedCaseInsensitiveContains(lowerName) })
            }) {
                if let url = g.coverURL { urlMap[stat.name] = url }
                gidMap[stat.name] = g.gid
            }
        }
        coverURLCache = urlMap
        coverGidCache = gidMap
        cachedIsExhentai = KeychainService.load(key: "igneous") != nil
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

                                // 代表作サムネ (cache からルックアップ、毎スクロール時の O(N*M) 検索を回避)
                                // .drawingGroup() で Metal offscreen composition、スクロール中の
                                // ラスタライズ負荷を GPU に逃がす。
                                CachedImageView(url: coverURLCache[stat.name], host: cachedIsExhentai ? .exhentai : .ehentai, gid: coverGidCache[stat.name])
                                    .frame(width: 32, height: 45)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .drawingGroup()

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
            .task(id: stats.count) {
                rebuildCoverCache()
            }
            .toolbar {
                if cortexUnlocked {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // エクスポート
                        if !ages.isEmpty {
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
                        }
                        // インポート
                        Button {
                            showAgeImport = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        // リセット
                        if !ages.isEmpty {
                            Button("リセット") { showResetConfirm = true }
                                .foregroundStyle(.red)
                        }
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
                                    CachedImageView(url: gallery.coverURL, host: KeychainService.load(key: "igneous") != nil ? .exhentai : .ehentai, gid: gallery.gid)
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
