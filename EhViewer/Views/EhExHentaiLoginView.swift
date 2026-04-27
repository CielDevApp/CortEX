import SwiftUI
#if canImport(UIKit)
import WebKit

/// E-Hentai / EXhentai WKWebView ログイン画面 (2026-04-27、田中要望 v.02b)。
/// 動作: bounce_login.php ロード → ユーザーがフォーム入力 →
/// e-hentai.org root リダイレクト検出 → exhentai.org 自動ロード → igneous 発行 →
/// 3 つの cookie (ipb_member_id / ipb_pass_hash / igneous) を AuthViewModel に流し込み、
/// 既存 LoginView の TextField が自動入力される (ユーザーが値を確認後「ログイン」押下)。
///
/// 雛形: NhentaiLoginView (CDN チャレンジは不要なため簡略化)。
struct EhExHentaiLoginView: View {
    @ObservedObject var authVM: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .login
    @State private var statusText: String = "e-hentai.org にログインしてください"
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var currentURL: String = "https://e-hentai.org/bounce_login.php"
    private let webViewHolder = WebViewHolder()

    /// 田中要望 2026-04-27: 「閉じて再起動」シミュレートで 2 回目に提示された場合 true。
    /// false (1 回目) のとき forums 到達で onRequestRelaunch を呼ぶ → 親が dismiss → 親が再 sheet 提示。
    /// true (2 回目) のとき forums 到達で exhentai.org bounce を実行 (既存 flow)。
    let isRelaunched: Bool
    /// 1 回目で forums 到達した時、親に「閉じて再起動して」と通知する callback。
    let onRequestRelaunch: (_ memberID: String, _ passHash: String) -> Void

    init(authVM: AuthViewModel, isRelaunched: Bool = false, onRequestRelaunch: @escaping (String, String) -> Void = { _, _ in }) {
        self.authVM = authVM
        self.isRelaunched = isRelaunched
        self.onRequestRelaunch = onRequestRelaunch
    }

