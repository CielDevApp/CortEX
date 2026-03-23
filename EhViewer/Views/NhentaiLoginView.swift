import SwiftUI
#if canImport(UIKit)
import WebKit

/// nhentai WKWebViewログイン画面（CDN Cloudflare認証付き）
struct NhentaiLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var loginDetected = false
    @State private var cdnPhase: CDNVerifyPhase = .idle
    @State private var statusText = ""

    enum CDNVerifyPhase {
        case idle, verifying, done, failed
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NhentaiWebView(
                    isLoading: $isLoading,
                    loginDetected: $loginDetected,
                    cdnPhase: $cdnPhase,
                    statusText: $statusText
                )
                .ignoresSafeArea(edges: .bottom)

                if isLoading && cdnPhase == .idle {
                    ProgressView()
                        .scaleEffect(1.2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }

                // CDN認証フェーズのオーバーレイ
                if cdnPhase == .verifying {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("CDN認証中...")
                            .font(.headline)
                        Text("Cloudflareチャレンジを解決しています")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !statusText.isEmpty {
                            Text(statusText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.3))
                }

                if cdnPhase == .done {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("CDN認証完了")
                            .font(.headline)
                        Text("画像のダウンロードが可能になりました")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.3))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            cdnPhase = .idle
                        }
                    }
                }
            }
            .navigationTitle(cdnPhase != .idle ? "CDN認証" : "nhentaiログイン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                if loginDetected {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { dismiss() }
                            .bold()
                    }
                }
            }
            .onChange(of: loginDetected) { _, detected in
                if detected {
                    LogManager.shared.log("nhAuth", "login detected via WebView")
                }
            }
        }
    }
}

