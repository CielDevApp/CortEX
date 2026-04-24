import SwiftUI
import UserNotifications
import TipKit
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 回転制御フラグ（コレクションモード時に.portraitに制限）
    static var orientationLock: UIInterfaceOrientationMask = .all

    /// プライバシー保護用Window
    private var privacyWindow: UIWindow?

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // AppSwitcherプライバシー保護
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        #if targetEnvironment(macCatalyst)
        // Catalyst のタイトルバー下に出る 1px separator を消す。
        // UINavigationBarAppearance の shadowColor = .clear で navigation bar 側、
        // UIScene.willConnect で windowScene.titlebar 側、両方消す。
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.shadowColor = .clear
        appearance.shadowImage = UIImage()
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        NotificationCenter.default.addObserver(
            self, selector: #selector(hideTitlebarSeparator),
            name: UIScene.willConnectNotification, object: nil
        )
        #endif
        return true
    }

    #if targetEnvironment(macCatalyst)
    @objc private func hideTitlebarSeparator(_ note: Notification) {
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                scene.titlebar?.titleVisibility = .hidden
                scene.titlebar?.toolbar = nil
            }
        }
    }
    #endif

    @objc private func appWillResignActive() {
        showPrivacyScreen()
    }

    @objc private func appDidBecomeActive() {
        hidePrivacyScreen()
    }

    private func showPrivacyScreen() {
        guard privacyWindow == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = PrivacyViewController()
        window.isHidden = false
        privacyWindow = window
    }

    private func hidePrivacyScreen() {
        privacyWindow?.isHidden = true
        privacyWindow = nil
    }

    // フォアグラウンド通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// バックグラウンドURLSession完了通知 → BackgroundDownloadManagerへ転送
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloadManager.shared.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

/// プライバシー保護画面のViewController
private class PrivacyViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // ブラー背景
        let blurEffect = UIBlurEffect(style: .systemThickMaterialDark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.frame = view.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blurView)

        // アイコン + テキスト
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "eye.slash.fill"))
        icon.tintColor = UIColor.gray.withAlphaComponent(0.6)
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 50).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 50).isActive = true

        let label = UILabel()
        label.text = "Cort:EX"
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = UIColor.gray.withAlphaComponent(0.5)

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
#endif

@main
struct EhViewerApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Phase 2C: BGProcessingTask handler 登録。
        // Apple 仕様で SceneDelegate / AppDelegate lifecycle 完了前に register 必須。
        // Info.plist の BGTaskSchedulerPermittedIdentifiers に同一 id 登録済み前提。
        #if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
        BackgroundDownloadManager.registerBGProcessingHandler()
        #endif

        // 既存ユーザーのdownloadQualityModeを0→2に移行（register前に実行）
        if !UserDefaults.standard.bool(forKey: "dlQualityMigrated2") {
            // 明示的に保存された値がなければ2をセット、0なら2に上書き
            if UserDefaults.standard.object(forKey: "downloadQualityMode") == nil
                || UserDefaults.standard.integer(forKey: "downloadQualityMode") == 0 {
                UserDefaults.standard.set(2, forKey: "downloadQualityMode")
            }
            UserDefaults.standard.set(true, forKey: "dlQualityMigrated2")
        }

        // UserDefaultsのデフォルト値を登録（Bundle ID変更や初回起動時に必要）
        UserDefaults.standard.register(defaults: [
            "onlineQualityMode": 2,
            "downloadQualityMode": 2,
            "noFilterMode": false,
        ])

        ImageCache.shared.cleanupOnLaunch()
        GalleryExporter.cleanupOldExportFiles()
        cleanupGalleryWebPTmp()
        // Keychain accessibility migration (既存 cookie を BG 可能 accessibility に書き直す)
        KeychainService.migrateAccessibility()
        // animated_cache 上限 500MB、超えてたら LRU eviction
        Task.detached(priority: .utility) {
            WebPToMP4Converter.enforceCacheCap()
        }
        print("[CoreML] modelAvailable: \(CoreMLImageProcessor.shared.modelAvailable)")

        #if DEBUG
        HTMLParserTests.runAll()
        #endif

        // Foundation Models可用性チェック（iOS 26+）
        _ = AIFeatures.shared

        // 通知許可
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[Notification] auth error: \(error)")
            } else {
                print("[Notification] auth granted: \(granted)")
            }
        }

        // TipKit初期化（初回のみ表示）
        if !UserDefaults.standard.bool(forKey: "tipsShownOnce") {
            try? Tips.resetDatastore()
            UserDefaults.standard.set(true, forKey: "tipsShownOnce")
        }
        try? Tips.configure([
            .displayFrequency(.immediate)
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
            .task {
                FavoritesViewModel.prefetchCachedFavorites()
                Task.detached(priority: .utility) {
                    ImageCache.shared.prewarmRecentThumbs()
                }
            }
            .onAppear {
                #if canImport(UIKit)
                UNUserNotificationCenter.current().delegate = appDelegate
                LogManager.shared.startFrameMonitor()
                #endif
            }
            .onChange(of: scenePhase) { _, newPhase in
                CoreMLImageProcessor.shared.isAppActive = (newPhase == .active)
                if newPhase == .active {
                    LogManager.shared.log("App", "scene active")
                }
            }
        }
    }
}

/// 起動時の tmp/ 掃除: クラッシュ / 強制終了で残る一時ファイルを一括削除。
/// 対象:
/// - `gallery_webp_*` (GalleryAnimatedWebPView が書き出した onDisappear 漏れ)
/// - `CFNetworkDownload_*.tmp` (URLSession downloadTask の未完了テンポラリ、アプリ強制終了時リーク)
/// - `CoordinatedZipFile*` (.cortex export 進行中のステージングフォルダ、共有シート未完了で残存)
/// - `bg-html-*.tmp` (BackgroundDownloadManager の BG HTML fetch テンポラリ)
@MainActor
private func cleanupGalleryWebPTmp() {
    let tmp = FileManager.default.temporaryDirectory
    guard let items = try? FileManager.default.contentsOfDirectory(
        at: tmp, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
    ) else { return }
    var removed = 0
    var freed: Int64 = 0
    for url in items {
        let name = url.lastPathComponent
        let matches = name.hasPrefix("gallery_webp_")
            || name.hasPrefix("CFNetworkDownload_")
            || name.hasPrefix("CoordinatedZipFile")
            || name.hasPrefix("bg-html-")
        guard matches else { continue }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if (try? FileManager.default.removeItem(at: url)) != nil {
            removed += 1
            freed += Int64(size)
        }
    }
    if removed > 0 {
        LogManager.shared.log("App", "cleanup tmp: \(removed) items, \(freed / 1024 / 1024)MB")
    }
}