    enum Phase: Equatable {
        case login          // ユーザーが e-hentai.org でログイン中
        case relaunching    // 1 回目フォーラム到達後の「閉じて再起動」処理中 (短時間)
        case bouncing       // 2 回目 sheet で exhentai.org にアクセス中 (igneous 発行)
        case igneousFailed  // 2 回目でも取れず、ユーザーに手動再試行を促す
        case done           // cookie 取得完了
        case sadPanda       // EXhentai アクセス権限なし
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // フェーズ別進捗バー
                phaseBanner
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))

                Divider()

                // WKWebView 領域 (max 高さ) + 待機/失敗 overlay
                ZStack {
                    EhExHentaiWebView(
                        phase: $phase,
                        statusText: $statusText,
                        canGoBack: $canGoBack,
                        canGoForward: $canGoForward,
                        currentURL: $currentURL,
                        holder: webViewHolder,
                        authVM: authVM,
                        onCookiesCaptured: handleCookiesCaptured,
                        isRelaunched: isRelaunched,
                        onRequestRelaunch: onRequestRelaunch
                    )
                    .ignoresSafeArea(edges: .bottom)

                    if phase == .igneousFailed {
                        igneousFailedOverlay
                    }
                }
            }
            .navigationTitle("ブラウザログイン")
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigation) {
                    Button {
                        webViewHolder.webView?.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!canGoBack)
                }
                ToolbarItem(placement: .navigation) {
                    Button {
                        webViewHolder.webView?.goForward()
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!canGoForward)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            clearEhCookiesAndReload()
                        } label: {
                            Label("e-hentai / exhentai cookie をクリア", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - フェーズバナー

    @ViewBuilder
    private var phaseBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: phaseSymbol)
                .foregroundStyle(phaseColor)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseTitle)
                    .font(.subheadline.bold())
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if phase == .bouncing {
                ProgressView()
                    .tint(.orange)
            }
        }
    }

    private var phaseSymbol: String {
        switch phase {
        case .login: return "person.crop.circle"
        case .relaunching: return "arrow.triangle.2.circlepath"
        case .bouncing: return "arrow.triangle.swap"
        case .igneousFailed: return "arrow.clockwise.circle"
        case .done: return "checkmark.circle.fill"
        case .sadPanda: return "exclamationmark.triangle.fill"
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .login: return .orange
        case .relaunching: return .orange
        case .bouncing: return .orange
        case .igneousFailed: return .red
        case .done: return .green
        case .sadPanda: return .red
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .login: return isRelaunched ? "再認証中..." : "e-hentai.org にログイン中"
        case .relaunching: return "閉じて再起動中..."
        case .bouncing: return "exhentai.org にアクセス中 (igneous 発行)"
        case .igneousFailed: return "igneous 取得失敗"
        case .done: return "cookie 取得完了"
        case .sadPanda: return "EXhentai アクセス権限がありません"
        }
    }

    // MARK: - 失敗 overlay

    @ViewBuilder
    private var igneousFailedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("igneous 取得失敗")
                .font(.title3.bold())
            Text("自動再試行しましたが、igneous cookie が発行されませんでした。\nもう一度試してください (cookie は維持されています)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                webViewHolder.webView?.load(URLRequest(url: URL(string: "https://e-hentai.org/bounce_login.php")!))
                phase = .login
                statusText = "e-hentai.org にログインしてください"
            } label: {
                Label("もう一度ログイン", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.horizontal, 40)
        }
        .padding(32)
        .background(Color(.systemBackground))
    }

    // MARK: - cookie 取得後の処理

    /// e-hentai.org / exhentai.org の cookie のみクリア → bounce_login.php に再 load。
    /// nhentai (cf_clearance / sessionid 等) の cookie は巻き込まない。検証用デバッグ機能。
    private func clearEhCookiesAndReload() {
        guard let webView = webViewHolder.webView else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let targets = cookies.filter { $0.domain.contains("e-hentai.org") || $0.domain.contains("exhentai.org") }
            LogManager.shared.log("EhAuth", "clearing \(targets.count) eh/exh cookies")
            let group = DispatchGroup()
            for c in targets {
                group.enter()
                store.delete(c) { group.leave() }
            }
            group.notify(queue: .main) {
                self.phase = .login
                self.statusText = "cookie クリア完了。再度ログインしてください"
                webView.load(URLRequest(url: URL(string: "https://e-hentai.org/bounce_login.php")!))
            }
        }
    }

    /// cookie 抽出完了 → AuthViewModel に流し込み → 1.5 秒後 dismiss。
    /// 既存 LoginView の TextField が自動入力された状態でユーザーが見える。
    private func handleCookiesCaptured(memberID: String, passHash: String, igneous: String?) {
        DispatchQueue.main.async {
            // 田中要望 2026-04-27: 自動入力後に「IDとパスハッシュを入力してください」赤字が
            // 消えない問題対策。値 set 前に errorMessage を nil に戻す。
            authVM.errorMessage = nil
            authVM.memberID = memberID
            authVM.passHash = passHash
            if let igneous, !igneous.isEmpty {
                authVM.igneous = igneous
            }
            phase = .done
            statusText = "認証情報フィールドに自動入力しました。\n値を確認して「ログイン」を押してください"
            LogManager.shared.log("EhAuth", "cookies captured via WebView: member=\(memberID.prefix(4))*** hasPass=\(!passHash.isEmpty) hasIgneous=\(!(igneous?.isEmpty ?? true))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            dismiss()
        }
    }
}

/// WKWebView を SwiftUI の View ライフサイクル外で保持するためのホルダ。
/// goBack / goForward を toolbar から叩くために必要。
@MainActor
final class WebViewHolder {
    var webView: WKWebView?
}

