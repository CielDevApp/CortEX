import Foundation
#if canImport(UIKit)
import WebKit

/// WKWebView経由でnhentai APIを叩くブリッジ
/// URLSessionではCloudflareのTLSフィンガープリント検証を通過できないため、
/// WKWebViewのJavaScript fetch()を使ってAPI通信を行う
@MainActor
final class NhentaiWebBridge: NSObject, WKNavigationDelegate {
    static let shared = NhentaiWebBridge()

    private var webView: WKWebView?
    private var isReady = false
    private var isInitializing = false

    private override init() {
        super.init()
    }

    /// ログイン後などにWebViewを再初期化（Cookieを最新化）
    func reset() {
        webView?.stopLoading()
        webView = nil
        isReady = false
        isInitializing = false
        LogManager.shared.log("nhBridge", "reset")
    }

    // MARK: - Setup

    private func ensureWebView() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView = wv
        LogManager.shared.log("nhBridge", "WebView created")
    }

    /// WebViewを初期化してCloudflareチャレンジを通過させる
    func initialize() async {
        guard !isReady, !isInitializing else { return }
        isInitializing = true

        ensureWebView()
        guard let wv = webView else { return }

        // NhentaiCookieManagerからCookieをWKWebViewに注入 + access_token抽出
        if let cookieString = NhentaiCookieManager.cookieHeader() {
            let store = wv.configuration.websiteDataStore.httpCookieStore
            for part in cookieString.components(separatedBy: "; ") {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let name = String(kv[0])
                let value = String(kv[1])
                // access_tokenはWKWebView cookie storeから取得するのでここではスキップ
                if let cookie = HTTPCookie(properties: [
                    .name: name, .value: value,
                    .domain: ".nhentai.net", .path: "/",
                    .secure: "TRUE"
                ]) {
                    await store.setCookie(cookie)
                }
            }
            LogManager.shared.log("nhBridge", "injected cookies from NhentaiCookieManager")
        }

        // WKWebViewのCookieストアからもaccess_tokenを探す
        let wvStore = wv.configuration.websiteDataStore.httpCookieStore
        let allCookies = await wvStore.allCookies()
        if let accessCookie = allCookies.first(where: { $0.name == "access_token" && $0.domain.contains("nhentai") }) {
            NhentaiCookieManager.saveToken(accessCookie.value)
            LogManager.shared.log("nhBridge", "access_token extracted from WKWebView cookie store")
        }

        LogManager.shared.log("nhBridge", "initializing: loading nhentai.net...")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let url = URL(string: "https://nhentai.net/")!
            wv.load(URLRequest(url: url))
            self._initContinuation = cont
        }
    }

    private var _initContinuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let cont = _initContinuation {
            webView.evaluateJavaScript("document.title") { [weak self] result, _ in
                guard let self else { return }
                let title = (result as? String) ?? ""
                let isChallenge = title.lowercased().contains("just a moment")
                    || title.lowercased().contains("cloudflare")
                    || title.lowercased().contains("checking")

                if isChallenge {
                    LogManager.shared.log("nhBridge", "Cloudflare challenge detected, waiting...")
                } else {
                    LogManager.shared.log("nhBridge", "ready! title: \(title.prefix(50))")
                    // document.cookieの中身を確認
                    webView.evaluateJavaScript("document.cookie") { cookieResult, _ in
                        let cookies = (cookieResult as? String) ?? ""
                        let hasAccess = cookies.contains("access_token")
                        LogManager.shared.log("nhBridge", "document.cookie: hasAccessToken=\(hasAccess) length=\(cookies.count) cookies=\(cookies.prefix(200))")
                    }
                    self.isReady = true
                    self.isInitializing = false
                    self._initContinuation = nil
                    cont.resume()
                }
            }
            return
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        LogManager.shared.log("nhBridge", "navigation failed: \(error.localizedDescription)")
        if let cont = _initContinuation {
            isReady = true
            isInitializing = false
            _initContinuation = nil
            cont.resume()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        LogManager.shared.log("nhBridge", "provisional navigation failed: \(error.localizedDescription)")
        if let cont = _initContinuation {
            isReady = true
            isInitializing = false
            _initContinuation = nil
            cont.resume()
        }
    }

    // MARK: - API

    /// GETリクエスト（JSON API用）
    func fetch(url: String) async throws -> Data {
        if !isReady { await initialize() }
        guard let wv = webView else { throw URLError(.cannotConnectToHost) }

        let js = """
        const headers = {};
        const cookies = document.cookie.split('; ');
        for (const c of cookies) {
            const [name, ...val] = c.split('=');
            if (name === 'access_token') {
                headers['Authorization'] = 'Bearer ' + val.join('=');
                break;
            }
        }
        const response = await fetch(targetUrl, {credentials: 'include', headers: headers});
        const text = await response.text();
        return JSON.stringify({status: response.status, body: text});
        """

        let result = try await wv.callAsyncJavaScript(
            js,
            arguments: ["targetUrl": url],
            contentWorld: .page
        )

        guard let jsonStr = result as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let status = json["status"] as? Int,
              let body = json["body"] as? String else {
            LogManager.shared.log("nhBridge", "unexpected response: \(String(describing: result))")
            throw URLError(.badServerResponse)
        }

        LogManager.shared.log("nhBridge", "GET \(url.suffix(80)): status=\(status) size=\(body.count)")

        if status == 200, let data = body.data(using: .utf8) {
            return data
        } else {
            LogManager.shared.log("nhBridge", "non-200: \(body.prefix(200))")
            throw URLError(.init(rawValue: status))
        }
    }

    /// POSTリクエスト（お気に入りトグル等）
    func post(url: String, csrfToken: String? = nil) async throws -> Data {
        if !isReady { await initialize() }
        guard let wv = webView else { throw URLError(.cannotConnectToHost) }

        // WKWebViewのCookieストアからaccess_tokenを直接取得（最新のものを使う）
        let wvStore = wv.configuration.websiteDataStore.httpCookieStore
        let allCookies = await wvStore.allCookies()
        let accessTokenCookies = allCookies.filter { $0.name == "access_token" && $0.domain.contains("nhentai") }
        // 有効期限が最も遅いものを選択
        let accessToken = accessTokenCookies
            .sorted { ($0.expiresDate ?? .distantPast) > ($1.expiresDate ?? .distantPast) }
            .first?.value ?? ""
        LogManager.shared.log("nhBridge", "POST auth token: \(accessToken.prefix(20))... (from \(accessTokenCookies.count) cookies, values: \(accessTokenCookies.map { "\($0.value.prefix(10))..exp=\($0.expiresDate?.description.prefix(19) ?? "nil")" }))")

        let js = """
        const headers = {'X-Requested-With': 'XMLHttpRequest'};
        if (csrf) headers['X-CSRFToken'] = csrf;
        if (authToken) headers['Authorization'] = 'Bearer ' + authToken;
        const response = await fetch(targetUrl, {
            method: 'POST',
            headers: headers,
            credentials: 'include'
        });
        const text = await response.text();
        return JSON.stringify({status: response.status, body: text});
        """

        let result = try await wv.callAsyncJavaScript(
            js,
            arguments: ["targetUrl": url, "csrf": csrfToken ?? "", "authToken": accessToken],
            contentWorld: .page
        )

        guard let jsonStr = result as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let status = json["status"] as? Int,
              let body = json["body"] as? String else {
            throw URLError(.badServerResponse)
        }

        LogManager.shared.log("nhBridge", "POST \(url.suffix(60)): status=\(status)")

        guard let data = body.data(using: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// refresh_tokenを使って新しいaccess_tokenを取得
    private func refreshAccessToken() async -> String? {
        guard let wv = webView else { return nil }

        let store = wv.configuration.websiteDataStore.httpCookieStore
        let allCookies = await store.allCookies()
        let refreshToken = allCookies
            .filter { $0.name == "refresh_token" && $0.domain.contains("nhentai") }
            .sorted { ($0.expiresDate ?? .distantPast) > ($1.expiresDate ?? .distantPast) }
            .first?.value

        guard let refreshToken, !refreshToken.isEmpty else {
            LogManager.shared.log("nhBridge", "refreshToken: no refresh_token in cookie store")
            return nil
        }

        LogManager.shared.log("nhBridge", "refreshToken: refreshing with \(refreshToken.prefix(15))...")

        let js = """
        try {
            const resp = await fetch('https://nhentai.net/api/v2/auth/refresh', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({refresh_token: rt}),
                credentials: 'include'
            });
            const text = await resp.text();
            return JSON.stringify({status: resp.status, body: text});
        } catch(e) {
            return JSON.stringify({status: 0, error: e.message});
        }
        """

        guard let result = try? await wv.callAsyncJavaScript(
            js,
            arguments: ["rt": refreshToken],
            contentWorld: .page
        ),
              let jsonStr = result as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let status = json["status"] as? Int,
              let body = json["body"] as? String else {
            LogManager.shared.log("nhBridge", "refreshToken: JS execution failed")
            return nil
        }

        LogManager.shared.log("nhBridge", "refreshToken: status=\(status)")

        if status == 200, let bodyData = body.data(using: .utf8),
           let tokenJson = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let newAccess = tokenJson["access_token"] as? String {
            LogManager.shared.log("nhBridge", "refreshToken: got new access_token \(newAccess.prefix(15))...")
            // 新しいrefresh_tokenも更新
            if let newRefresh = tokenJson["refresh_token"] as? String {
                if let cookie = HTTPCookie(properties: [
                    .name: "refresh_token", .value: newRefresh,
                    .domain: ".nhentai.net", .path: "/", .secure: "TRUE"
                ]) {
                    await store.setCookie(cookie)
                }
            }
            // access_tokenもcookieに保存
            if let cookie = HTTPCookie(properties: [
                .name: "access_token", .value: newAccess,
                .domain: ".nhentai.net", .path: "/", .secure: "TRUE"
            ]) {
                await store.setCookie(cookie)
            }
            return newAccess
        }

        LogManager.shared.log("nhBridge", "refreshToken: failed body=\(body.prefix(200))")
        return nil
    }

    /// お気に入りトグル：refresh_tokenで最新access_tokenを取得してv2 API POST
    func toggleFavoriteViaPage(galleryId: Int) async throws -> Bool {
        if !isReady { await initialize() }
        guard let wv = webView else { throw URLError(.cannotConnectToHost) }

        // 1. まずrefresh_tokenで最新のaccess_tokenを取得
        guard let freshToken = await refreshAccessToken() else {
            LogManager.shared.log("nhBridge", "toggleFav: failed to get fresh token")
            return false
        }

        // 2. 新しいトークンでお気に入りAPI POST
        let js = """
        try {
            const resp = await fetch('https://nhentai.net/api/v2/galleries/' + gid + '/favorite', {
                method: 'POST',
                headers: {
                    'Authorization': 'Bearer ' + token,
                    'Content-Type': 'application/json'
                }
            });
            const text = await resp.text();
            return JSON.stringify({success: resp.ok, status: resp.status, body: text});
        } catch(e) {
            return JSON.stringify({success: false, error: e.message});
        }
        """

        let result = try await wv.callAsyncJavaScript(
            js,
            arguments: ["gid": galleryId, "token": freshToken],
            contentWorld: .page
        )

        guard let jsonStr = result as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            LogManager.shared.log("nhBridge", "toggleFav: unexpected result")
            throw URLError(.badServerResponse)
        }

        let success = json["success"] as? Bool ?? false
        let status = json["status"] as? Int ?? 0
        let body = json["body"] as? String ?? ""

        LogManager.shared.log("nhBridge", "toggleFav: status=\(status) success=\(success) body=\(body.prefix(100))")

        return success
    }

    /// HTMLページ取得（ステータスコードも返す）
    func fetchHTML(url: String) async throws -> (html: String, status: Int) {
        if !isReady { await initialize() }
        guard let wv = webView else { throw URLError(.cannotConnectToHost) }

        let js = """
        const headers = {};
        const cookies = document.cookie.split('; ');
        for (const c of cookies) {
            const [name, ...val] = c.split('=');
            if (name === 'access_token') {
                headers['Authorization'] = 'Bearer ' + val.join('=');
                break;
            }
        }
        const response = await fetch(targetUrl, {credentials: 'include', headers: headers});
        const text = await response.text();
        return JSON.stringify({status: response.status, body: text});
        """

        let result = try await wv.callAsyncJavaScript(
            js,
            arguments: ["targetUrl": url],
            contentWorld: .page
        )

        guard let jsonStr = result as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let status = json["status"] as? Int,
              let body = json["body"] as? String else {
            throw URLError(.badServerResponse)
        }

        return (html: body, status: status)
    }
}
#endif
