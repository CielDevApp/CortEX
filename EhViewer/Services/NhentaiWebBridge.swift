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

        // document.cookieから直接refresh_tokenを取得（WKCookieStoreは古いトークンが残る）
        let cookieStr = try? await wv.evaluateJavaScript("document.cookie") as? String
        var refreshToken: String?
        if let cookieStr {
            for part in cookieStr.components(separatedBy: "; ") {
                if part.hasPrefix("refresh_token=") {
                    refreshToken = String(part.dropFirst("refresh_token=".count))
                    break
                }
            }
        }

        guard let refreshToken, !refreshToken.isEmpty else {
            LogManager.shared.log("nhBridge", "refreshToken: no refresh_token in document.cookie")
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
            // 新しいトークンをdocument.cookieに直接セット
            let cookieStore = wv.configuration.websiteDataStore.httpCookieStore
            if let newRefresh = tokenJson["refresh_token"] as? String {
                if let cookie = HTTPCookie(properties: [
                    .name: "refresh_token", .value: newRefresh,
                    .domain: ".nhentai.net", .path: "/", .secure: "TRUE"
                ]) {
                    await cookieStore.setCookie(cookie)
                }
            }
            if let cookie = HTTPCookie(properties: [
                .name: "access_token", .value: newAccess,
                .domain: ".nhentai.net", .path: "/", .secure: "TRUE"
            ]) {
                await cookieStore.setCookie(cookie)
            }
            return newAccess
        }

        LogManager.shared.log("nhBridge", "refreshToken: failed body=\(body.prefix(200))")
        return nil
    }

    // MARK: - お気に入りトグル

    /// v2 APIのfavoriteエンドポイントは機能フラグで無効化されてるため、
    /// Webサイトのフロントエンド経由でのみ操作可能
    func toggleFavoriteViaPage(galleryId: Int) async throws -> Bool {
        // 別WebView（メインを壊さない）
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let favWV = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: config)
        favWV.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

        let delegate = FavNavigationDelegate()
        favWV.navigationDelegate = delegate

        // .default() websiteDataStoreはアプリ全体で共有されるため、
        // ログイン済みWebViewのCookieは自動的にfavWVでも利用可能

        // ギャラリーページを読み込む
        let pageUrl = URL(string: "https://nhentai.net/g/\(galleryId)/")!
        LogManager.shared.log("nhBridge", "toggleFav: loading /g/\(galleryId)/")
        favWV.load(URLRequest(url: pageUrl))

        // ナビゲーション完了を待つ（最大15秒）
        await delegate.waitForLoad(timeout: 15)
        LogManager.shared.log("nhBridge", "toggleFav: page loaded, waiting for SPA hydration...")

        // fetch()をモンキーパッチしてボタンクリック時のAPIリクエストを捕捉
        let patchJS = """
        window.__favCapture = [];
        const _origFetch = window.fetch;
        window.fetch = function(...args) {
            const url = typeof args[0] === 'string' ? args[0] : args[0]?.url || '';
            const method = args[1]?.method || 'GET';
            window.__favCapture.push({url, method, ts: Date.now()});
            return _origFetch.apply(this, args);
        };
        const _origXHR = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            window.__favCapture.push({url: String(url), method, ts: Date.now(), type: 'xhr'});
            return _origXHR.call(this, method, url, ...rest);
        };
        'patched';
        """
        _ = try? await favWV.callAsyncJavaScript(patchJS, arguments: [:], contentWorld: .page)

        // SPA hydrationをポーリング（#favoriteボタン出現まで最大12秒）
        var buttonFound = false
        for attempt in 1...24 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let pollJS = """
            const selectors = [
                '#favorite',
                'button[class*="favorite"]', 'button[class*="fav"]',
                '.gallery-favorite', '.btn-fav',
                'button:has(i.fa-heart)'
            ];
            for (const sel of selectors) {
                try { if (document.querySelector(sel)) return true; } catch(e) {}
            }
            return false;
            """
            let found = (try? await favWV.callAsyncJavaScript(pollJS, arguments: [:], contentWorld: .page)) as? Bool ?? false
            if found {
                buttonFound = true
                LogManager.shared.log("nhBridge", "toggleFav: button found after \(attempt * 500)ms")
                break
            }
        }

        if !buttonFound {
            // デバッグ: DOM状態をダンプ
            let debugJS = """
            const els = Array.from(document.querySelectorAll('button, a[href], [role="button"], [onclick]'));
            const info = els.slice(0, 20).map(e => ({
                tag: e.tagName, cls: e.className?.substring?.(0, 60) || '',
                text: e.textContent?.trim()?.substring(0, 40) || '',
                href: e.href?.substring?.(0, 60) || ''
            }));
            return JSON.stringify({
                url: location.href, title: document.title,
                bodyLen: document.body?.innerHTML?.length || 0,
                elements: info
            });
            """
            let debugResult = try? await favWV.callAsyncJavaScript(debugJS, arguments: [:], contentWorld: .page)
            LogManager.shared.log("nhBridge", "toggleFav: no button found, DOM dump=\(String(describing: debugResult))")
            favWV.stopLoading()
            return false
        }

        // favoriteボタンを探してクリック
        let clickJS = """
        const selectors = [
            '#favorite',
            'button[class*="favorite"]', 'button[class*="fav"]',
            '.gallery-favorite', '.btn-fav',
            'button:has(i.fa-heart)'
        ];

        let btn = null;
        let matchedSel = '';
        for (const sel of selectors) {
            try { btn = document.querySelector(sel); } catch(e) {}
            if (btn) { matchedSel = sel; break; }
        }

        // テキスト検索フォールバック
        if (!btn) {
            for (const el of document.querySelectorAll('button, a, span, div')) {
                const t = el.textContent?.toLowerCase() || '';
                if ((t.includes('favorite') || t === '♥' || t === '❤') && el.offsetParent !== null) {
                    btn = el;
                    matchedSel = 'text:' + t.substring(0, 20);
                    break;
                }
            }
        }

        if (btn) {
            // クリック前のキャプチャ状態をリセット
            window.__favCapture = [];
            btn.click();

            // クリック後に少し待ってからキャプチャを収集
            await new Promise(r => setTimeout(r, 2000));
            const captured = window.__favCapture || [];

            return JSON.stringify({
                success: true,
                method: 'click',
                selector: matchedSel,
                buttonTag: btn.tagName,
                buttonClass: (btn.className || '').substring(0, 80),
                buttonText: btn.textContent?.trim()?.substring(0, 50) || '',
                capturedRequests: captured.slice(0, 5)
            });
        }

        return JSON.stringify({success: false, method: 'none'});
        """

        let result = try? await favWV.callAsyncJavaScript(clickJS, arguments: [:], contentWorld: .page)

        // WebView破棄
        favWV.stopLoading()

        guard let jsonStr = result as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            LogManager.shared.log("nhBridge", "toggleFav: JS failed, result=\(String(describing: result))")
            return false
        }

        let success = json["success"] as? Bool ?? false
        let method = json["method"] as? String ?? ""
        let captured = json["capturedRequests"] as? [[String: Any]] ?? []
        LogManager.shared.log("nhBridge", "toggleFav: success=\(success) method=\(method) selector=\(json["selector"] ?? "") btn=\(json["buttonClass"] ?? "") text=\(json["buttonText"] ?? "")")
        if !captured.isEmpty {
            LogManager.shared.log("nhBridge", "toggleFav: captured API calls=\(captured)")
        }

        return success
    }

    // MARK: - HTMLページ取得

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