/// E-Hentai / EXhentai 用 WKWebView wrapper。
struct EhExHentaiWebView: UIViewRepresentable {
    @Binding var phase: EhExHentaiLoginView.Phase
    @Binding var statusText: String
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var currentURL: String
    let holder: WebViewHolder
    let authVM: AuthViewModel
    let onCookiesCaptured: (_ memberID: String, _ passHash: String, _ igneous: String?) -> Void
    let isRelaunched: Bool
    let onRequestRelaunch: (_ memberID: String, _ passHash: String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nhentai と同じ流儀で .default() を使う (隔離 store は overkill、田中合意済)
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Catalyst では UA を上書きしない (Cloudflare Turnstile が WebKit build と整合検査するため)
        #if !targetEnvironment(macCatalyst)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        #endif
        // KVO で goBack/goForward 状態を反映
        context.coordinator.observe(webView: webView)
        holder.webView = webView

        let url = URL(string: "https://e-hentai.org/bounce_login.php")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EhExHentaiWebView
        private var hasTriggeredExBounce = false
        private var hasCapturedAll = false
        private var observers: [NSKeyValueObservation] = []

        init(_ parent: EhExHentaiWebView) {
            self.parent = parent
        }

        func observe(webView: WKWebView) {
            observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.parent.canGoBack = webView.canGoBack }
            })
            observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.parent.canGoForward = webView.canGoForward }
            })
            observers.append(webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.parent.currentURL = webView.url?.absoluteString ?? "" }
            })
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            LogManager.shared.log("EhAuth", "nav start: \(url.absoluteString)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            LogManager.shared.log("EhAuth", "nav finish: \(url.absoluteString)")

            let host = url.host ?? ""
            let path = url.path

            // e-hentai.org にログイン成功 → root リダイレクト or /home.php 等の認証必要ページ到達
            // bounce_login.php 上で submit すると root or 元 referer に飛ぶ
            if host.contains("e-hentai.org") && !path.contains("bounce_login") && !path.contains("login") {
                handleEHentaiLoginSuccess(webView: webView)
            }

            // exhentai.org に到達 → igneous 発行 cookie が来てるはず
            if host.contains("exhentai.org") {
                handleExHentaiReached(webView: webView)
            }
        }

        // MARK: - e-hentai.org login 成功

        /// forums.e-hentai.org 等 (ログイン成功 redirect 先) 到達時の挙動。
        /// 田中要望 2026-04-27: 「一回閉じて、もう一度ブラウザでログインを押した動作」を物理的に再現する。
        /// - 1 回目 (isRelaunched = false): 仮 capture + 親に閉じて再 sheet 表示を依頼
        ///   → 親が showWebLogin を false → 0.5 秒 → true に戻す → 新規 EhExHentaiLoginView + 新規 WKWebView 生成
        /// - 2 回目 (isRelaunched = true): 既存 cookie で e-hentai 自動ログイン状態 → exhentai.org bounce → igneous 取得
        private func handleEHentaiLoginSuccess(webView: WKWebView) {
            extractEhCookies(from: webView) { memberID, passHash in
                guard let memberID, let passHash else {
                    LogManager.shared.log("EhAuth", "ipb_member_id / ipb_pass_hash 未取得 (まだログイン未完?)")
                    return
                }
                // 仮 capture (TextField 即更新、エラー赤字消去)
                Task { @MainActor in
                    self.parent.authVM.errorMessage = nil
                    self.parent.authVM.memberID = memberID
                    self.parent.authVM.passHash = passHash
                }

                if !self.parent.isRelaunched {
                    // 1 回目: 親に「閉じて再起動」を依頼。WKWebView 物理破棄 + 再生成のため。
                    LogManager.shared.log("EhAuth", "forums 到達 (1 回目) → 親に閉じて再起動を依頼")
                    Task { @MainActor in
                        self.parent.onRequestRelaunch(memberID, passHash)
                    }
                } else {
                    // 2 回目: 既存 cookie あり、exhentai.org bounce で igneous 発行
                    LogManager.shared.log("EhAuth", "forums 到達 (2 回目 = relaunch 後) → exhentai.org bounce")
                    if !self.hasTriggeredExBounce {
                        self.hasTriggeredExBounce = true
                        Task { @MainActor in
                            self.parent.phase = .bouncing
                            self.parent.statusText = "exhentai.org に遷移しています..."
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            webView.load(URLRequest(url: URL(string: "https://exhentai.org/")!))
                        }
                    }
                }
            }
        }

        // MARK: - exhentai.org 到達

        private func handleExHentaiReached(webView: WKWebView) {
            // リトライサイクル中の didFinish は scheduleIgneousRetry 側で cookie 検査しているため、
            // ここでの extractAllCookiesAndFinish 多重起動を防ぐ。
            let currentPhase = parent.phase
            guard currentPhase == .bouncing else {
                LogManager.shared.log("EhAuth", "handleExHentaiReached skipped (phase=\(currentPhase))")
                return
            }
            // Sad Panda 判定: HTML body が空 / image content / 既知エラー文字列
            webView.evaluateJavaScript("document.title + '|' + (document.body ? document.body.innerText.slice(0, 200) : '')") { result, _ in
                let combined = (result as? String) ?? ""
                let lower = combined.lowercased()
                if lower.contains("sad panda") || combined.isEmpty || lower.contains("forbidden") {
                    Task { @MainActor in
                        self.parent.phase = .sadPanda
                        self.parent.statusText = "EXhentai アクセス権限がありません。\nE-Hentai アカウントが ExHentai 対応か確認してください"
                    }
                    LogManager.shared.log("EhAuth", "sad panda detected: \(combined.prefix(80))")
                    return
                }
                // 通常到達 → cookie 抽出 (igneous 未発行なら自動リトライサイクルへ)
                self.extractAllCookiesAndFinish(from: webView)
            }
        }

        // MARK: - cookie 抽出

        /// e-hentai.org の ipb_member_id / ipb_pass_hash を抽出。
        private func extractEhCookies(from webView: WKWebView, completion: @escaping (_ memberID: String?, _ passHash: String?) -> Void) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let ehCookies = cookies.filter { $0.domain.contains("e-hentai.org") || $0.domain.contains("exhentai.org") }
                let memberID = ehCookies.first(where: { $0.name == "ipb_member_id" })?.value
                let passHash = ehCookies.first(where: { $0.name == "ipb_pass_hash" })?.value
                completion(memberID, passHash)
            }
        }

        /// 2 回目 sheet (relaunch 後) の exhentai.org 到達後、3 秒待機して 3 cookie を抽出。
        /// 田中 testimony 2026-04-27: relaunch 後の操作なら igneous は即取得できる。
        /// 万が一取れなかった場合は .igneousFailed で手動再試行を誘導。
        private func extractAllCookiesAndFinish(from webView: WKWebView) {
            guard !hasCapturedAll else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                guard !self.hasCapturedAll else { return }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let ehCookies = cookies.filter { $0.domain.contains("e-hentai.org") || $0.domain.contains("exhentai.org") }
                    let memberID = ehCookies.first(where: { $0.name == "ipb_member_id" })?.value
                    let passHash = ehCookies.first(where: { $0.name == "ipb_pass_hash" })?.value
                    let igneous = ehCookies.first(where: { $0.name == "igneous" })?.value

                    guard let memberID, let passHash else {
                        LogManager.shared.log("EhAuth", "ipb_member_id / ipb_pass_hash 未取得 in exhentai phase")
                        return
                    }

                    if let igneous, !igneous.isEmpty {
                        self.hasCapturedAll = true
                        LogManager.shared.log("EhAuth", "igneous captured on relaunched exhentai bounce")
                        self.parent.onCookiesCaptured(memberID, passHash, igneous)
                        return
                    }

                    LogManager.shared.log("EhAuth", "igneous not issued even after relaunch, prompting manual retry")
                    Task { @MainActor in
                        self.parent.phase = .igneousFailed
                        self.parent.statusText = "igneous が発行されませんでした。もう一度試してください"
                    }
                }
            }
        }

        deinit {
            observers.forEach { $0.invalidate() }
        }
    }
}
#endif
