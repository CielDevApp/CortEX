import Foundation
#if canImport(UIKit)
import WebKit

/// WKWebViewでnhentaiお気に入りページをレンダリングし、ギャラリーIDを抽出
@MainActor
class NhentaiFavoritesFetcher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var pageContinuation: CheckedContinuation<(ids: [Int], hasNext: Bool), Error>?

    /// 単一ページのお気に入りギャラリーIDを取得
    /// NhentaiWebBridge (API v2と同じclean cookie WebView) 経由でHTMLを取得することで、
    /// 独立したWebViewで発生する stale cookie / 二重セッション問題を回避
    func fetchFavoritePage(page: Int) async throws -> (ids: [Int], hasNext: Bool) {
        LogManager.shared.log("nhFav", "[1] fetchFavoritePage start: page=\(page) (via nhBridge)")

        let url = "https://nhentai.net/favorites/?page=\(page)"
        let data: Data
        do {
            data = try await NhentaiWebBridge.shared.fetch(url: url, cookieOnly: true)
        } catch {
            LogManager.shared.log("nhFav", "[ERROR] bridge fetch failed: \(error.localizedDescription)")
            throw error
        }

        guard let html = String(data: data, encoding: .utf8) else {
            LogManager.shared.log("nhFav", "[ERROR] failed to decode HTML from bridge response")
            throw URLError(.cannotDecodeContentData)
        }

        // /login にリダイレクトされた場合
        if html.contains("Abandon all hope") || html.contains("name=\"username\"") {
            LogManager.shared.log("nhFav", "[ERROR] redirected to login page - session invalid")
            return (ids: [], hasNext: false)
        }

        // 正規表現でギャラリーIDを抽出 (/g/12345/)
        var ids: [Int] = []
        let pattern = #"/g/(\d+)/"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                if let range = Range(match.range(at: 1), in: html), let id = Int(html[range]) {
                    if !ids.contains(id) { ids.append(id) }
                }
            }
        }

        // 次ページの存在確認 (pagination, rel="next", Next link)
        let hasNext = html.contains("rel=\"next\"")
            || html.contains("class=\"next\"")
            || html.range(of: #"page=\#(page + 1)"#, options: .regularExpression) != nil

        LogManager.shared.log("nhFav", "[DONE] page \(page): \(ids.count) IDs, hasNext=\(hasNext), html=\(html.count) bytes")
        return (ids: ids, hasNext: hasNext)
    }

    /// 全ページのお気に入りを取得
    func fetchAllFavoriteIds() async throws -> [Int] {
        LogManager.shared.log("nhFav", "[0] fetchAllFavoriteIds start")
        var allIds: [Int] = []
        var page = 1

        while true {
            let (ids, hasNext) = try await fetchFavoritePage(page: page)
            allIds.append(contentsOf: ids)
            LogManager.shared.log("nhFav", "[DONE] page \(page): \(ids.count) IDs, hasNext=\(hasNext), total=\(allIds.count)")

            if !hasNext || ids.isEmpty { break }
            page += 1
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        LogManager.shared.log("nhFav", "[DONE] all pages done: \(allIds.count) IDs")
        return allIds
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            LogManager.shared.log("nhFav", "[NAV] didStartProvisionalNavigation url=\(webView.url?.absoluteString ?? "nil")")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let url = webView.url?.absoluteString ?? "nil"
            LogManager.shared.log("nhFav", "[NAV] didFinish url=\(url)")

            // ページタイトル確認
            webView.evaluateJavaScript("document.title") { result, _ in
                let title = result as? String ?? "(nil)"
                LogManager.shared.log("nhFav", "[NAV] title=\(title)")
            }

            // SPA描画待ち: 2秒
            LogManager.shared.log("nhFav", "[4] waiting 2s for SPA render...")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            LogManager.shared.log("nhFav", "[5] extracting IDs...")
            self.extractIds(from: webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            LogManager.shared.log("nhFav", "[NAV] didFail: \(error.localizedDescription)")
            if let cont = self.pageContinuation {
                self.pageContinuation = nil
                self.webView = nil
                cont.resume(throwing: error)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            LogManager.shared.log("nhFav", "[NAV] didFailProvisional: \(error.localizedDescription)")
            if let cont = self.pageContinuation {
                self.pageContinuation = nil
                self.webView = nil
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - JavaScript抽出

    private func extractIds(from webView: WKWebView) {
        // Step 1: ページ状態を診断
        let diagJS = """
        (function() {
            var allLinks = document.querySelectorAll('a');
            var gLinks = document.querySelectorAll('a[href*="/g/"]');
            var containers = document.querySelectorAll('.gallery-favorite, .gallery, .container');
            var body = document.body ? document.body.innerText.substring(0, 500) : '(no body)';
            return JSON.stringify({
                totalLinks: allLinks.length,
                gLinks: gLinks.length,
                containers: containers.length,
                bodyLen: document.body ? document.body.innerText.length : 0,
                bodyPreview: body,
                url: window.location.href,
                cookies: document.cookie
            });
        })()
        """

        webView.evaluateJavaScript(diagJS) { [weak self] result, error in
            if let jsonStr = result as? String {
                LogManager.shared.log("nhFav", "[DIAG] \(jsonStr)")
            } else {
                LogManager.shared.log("nhFav", "[DIAG] failed: \(error?.localizedDescription ?? "nil")")
            }

            // Step 2: ギャラリーID抽出
            self?.extractGalleryIds(from: webView)
        }
    }

    private func extractGalleryIds(from webView: WKWebView) {
        let js = """
        (function() {
            var ids = [];
            var links = document.querySelectorAll('a[href*="/g/"]');
            links.forEach(function(a) {
                var m = a.href.match(/\\/g\\/(\\d+)\\//);
                if (m && ids.indexOf(parseInt(m[1])) === -1) {
                    ids.push(parseInt(m[1]));
                }
            });
            var paginateLinks = document.querySelectorAll('.pagination a, a.page, a[href*="page="]');
            var hasNext = false;
            paginateLinks.forEach(function(a) {
                if (a.classList.contains('next') || a.textContent.trim() === '>' || a.textContent.trim() === 'Next') {
                    hasNext = true;
                }
            });
            if (!hasNext) {
                hasNext = document.querySelector('a.next, .next a, a[rel="next"]') !== null;
            }
            return JSON.stringify({ids: ids, hasNext: hasNext, paginateCount: paginateLinks.length});
        })()
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }

            if let jsonStr = result as? String,
               let jsonData = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let ids = json["ids"] as? [Int] {

                let hasNext = json["hasNext"] as? Bool ?? false
                let paginateCount = json["paginateCount"] as? Int ?? 0
                LogManager.shared.log("nhFav", "[EXTRACT] ids=\(ids.count) hasNext=\(hasNext) paginateLinks=\(paginateCount)")

                if ids.isEmpty {
                    LogManager.shared.log("nhFav", "[EXTRACT] 0 IDs found, trying innerHTML fallback...")
                    self.fallbackExtract(from: webView)
                    return
                }

                if let cont = self.pageContinuation {
                    self.pageContinuation = nil
                    self.webView = nil
                    cont.resume(returning: (ids: ids, hasNext: hasNext))
                }
            } else {
                LogManager.shared.log("nhFav", "[EXTRACT] JS error: \(error?.localizedDescription ?? "nil"), result=\(String(describing: result))")
                self.fallbackExtract(from: webView)
            }
        }
    }

    private func fallbackExtract(from webView: WKWebView) {
        webView.evaluateJavaScript("document.documentElement.innerHTML.substring(0, 3000)") { [weak self] result, _ in
            guard let self = self else { return }

            var ids: [Int] = []
            if let html = result as? String {
                LogManager.shared.log("nhFav", "[FALLBACK] innerHTML preview (\(html.count) chars): \(String(html.prefix(500)))")

                let pattern = #"/g/(\d+)/"#
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                    for match in matches {
                        if let range = Range(match.range(at: 1), in: html), let id = Int(html[range]) {
                            if !ids.contains(id) { ids.append(id) }
                        }
                    }
                }
                LogManager.shared.log("nhFav", "[FALLBACK] regex found \(ids.count) IDs")
            } else {
                LogManager.shared.log("nhFav", "[FALLBACK] innerHTML is nil")
            }

            if let cont = self.pageContinuation {
                self.pageContinuation = nil
                self.webView = nil
                cont.resume(returning: (ids: ids, hasNext: false))
            }
        }
    }
}
#endif
