import SwiftUI
import Combine
import LocalAuthentication

extension Notification.Name {
    /// 設定タブへ遷移を要求する通知（NhentaiDetailView などから）
    static let navigateToSettingsTab = Notification.Name("Cortex.navigateToSettingsTab")
    /// 保存済みタブへ遷移を要求する通知（詳細画面でDL開始時）
    static let navigateToDownloadsTab = Notification.Name("Cortex.navigateToDownloadsTab")
}

struct ContentView: View {
    @StateObject private var authVM = AuthViewModel()
    @ObservedObject private var bioAuth = BiometricAuth.shared
    @ObservedObject private var pinManager = PINManager.shared
    /// CUI から reader 直接 open する用の bus (cortex:// scheme で書き換えられる)。
    @ObservedObject private var cortexBus = CortexCommandBus.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var lockBlur: CGFloat = 30
    @State private var lockTiles: [LockTile] = []
    @State private var lockScrollOffset: CGFloat = 0
    @StateObject private var lockDisplayLink = DisplayLinkDriver()
    @AppStorage("appTheme") private var appTheme = 0
    @ObservedObject private var safetyMode = SafetyMode.shared
    @ObservedObject private var ecoMode = EcoMode.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @State private var dangerPulse = false
    @State private var greenFlash = false
    @State private var greenOpacity: Double = 0
    @State private var importToast: String?
    @State private var selectedTab = 0
    private var colorScheme: ColorScheme? {
        switch appTheme {
        case 1: return .dark
        case 2: return .light
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            mainContent
                .disabled(showLockScreen && bioAuth.isLockActive)
                .opacity(showLockScreen && bioAuth.isLockActive ? 0 : 1)

            if showLockScreen && bioAuth.isLockActive {
                lockScreen
                    .transition(.opacity)
            }

        }
        .overlay {
            // safety OFF = 旧 EXTREME 相当で危険、赤ボーダー
            if !safetyMode.isEnabled {
                RoundedRectangle(cornerRadius: Self.screenCornerRadius)
                    .stroke(Color.red, lineWidth: 2.5)
                    .opacity(dangerPulse ? 1.0 : 0.5)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                            dangerPulse = true
                        }
                    }
                    .onDisappear { dangerPulse = false }
            }
            if greenFlash {
                RoundedRectangle(cornerRadius: Self.screenCornerRadius)
                    .stroke(Color.green, lineWidth: 2.5)
                    .opacity(greenOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            DebugVitalsHUD()
                .padding(.top, 48)
                .padding(.trailing, 8)
                .allowsHitTesting(false)
        }
        .onChange(of: safetyMode.isEnabled) { old, new in
            // safety OFF → ON = 安全に戻った = 緑フラッシュ 2 回で安心 feedback
            if !old && new {
                greenFlash = true
                greenOpacity = 0
                Task {
                    withAnimation(.easeIn(duration: 0.4)) { greenOpacity = 1 }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    withAnimation(.easeOut(duration: 0.4)) { greenOpacity = 0 }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    withAnimation(.easeIn(duration: 0.4)) { greenOpacity = 1 }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    withAnimation(.easeOut(duration: 0.4)) { greenOpacity = 0 }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    greenFlash = false
                }
            }
        }
        .preferredColorScheme(colorScheme)
        .onOpenURL { url in
            // CUI debug 用 cortex:// scheme は CortexURLRouter で処理 (非破壊で追加、田中指示 2026-04-25)
            if url.scheme == "cortex" {
                _ = CortexURLRouter.handle(url)
                return
            }
            // AirDrop/ファイル等から.cortexまたは.zipを受信
            let ext = url.pathExtension.lowercased()
            guard ext == "cortex" || ext == "zip" else { return }
            // 大容量 ZIP は数秒かかる → main thread ブロックで watchdog kill 回避のため
            // background thread へ逃がす。import 中は toast で進行中を示す
            importToast = "インポート中..."
            LogManager.shared.log("Export", "onOpenURL: start import url=\(url.lastPathComponent)")
            Task.detached(priority: .userInitiated) {
                let result = GalleryExporter.importFromZip(url: url)
                await MainActor.run {
                    if result != nil {
                        importToast = "インポート完了"
                        withAnimation { selectedTab = 3 }
                    } else {
                        importToast = "インポート失敗"
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { importToast = nil }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSettingsTab)) { _ in
            withAnimation { selectedTab = 6 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDownloadsTab)) { _ in
            withAnimation { selectedTab = 3 }
        }
        // cortex:// scheme から reader 直接 open (Phase B、田中指示 2026-04-25)。
        // 既存の navigation 経由 (一覧 → 詳細 → reader) は触らず、ContentView レベルの
        // 独立 fullScreenCover で表示。bus を nil にすると閉じる (cortex://reader/close)。
        .fullScreenCover(item: $cortexBus.openOnlineReader) { req in
            let host: GalleryHost = req.hostName == "exhentai" ? .exhentai : .ehentai
            let gallery = Gallery(
                gid: req.gid, token: req.token, title: "(cortex debug)",
                category: nil, coverURL: nil, rating: 0, pageCount: 999,
                postedDate: "", uploader: nil, tags: []
            )
            GalleryReaderView(gallery: gallery, host: host, initialPage: req.page)
        }
        .fullScreenCover(item: $cortexBus.openLocalReader) { req in
            if let meta = DownloadManager.shared.downloads[req.gid] {
                LocalReaderView(meta: meta, isLiveDownload: false, initialPage: req.page)
            } else {
                Text("Local gallery not found for gid=\(req.gid)")
                    .padding()
                    .onAppear {
                        LogManager.shared.log("CortexURL", "local reader meta missing gid=\(req.gid)")
                    }
            }
        }
        .overlay {
            if let toast = importToast {
                VStack {
                    Text(toast)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.green.opacity(0.9))
                        .clipShape(Capsule())
                        .padding(.top, 60)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeOut(duration: 0.3), value: importToast)
            }
        }
        .overlay(alignment: .top) {
            if ecoMode.isEnabled {
                HStack(spacing: 4) {
                    Image(systemName: "leaf.fill")
                        .font(.caption2)
                    Text("ECO")
                        .font(.caption2.bold())
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.green.opacity(0.15))
                .clipShape(Capsule())
                .padding(.top, 55)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if networkMonitor.showOfflineBanner {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.slash")
                        .font(.caption2)
                    Text("オフライン")
                        .font(.caption2.bold())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.red.opacity(0.85))
                .clipShape(Capsule())
                .padding(.top, ecoMode.isEnabled ? 75 : 55)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeOut(duration: 0.3), value: networkMonitor.showOfflineBanner)
            }
        }
        .alert("モバイルデータ通信", isPresented: $networkMonitor.showCellularPrompt) {
            Button("続行") { networkMonitor.allowCellularDownload = true }
            Button("停止") { }
            Button("常に許可") {
                networkMonitor.allowCellularDownload = true
            }
        } message: {
            Text("WiFiが切断されました。モバイルデータでダウンロードを続けますか？")
        }
        .onAppear {
            showLockScreen = !bioAuth.isUnlocked
            if bioAuth.isLockActive && !bioAuth.isUnlocked {
                bioAuth.authenticate()
                #if os(iOS)
                AppDelegate.orientationLock = .portrait
                #endif
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                bioAuth.lock()
                showLockScreen = true
                lockBlur = 30
                #if os(iOS)
                AppDelegate.orientationLock = .portrait
                #endif
            } else if phase == .active && bioAuth.isLockActive && !bioAuth.isUnlocked {
                bioAuth.authenticate()
            }
        }
        .onChange(of: bioAuth.isUnlocked) { _, unlocked in
            if unlocked {
                // ブラー解除→サムネくっきり表示→通常画面
                withAnimation(.easeOut(duration: 0.3)) {
                    lockBlur = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showLockScreen = false
                    }
                    lockDisplayLink.stop()
                    #if os(iOS)
                    AppDelegate.orientationLock = .all
                    #endif
                }
            }
        }
    }

    @State private var showLockScreen = true

    private static var screenCornerRadius: CGFloat {
        #if os(iOS)
        // UIScreen.main の _displayCornerRadius を安全に取得
        let screen = UIScreen.main
        if let radius = screen.value(forKey: "_displayCornerRadius") as? CGFloat, radius > 0 {
            return radius
        }
        // フォールバック: iPhoneは55、iPadは20
        return UIDevice.current.userInterfaceIdiom == .pad ? 20 : 55
        #else
        return 10
        #endif
    }

    private var isLocked: Bool {
        bioAuth.isLockActive && !bioAuth.isUnlocked
    }

    @ObservedObject private var downloadManager = DownloadManager.shared

    private var mainContent: some View {
        #if targetEnvironment(macCatalyst)
        // Catalyst: TabView は macOS ネイティブ tab bar に bridge され、幅不足時に
        // overflow menu (>>) に畳まれる。常に全タブ横並び表示にするため独自 HStack に置換。
        VStack(spacing: 0) {
            CatalystTabBar(selection: $selectedTab, activeDownloadCount: downloadManager.activeDownloadCount)
            Group {
                switch selectedTab {
                case 0: GalleryListView(authVM: authVM)
                case 1: FavoritesView(authVM: authVM)
                case 2: GachaView()
                case 3: DownloadsView()
                case 4: HistoryView()
                case 5: CharacterManagementTab()
                case 6: SettingsView(authVM: authVM)
                default: EmptyView()
                }
            }
        }
        .sheet(isPresented: $authVM.showingLogin) {
            LoginView(authVM: authVM)
        }
        #else
        TabView(selection: $selectedTab) {
            GalleryListView(authVM: authVM)
                .tabItem { Label("ギャラリー", systemImage: "photo.on.rectangle.angled") }
                .tag(0)
            FavoritesView(authVM: authVM)
                .tabItem { Label("お気に入り", systemImage: "heart.fill") }
                .tag(1)
            GachaView()
                .tabItem { Label("ガチャ", systemImage: "dice.fill") }
                .tag(2)
            DownloadsView()
                .tabItem { Label("保存済み", systemImage: "arrow.down.circle.fill") }
                .badge(downloadManager.activeDownloadCount)
                .tag(3)
            HistoryView()
                .tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
                .tag(4)
            CharacterManagementTab()
                .tabItem { Label("お気に入りキャラクター管理", systemImage: "person.2.fill") }
                .tag(5)
            SettingsView(authVM: authVM)
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(6)
        }
        .sheet(isPresented: $authVM.showingLogin) {
            LoginView(authVM: authVM)
        }
        #endif
    }

    // MARK: - ロック画面

    struct LockTile: Identifiable {
        let id = UUID()
        let image: PlatformImage
        var x: CGFloat
        var y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private var lockScreen: some View {
        ZStack {
            // 背景: サムネ無限スクロール + ブラー
            lockBackground
                .blur(radius: lockBlur)
                .ignoresSafeArea()

            // 暗めオーバーレイ
            Color.black.opacity(0.3).ignoresSafeArea()

            if bioAuth.showPINInput {
                pinInputScreen
            } else {
                faceIDScreen
            }
        }
        .onAppear {
            buildLockTiles()
            lockDisplayLink.onFrame = { scrollLockTiles() }
            lockDisplayLink.start()
            lockBlur = 30
        }
        .onDisappear {
            lockDisplayLink.stop()
        }
    }

    private var lockBackground: some View {
        let _ = lockDisplayLink.tick
        #if os(iOS)
        let screenH = UIScreen.main.bounds.height + 60
        #else
        let screenH: CGFloat = 900
        #endif

        return ZStack {
            Color.black
            ForEach(lockTiles) { tile in
                let sy = tile.y + lockScrollOffset
                if sy > -tile.height && sy < screenH + tile.height {
                    Image(platformImage: tile.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tile.width, height: tile.height)
                        .clipped()
                        .position(x: tile.x + tile.width / 2, y: sy + tile.height / 2)
                }
            }
        }
    }

    private func buildLockTiles() {
        var images: [PlatformImage] = []
        for g in FavoritesCache.shared.load().shuffled() {
            if let url = g.coverURL, let img = ImageCache.shared.image(for: url) {
                images.append(img)
            }
            if images.count >= 20 { break }
        }
        guard !images.isEmpty else { return }

        #if os(iOS)
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        #else
        let w: CGFloat = 400; let h: CGFloat = 900
        #endif

        let cols = 4
        let tileW = w / CGFloat(cols)
        let tileH = tileW * 1.4
        let rows = max(12, Int(ceil(h * 3 / tileH)))

        lockTiles = (0..<(rows * cols)).map { i in
            let row = i / cols, col = i % cols
            return LockTile(
                image: images[i % images.count],
                x: CGFloat(col) * tileW, y: CGFloat(row) * tileH,
                width: tileW, height: tileH
            )
        }
        lockScrollOffset = 0
    }

    private static func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let table = greetingTable(lang: lang)
        let key: Int
        switch hour {
        case 5..<9: key = 0
        case 9..<12: key = 1
        case 12..<14: key = 2
        case 14..<17: key = 3
        case 17..<21: key = 4
        case 21...23, 0: key = 5
        default: key = 6
        }
        let messages = table[key]
        return messages.randomElement() ?? ""
    }

    // 7時間帯 × 多言語メッセージ
    private static func greetingTable(lang: String) -> [[String]] {
        switch lang {
        case "ja":
            return [
                ["おはようございます", "早起きですね", "朝の一冊はいかが？"],
                ["良い午前を", "何を読みましょうか"],
                ["お昼休みですか？", "ランチのお供に"],
                ["午後もお楽しみに", "いい作品見つかるかも"],
                ["おかえりなさい", "夜のお供はいかが？"],
                ["夜更かしですか？", "今日のおすすめを引いてみては", "まだ寝ないの？"],
                ["深夜ですよ…", "そろそろ寝ましょう", "お体に気をつけて"],
            ]
        case "zh":
            return [
                ["早上好", "起得真早", "来一本晨读？"],
                ["上午好", "读点什么？"],
                ["午休时间？", "休息一下？"],
                ["下午好", "也许能找到好作品"],
                ["欢迎回来", "来点夜读？"],
                ["还没睡？", "来一发？", "夜猫子？"],
                ["太晚了...", "该睡了吧？", "注意身体"],
            ]
        case "ko":
            return [
                ["좋은 아침", "일찍 일어났네요", "아침 독서 어때요?"],
                ["좋은 오전", "뭘 읽을까요?"],
                ["점심시간?", "쉬면서 한 편?"],
                ["좋은 오후", "좋은 작품 있을지도"],
                ["다녀왔어요", "저녁 독서?"],
                ["아직 안 자요?", "한 편 어때요?", "올빼미시군요?"],
                ["늦었어요...", "이제 자야죠?", "몸 조심하세요"],
            ]
        case "fr":
            return [
                ["Bonjour", "Lève-tôt !", "Une lecture matinale ?"],
                ["Bonne matinée", "Que lire ?"],
                ["Pause déjeuner ?", "Un petit moment ?"],
                ["Bon après-midi", "Peut-être une trouvaille"],
                ["Bon retour", "Lecture du soir ?"],
                ["Encore debout ?", "Un petit tirage ?", "Noctambule ?"],
                ["Il est tard...", "Au lit ?", "Prenez soin de vous"],
            ]
        case "de":
            return [
                ["Guten Morgen", "Frühaufsteher!", "Morgenlektüre?"],
                ["Guten Vormittag", "Was lesen wir?"],
                ["Mittagspause?", "Eine kleine Pause?"],
                ["Guten Nachmittag", "Vielleicht was Gutes"],
                ["Willkommen zurück", "Abendlektüre?"],
                ["Noch wach?", "Wie wär's?", "Nachteule?"],
                ["Es ist spät...", "Ab ins Bett?", "Pass auf dich auf"],
            ]
        case "es":
            return [
                ["Buenos días", "¡Madrugador!", "¿Lectura matutina?"],
                ["Buena mañana", "¿Qué leemos?"],
                ["¿Hora del almuerzo?", "¿Un descanso?"],
                ["Buenas tardes", "Quizás algo bueno"],
                ["Bienvenido", "¿Lectura nocturna?"],
                ["¿Aún despierto?", "¿Un tirada?", "¿Noctámbulo?"],
                ["Es tarde...", "¿A dormir?", "Cuídate"],
            ]
        default: // English
            return [
                ["Good morning", "Early bird!", "Morning read?"],
                ["Good morning", "What shall we read?"],
                ["Lunch break?", "A quick read?"],
                ["Good afternoon", "Maybe something good"],
                ["Welcome back", "Evening read?"],
                ["Still up?", "How about a pick?", "Night owl?"],
                ["It's late...", "Time to sleep?", "Take care"],
            ]
        }
    }

    private func scrollLockTiles() {
        lockScrollOffset -= 0.5
        guard let first = lockTiles.first,
              let minY = lockTiles.map(\.y).min(),
              let maxY = lockTiles.map(\.y).max() else { return }
        let tileH = first.height
        let totalH = maxY - minY + tileH
        for i in lockTiles.indices {
            if lockTiles[i].y + lockScrollOffset < -tileH {
                lockTiles[i].y += totalH
            }
        }
    }

    @State private var greetingMessage = ""

    private var biometryIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }

    private var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "パスコード"
        }
    }

    private var faceIDScreen: some View {
        VStack(spacing: 24) {
            Image(systemName: biometryIcon)
                .font(.system(size: 60))
                .foregroundStyle(.white.opacity(0.7))

            Text("Cort:EX")
                .font(.title).fontWeight(.bold).foregroundStyle(.white)

            Text(greetingMessage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .onAppear { greetingMessage = Self.greeting() }

            if bioAuth.authFailed {
                Text("認証に失敗しました")
                    .font(.caption).foregroundStyle(.red)
            }

            VStack(spacing: 12) {
                if bioAuth.authFailed && pinManager.hasPIN {
                    Button {
                        bioAuth.showPINInput = true
                    } label: {
                        Label("PINで解除", systemImage: "lock.fill")
                            .font(.headline).padding()
                            .frame(maxWidth: 240)
                            .background(.blue).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                Button {
                    bioAuth.authenticate()
                } label: {
                    Label(bioAuth.authFailed ? "\(biometryName)で再試行" : "ロックを解除", systemImage: biometryIcon)
                        .font(.subheadline).padding(.vertical, 10)
                        .frame(maxWidth: 240)
                        .background(bioAuth.authFailed ? Color.gray.opacity(0.15) : .blue)
                        .foregroundStyle(bioAuth.authFailed ? Color.primary : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    @State private var pinInputID = UUID()

    private var pinInputScreen: some View {
        VStack(spacing: 16) {
            if pinManager.isLockedOut {
                lockoutView
            } else {
                PINInputView(title: "PINを入力") { pin in
                    if pinManager.verify(pin) {
                        bioAuth.pinVerified()
                    } else {
                        // 入力IDを変えて再レンダリング（エラーリセット）
                        pinInputID = UUID()
                        if pinManager.isLockedOut {
                            // ロックアウトに入った
                        }
                    }
                }
                .id(pinInputID)

                if pinManager.failedAttempts > 0 {
                    Text("PINが違います（残り\(3 - pinManager.failedAttempts)回）")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            if bioAuth.isEnabled {
                Button {
                    bioAuth.retryFaceID()
                } label: {
                    Label("\(biometryName)で再試行", systemImage: biometryIcon)
                        .font(.subheadline).padding(.vertical, 10)
                        .frame(maxWidth: 240)
                        .background(Color.gray.opacity(0.15))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var lockoutView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 50))
                .foregroundStyle(.red)

            Text("PINロック中")
                .font(.title3).fontWeight(.semibold)

            Text("\(pinManager.lockoutRemaining)秒後に再試行できます")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - キャラクター管理タブ

struct CharacterManagementTab: View {
    @State private var characterStats: [(name: String, count: Int)] = []
    @State private var isAnalyzing = false
    @State private var characterAges: [String: Int] = {
        (UserDefaults.standard.dictionary(forKey: "cortex_character_ages") as? [String: Int]) ?? [:]
    }()
    @State private var ehTagCount = 0
    @State private var nhTagCount = 0

    var body: some View {
        CharacterCensusView(
            stats: $characterStats,
            ages: $characterAges,
            ehTagCount: $ehTagCount,
            nhTagCount: $nhTagCount,
            isAnalyzing: $isAnalyzing
        )
        .onAppear {
            if characterStats.isEmpty { analyzeCharacters() }
        }
        .onChange(of: characterAges) { _, newAges in
            UserDefaults.standard.set(newAges, forKey: "cortex_character_ages")
        }
    }

    private func analyzeCharacters() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        Task {
            var counts: [String: Int] = [:]
            var ehWith = 0, nhWith = 0

            let ehFavs = FavoritesCache.shared.load()
            let apiTagged = UserDefaults.standard.bool(forKey: "cortex_eh_tags_fetched")
            let needsApi = apiTagged ? ehFavs.filter { $0.tags.isEmpty } : ehFavs
            let cached = apiTagged ? ehFavs.filter { !$0.tags.isEmpty } : []

            for g in cached {
                let chars = g.tags.filter { $0.hasPrefix("character:") }
                if !chars.isEmpty { ehWith += 1 }
                for t in chars { counts[String(t.dropFirst("character:".count)), default: 0] += 1 }
            }
            if !needsApi.isEmpty {
                let tagMap = await EhClient.shared.fetchGalleryTags(galleries: needsApi)
                var updated = ehFavs
                for i in updated.indices {
                    if let tags = tagMap[updated[i].gid], !tags.isEmpty { updated[i].tags = tags }
                }
                FavoritesCache.shared.save(updated)
                UserDefaults.standard.set(true, forKey: "cortex_eh_tags_fetched")
                for (_, tags) in tagMap {
                    let chars = tags.filter { $0.hasPrefix("character:") }
                    if !chars.isEmpty { ehWith += 1 }
                    for t in chars { counts[String(t.dropFirst("character:".count)), default: 0] += 1 }
                }
            }

            let nhFavs = NhentaiFavoritesCache.shared.load()
            for g in nhFavs {
                let chars = (g.tags ?? []).filter { $0.type == "character" }
                if !chars.isEmpty { nhWith += 1 }
                for t in chars { counts[t.name, default: 0] += 1 }
            }

            let maleProtags: Set<String> = ["sensei", "teitoku", "gudao", "producer", "shikikan",
                                            "admiral", "master", "commander", "protagonist"]
            let filtered = counts.filter { !maleProtags.contains($0.key.lowercased()) }

            await MainActor.run {
                ehTagCount = ehWith; nhTagCount = nhWith
                characterStats = filtered.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
                isAnalyzing = false
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// Mac Catalyst 専用の上部タブバー。SwiftUI TabView を使うと overflow menu に
/// 畳まれる仕様回避のため独自 HStack 実装。iOS は既存 TabView のまま。
struct CatalystTabBar: View {
    @Binding var selection: Int
    let activeDownloadCount: Int

    private let tabs: [(tag: Int, title: String, icon: String)] = [
        (0, "ギャラリー", "photo.on.rectangle.angled"),
        (1, "お気に入り", "heart.fill"),
        (2, "ガチャ", "dice.fill"),
        (3, "保存済み", "arrow.down.circle.fill"),
        (4, "履歴", "clock.arrow.circlepath"),
        (5, "お気に入りキャラクター管理", "person.2.fill"),
        (6, "設定", "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.tag) { tab in
                HStack(spacing: 6) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12))
                    Text(tab.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if tab.tag == 3 && activeDownloadCount > 0 {
                        Text("\(activeDownloadCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .foregroundStyle(
                    selection == tab.tag ? Color.accentColor : Color.primary
                )
                .background(
                    // アクティブ時は accent、非アクティブ時も extremely subtle な fill を置く。
                    // Mac Catalyst は完全透明 or 極小 alpha (Color.X.opacity(0.0001) 等) を
                    // hit test 最適化で落とすことがあるので、視覚的には見えないが
                    // runtime では確実に hittable な alpha=0.001 の白を敷く。
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            selection == tab.tag
                                ? Color.accentColor.opacity(0.15)
                                : Color.white.opacity(0.001)
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = tab.tag
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
#endif