/// CDN Cloudflare認証専用ビュー（ダウンロード失敗時に単独表示可能）
struct NhentaiCDNVerifyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var loginDetected = false
    @State private var cdnPhase: NhentaiLoginView.CDNVerifyPhase = .idle
    @State private var statusText = ""
    @State private var startCDNImmediately = true

    var body: some View {
        NavigationStack {
            ZStack {
                NhentaiWebView(
                    isLoading: $isLoading,
                    loginDetected: $loginDetected,
                    cdnPhase: $cdnPhase,
                    statusText: $statusText,
                    cdnOnly: true
                )
                .ignoresSafeArea(edges: .bottom)

                if cdnPhase == .done {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("CDN認証完了")
                            .font(.headline)
                        Text("画像のダウンロードが可能になりました")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.3))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("CDN認証")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

/// WKWebView wrapper for nhentai login + CDN verification
struct NhentaiWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    @Binding var loginDetected: Bool
    @Binding var cdnPhase: NhentaiLoginView.CDNVerifyPhase
    @Binding var statusText: String
    var cdnOnly: Bool = false

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

        if cdnOnly {
            // CDN認証モード：直接CDNドメインへ
            context.coordinator.startCDNVerification(webView: webView)
        } else {
            let url = URL(string: "https://nhentai.net/login/")!
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: NhentaiWebView
        private var cdnDomains = ["i.nhentai.net", "t.nhentai.net"]
        private var currentCDNIndex = 0
        private var isInCDNPhase = false
        private var cfClearanceCaptured = false

        init(_ parent: NhentaiWebView) {
            self.parent = parent
            if parent.cdnOnly {
                self.isInCDNPhase = true
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false

            if isInCDNPhase {
                handleCDNNavigation(webView: webView)
            } else {
                extractAndSaveCookies(from: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            LogManager.shared.log("nhAuth", "navigation failed: \(error.localizedDescription)")

            // CDNフェーズでエラーでもCookieは取得できている可能性がある
            if isInCDNPhase {
                extractCDNCookies(from: webView) {
                    self.advanceCDN(webView: webView)
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            LogManager.shared.log("nhAuth", "provisional navigation failed: \(error.localizedDescription)")

            if isInCDNPhase {
                extractCDNCookies(from: webView) {
                    self.advanceCDN(webView: webView)
                }
            }
        }

        // MARK: - CDN Cloudflare Verification

        func startCDNVerification(webView: WKWebView) {
            isInCDNPhase = true
            currentCDNIndex = 0
            DispatchQueue.main.async {
                self.parent.cdnPhase = .verifying
                self.parent.statusText = "CDNドメインを認証中..."
            }
            loadCurrentCDN(webView: webView)
        }

        private func loadCurrentCDN(webView: WKWebView) {
            guard currentCDNIndex < cdnDomains.count else {
                finishCDNVerification(webView: webView)
                return
            }

            let domain = cdnDomains[currentCDNIndex]
            DispatchQueue.main.async {
                self.parent.statusText = "\(domain) を認証中..."
            }
            LogManager.shared.log("nhAuth", "CDN verify: loading \(domain)")

            let url = URL(string: "https://\(domain)/")!
            webView.load(URLRequest(url: url))
        }

        private func handleCDNNavigation(webView: WKWebView) {
            // Cloudflareチャレンジが自動解決されたか確認
            // ページ内容をチェック（チャレンジページかどうか）
            webView.evaluateJavaScript("document.title") { result, _ in
                let title = (result as? String) ?? ""
                let isChallenge = title.lowercased().contains("just a moment")
                    || title.lowercased().contains("cloudflare")
                    || title.lowercased().contains("checking")

                if isChallenge {
                    // まだチャレンジ中 → 少し待ってリロード（JSチャレンジ自動解決を待つ）
                    LogManager.shared.log("nhAuth", "CDN challenge detected, waiting...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        self.extractCDNCookies(from: webView) {
                            // チャレンジ解決を再確認
                            if self.cfClearanceCaptured {
                                self.advanceCDN(webView: webView)
                            } else {
                                // もう少し待つ（ユーザーがCAPTCHA操作中の可能性）
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                    self.extractCDNCookies(from: webView) {
                                        self.advanceCDN(webView: webView)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // チャレンジ通過済み → Cookie取得して次へ
                    self.extractCDNCookies(from: webView) {
                        self.advanceCDN(webView: webView)
                    }
                }
            }
        }

        private func advanceCDN(webView: WKWebView) {
            currentCDNIndex += 1
            if currentCDNIndex < cdnDomains.count {
                // 次のCDNドメインへ（少し間隔を置く）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.loadCurrentCDN(webView: webView)
                }
            } else {
                finishCDNVerification(webView: webView)
            }
        }

        private func finishCDNVerification(webView: WKWebView) {
            extractCDNCookies(from: webView) {
                let hasCf = NhentaiCookieManager.hasCfClearance()
                DispatchQueue.main.async {
                    if hasCf {
                        self.parent.cdnPhase = .done
                        LogManager.shared.log("nhAuth", "CDN verification completed with cf_clearance")
                    } else {
                        self.parent.cdnPhase = .failed
                        LogManager.shared.log("nhAuth", "CDN verification completed but no cf_clearance found")
                    }
                    self.isInCDNPhase = false
                }
            }
        }

        // MARK: - Cookie Extraction

        private func extractCDNCookies(from webView: WKWebView, completion: @escaping () -> Void) {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { cookies in
                let nhCookies = cookies.filter { $0.domain.contains("nhentai.net") }
                guard !nhCookies.isEmpty else {
                    completion()
                    return
                }

                let cookieString = nhCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                let hasCf = nhCookies.contains { $0.name == "cf_clearance" }

                if hasCf {
                    self.cfClearanceCaptured = true
                    NhentaiCookieManager.saveCookies(cookieString)
                    LogManager.shared.log("nhAuth", "cf_clearance captured! domains: \(Set(nhCookies.filter { $0.name == "cf_clearance" }.map { $0.domain }).joined(separator: ", "))")
                } else {
                    // cf_clearanceはないがその他のCookieがあれば保存
                    let names = nhCookies.map { $0.name }.joined(separator: ", ")
                    LogManager.shared.log("nhAuth", "cookies found (no cf_clearance): \(names)")
                    if nhCookies.contains(where: { $0.name == "sessionid" || $0.name == "csrftoken" }) {
                        NhentaiCookieManager.saveCookies(cookieString)
                    }
                }
                completion()
            }
        }

        private func extractAndSaveCookies(from webView: WKWebView) {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { cookies in
                let nhCookies = cookies.filter { $0.domain.contains("nhentai.net") }
                guard !nhCookies.isEmpty else { return }

                let cookieString = nhCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

                // cf_clearanceがあれば常に保存
                let hasCfClearance = nhCookies.contains { $0.name == "cf_clearance" }
                if hasCfClearance {
                    self.cfClearanceCaptured = true
                    NhentaiCookieManager.saveCookies(cookieString)
                    LogManager.shared.log("nhAuth", "cf_clearance captured from login page")
                }

                // ログイン検出
                let hasSession = nhCookies.contains { $0.name == "sessionid" || $0.name == "token" }
                if hasSession || nhCookies.count >= 2 {
                    NhentaiCookieManager.saveCookies(cookieString)
                    DispatchQueue.main.async {
                        self.parent.loginDetected = true

                        // ログイン成功後、自動でCDN認証を開始
                        if !self.isInCDNPhase && !self.cfClearanceCaptured {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.startCDNVerification(webView: webView)
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