/// toggleFavoriteViaPage用のナビゲーションデリゲート
@MainActor
private final class FavNavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var loaded = false

    func waitForLoad(timeout: TimeInterval) async {
        if loaded { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            // タイムアウト
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = self.continuation {
                    self.continuation = nil
                    self.loaded = true
                    LogManager.shared.log("nhBridge", "FavNav: timeout after \(timeout)s")
                    c.resume()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let cont = continuation else { return }
        // Cloudflareチャレンジかチェック
        webView.evaluateJavaScript("document.title") { [weak self] result, _ in
            guard let self else { return }
            let title = (result as? String) ?? ""
            let isChallenge = title.lowercased().contains("just a moment")
                || title.lowercased().contains("cloudflare")
            if isChallenge {
                LogManager.shared.log("nhBridge", "FavNav: Cloudflare challenge, waiting...")
                return // タイムアウトまで待つか次のdidFinishを待つ
            }
            LogManager.shared.log("nhBridge", "FavNav: loaded title=\(title.prefix(50))")
            self.loaded = true
            self.continuation = nil
            cont.resume()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        LogManager.shared.log("nhBridge", "FavNav: failed \(error.localizedDescription)")
        if let cont = continuation {
            continuation = nil
            loaded = true
            cont.resume()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        LogManager.shared.log("nhBridge", "FavNav: provisional failed \(error.localizedDescription)")
        if let cont = continuation {
            continuation = nil
            loaded = true
            cont.resume()
        }
    }
}
#endif
