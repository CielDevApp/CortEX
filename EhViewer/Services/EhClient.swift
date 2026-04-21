import Foundation
import UIKit

final class EhClient: Sendable {
    static let shared = EhClient()

    private let session: URLSession
    /// サムネ用高速セッション（並列数増、タイムアウト短）
    let thumbSession: URLSession

    nonisolated private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config)

        let thumbConfig = URLSessionConfiguration.default
        thumbConfig.httpCookieAcceptPolicy = .never
        thumbConfig.httpShouldSetCookies = false
        thumbConfig.httpCookieStorage = nil
        thumbConfig.timeoutIntervalForRequest = 10
        thumbConfig.httpMaximumConnectionsPerHost = SafetyMode.shared.isEnabled ? 6 : 20
        thumbConfig.requestCachePolicy = .returnCacheDataElseLoad
        self.thumbSession = URLSession(configuration: thumbConfig)
    }

    // MARK: - Gallery List

    nonisolated func fetchGalleryList(host: GalleryHost, page: Int = 0, searchQuery: String? = nil, categoryFilter: Int? = nil) async throws -> (galleries: [Gallery], pageNumber: PageNumber) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var urlString = host.baseURL + "/"
        var queryItems: [String] = []

        if let query = searchQuery, !query.isEmpty {
            queryItems.append("f_search=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")
        }
        if let cats = categoryFilter {
            queryItems.append("f_cats=\(cats)")
        }
        if !queryItems.isEmpty {
            urlString += "?" + queryItems.joined(separator: "&")
        }

        LogManager.shared.log("Reader", "fetchGalleryList URL: \(urlString)")

        let html = try await fetchHTML(urlString: urlString, host: host)
        let galleries = HTMLParser.parseGalleryList(html: html)
        let pageNumber = HTMLParser.parsePageNumber(html: html)

        if let first = galleries.first, let last = galleries.last {
            LogManager.shared.log("Reader", "  \(galleries.count)件 first=\(first.postedDate) last=\(last.postedDate) hasNext=\(pageNumber.hasNext)")
        } else {
            LogManager.shared.log("Reader", "  0件")
        }

        LogManager.shared.log("Perf", "fetchGalleryList: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms count=\(galleries.count) page=\(page)")
        return (galleries, pageNumber)
    }

    // MARK: - Favorites

    nonisolated func fetchFavorites(host: GalleryHost, category: Int = -1, page: Int = 0) async throws -> (galleries: [Gallery], pageNumber: PageNumber) {
        var urlString = host.baseURL + "/favorites.php"
        var queryItems: [String] = []

        if category >= 0 {
            queryItems.append("favcat=\(category)")
        } else {
            queryItems.append("favcat=all")
        }
        if page > 0 {
            queryItems.append("page=\(page)")
        }
        if !queryItems.isEmpty {
            urlString += "?" + queryItems.joined(separator: "&")
        }

        let html = try await fetchHTML(urlString: urlString, host: host)
        let galleries = HTMLParser.parseGalleryList(html: html)
        let pageNumber = HTMLParser.parsePageNumber(html: html)
        return (galleries, pageNumber)
    }

    /// nextURLを使って次のページを取得（searchnavベースのページネーション用）
    nonisolated func fetchByURL(urlString: String, host: GalleryHost) async throws -> (galleries: [Gallery], pageNumber: PageNumber) {
        let html = try await fetchHTML(urlString: urlString, host: host)
        let galleries = HTMLParser.parseGalleryList(html: html)
        let pageNumber = HTMLParser.parsePageNumber(html: html)
        return (galleries, pageNumber)
    }

    // MARK: - Bulk Tag Fetch (E-Hentai API)

    /// E-Hentai JSON APIでギャラリーのタグをバルク取得（最大25件/リクエスト）
    nonisolated func fetchGalleryTags(galleries: [Gallery]) async -> [Int: [String]] {
        var result: [Int: [String]] = [:]

        // GID重複排除（お気に入りキャッシュに重複がある場合）
        var seen = Set<Int>()
        let unique = galleries.filter { seen.insert($0.gid).inserted }
        LogManager.shared.log("EhAPI", "fetchGalleryTags: \(galleries.count) input, \(unique.count) unique")

        let chunks = stride(from: 0, to: unique.count, by: 25).map {
            Array(unique[$0..<min($0 + 25, unique.count)])
        }

        for chunk in chunks {
            let gidlist = chunk.map { [$0.gid, $0.token] as [Any] }
            let body: [String: Any] = [
                "method": "gdata",
                "gidlist": gidlist,
                "namespace": 1
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
                  let url = URL(string: "https://api.e-hentai.org/api.php") else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = jsonData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let gmetadata = json["gmetadata"] as? [[String: Any]] else {
                LogManager.shared.log("EhAPI", "gdata request failed for \(chunk.count) items")
                continue
            }

            var parsed = 0
            var errors = 0
            for meta in gmetadata {
                // 削除済みギャラリーはerrorフィールドを持つ
                if meta["error"] != nil { errors += 1; continue }
                // gid: Int or NSNumber
                let gid: Int
                if let n = meta["gid"] as? NSNumber { gid = n.intValue }
                else if let i = meta["gid"] as? Int { gid = i }
                else { continue }
                // tags: [String] or [Any]
                let tags: [String]
                if let s = meta["tags"] as? [String] { tags = s }
                else if let a = meta["tags"] as? [Any] { tags = a.compactMap { $0 as? String } }
                else { continue }
                result[gid] = tags
                parsed += 1
            }

            LogManager.shared.log("EhAPI", "gdata: \(gmetadata.count) fetched, \(parsed) ok, \(errors) deleted, total=\(result.count)")
            // レートリミット対策
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return result
    }

    // MARK: - Gallery Detail

    nonisolated func fetchGalleryDetail(host: GalleryHost, gallery: Gallery) async throws -> GalleryDetail {
        let t0 = CFAbsoluteTimeGetCurrent()
        let urlString = gallery.galleryURL(host: host) + "?hc=1"
        let html = try await fetchHTML(urlString: urlString, host: host)
        let detail = HTMLParser.parseGalleryDetail(html: html, gallery: gallery)
        LogManager.shared.log("Perf", "fetchGalleryDetail: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms gid=\(gallery.gid)")
        return detail
    }

    // MARK: - Image Pages

    nonisolated func fetchImagePageURLs(host: GalleryHost, gallery: Gallery, page: Int = 0) async throws -> [URL] {
        let t0 = CFAbsoluteTimeGetCurrent()
        var urlString = gallery.galleryURL(host: host)
        if page > 0 {
            urlString += "?p=\(page)"
        }
        let html = try await fetchHTML(urlString: urlString, host: host)
        let urls = HTMLParser.parseImagePageURLs(html: html)
        LogManager.shared.log("Perf", "fetchImagePageURLs: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms count=\(urls.count) page=\(page) gid=\(gallery.gid)")
        return urls
    }

    /// ギャラリーページからサムネイル情報を取得
    nonisolated func fetchThumbnailInfos(host: GalleryHost, gallery: Gallery, page: Int = 0) async throws -> [ThumbnailInfo] {
        let t0 = CFAbsoluteTimeGetCurrent()
        var urlString = gallery.galleryURL(host: host)
        if page > 0 {
            urlString += "?p=\(page)"
        }
        let html = try await fetchHTML(urlString: urlString, host: host)
        let infos = HTMLParser.parseThumbnailInfos(html: html)
        LogManager.shared.log("Reader", "fetchThumbnailInfos page=\(page) count=\(infos.count)")
        if let first = infos.first {
            LogManager.shared.log("Reader", "  first: url=\(first.spriteURL) offsetX=\(first.offsetX) size=\(first.width)x\(first.height)")
        }
        LogManager.shared.log("Perf", "fetchThumbnailInfos: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms count=\(infos.count) page=\(page) gid=\(gallery.gid)")
        return infos
    }

    nonisolated func fetchImageURL(pageURL: URL) async throws -> URL {
        // 画像ページURLからホストを判定
        let host: GalleryHost = pageURL.host?.contains("exhentai") == true ? .exhentai : .ehentai
        let html = try await fetchHTMLViaBGOrFallback(urlString: pageURL.absoluteString, host: host)
        if let url = HTMLParser.parseFullImageURL(html: html) {
            return url
        }
        throw EhError.parseFailed
    }

    /// 別ミラーサーバーから画像URLを取得（nlトークン使用）
    nonisolated func fetchImageURLWithMirror(pageURL: URL) async throws -> URL {
        let host: GalleryHost = pageURL.host?.contains("exhentai") == true ? .exhentai : .ehentai

        // まずページHTMLを取得してnlトークンを探す
        let html = try await fetchHTMLViaBGOrFallback(urlString: pageURL.absoluteString, host: host)
        if let nlToken = HTMLParser.parseNLToken(html: html) {
            // nlトークンで別サーバーを要求
            let mirrorURLStr = pageURL.absoluteString + (pageURL.query != nil ? "&" : "?") + "nl=\(nlToken)"
            LogManager.shared.log("Download", "requesting mirror: \(mirrorURLStr)")
            let mirrorHTML = try await fetchHTMLViaBGOrFallback(urlString: mirrorURLStr, host: host)
            if let url = HTMLParser.parseFullImageURL(html: mirrorHTML) {
                return url
            }
        }
        // nlトークンがない場合は通常取得
        if let url = HTMLParser.parseFullImageURL(html: html) {
            return url
        }
        throw EhError.parseFailed
    }

    /// 案 4 の HTML fetch: 通常 fetchHTML (FG session) を直呼び。
    /// 以前は BG session 経由で lock 中継続を試みたが、BG session が空/不正 body を返す
    /// 不具合が発覚したため revert。lock 中は await が blocked、unlock で自然に resume される。
    /// ban 検知は fetchHTML 内で実装済み。
    ///
    /// 根因: FG URLSession はアプリが background 中に empty body (0B) を返し、
    /// fetchHTML は `notLoggedIn` を throw する。通常の指数バックオフでは background 期間を
    /// 乗り越えられず URL 解決が途中打ち切りになる。
    /// 対処: 0B 系失敗時に UIApplication.state を確認し、`.active` でなければ
    /// foreground 復帰まで最大 300 秒待機 (= ロック画面継続) → 復帰後に再試行。
    /// banned / galleryRemoved は即時 throw (retry 無意味)。
    nonisolated func fetchHTMLViaBGOrFallback(urlString: String, host: GalleryHost) async throws -> String {
        let maxFgRetries = 3
        let maxBgWaitCycles = 5
        var fgRetries = 0
        var bgWaitCycles = 0
        var lastError: Error = EhError.parseFailed
        while true {
            do {
                return try await fetchHTML(urlString: urlString, host: host)
            } catch EhError.banned(let remaining) {
                throw EhError.banned(remaining: remaining)
            } catch EhError.galleryRemoved {
                throw EhError.galleryRemoved
            } catch EhError.invalidURL {
                throw EhError.invalidURL
            } catch {
                lastError = error
                let isBackgrounded = await MainActor.run { UIApplication.shared.applicationState != .active }
                if isBackgrounded {
                    bgWaitCycles += 1
                    if bgWaitCycles > maxBgWaitCycles { break }
                    LogManager.shared.log("Download", "fetchHTML backgrounded (cycle \(bgWaitCycles)/\(maxBgWaitCycles)), waiting foreground (err=\(error)) url=\(urlString.suffix(60))")
                    var waited = 0
                    while waited < 300 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        waited += 1
                        let nowActive = await MainActor.run { UIApplication.shared.applicationState == .active }
                        if nowActive { break }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                } else {
                    if fgRetries >= maxFgRetries { break }
                    let backoffMs: UInt64 = UInt64(500 * (1 << fgRetries))
                    LogManager.shared.log("Download", "fetchHTML retry \(fgRetries+1)/\(maxFgRetries) after \(backoffMs)ms (err=\(error)) url=\(urlString.suffix(60))")
                    try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
                    fgRetries += 1
                }
            }
        }
        throw lastError
    }

    /// 画像データをcookie付きでダウンロード（AsyncImageの代わりに使用）
    nonisolated func fetchImageData(url: URL, host: GalleryHost) async throws -> Data {
        let t0 = CFAbsoluteTimeGetCurrent()
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host), forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw EhError.parseFailed
        }
        guard !data.isEmpty else {
            throw EhError.parseFailed
        }
        LogManager.shared.log("Perf", "fetchImageData: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms \(data.count)B \(url.lastPathComponent)")
        return data
    }

    /// サムネ高速取得（並列15接続、短タイムアウト）
    /// BAN 検知: 画像のはずが HTML (text/html or 小サイズ HTML 本文) が返ってきたら
    /// The ban expires in... をパースして EhError.banned throw
    nonisolated func fetchThumbData(url: URL, host: GalleryHost) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host), forHTTPHeaderField: "Cookie")

        let (data, response) = try await thumbSession.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let status = httpResponse?.statusCode ?? 0

        // 503 / 429 / 509 / その他非 2xx: HTML 本文から BAN 文言を探す
        if !(200...299).contains(status) {
            let body = String(data: data.prefix(2000), encoding: .utf8) ?? ""
            if body.contains("The ban expires in") || body.contains("temporarily banned") {
                let remaining = Self.extractBanRemaining(from: data)
                LogManager.shared.log("eh-rate", "fetchThumbData BAN detected url=\(url.lastPathComponent) status=\(status) remaining=\(remaining ?? "nil")")
                throw EhError.banned(remaining: remaining)
            }
            LogManager.shared.log("eh-rate", "fetchThumbData http \(status) url=\(url.lastPathComponent)")
            throw EhError.parseFailed
        }

        // 200 だが Content-Type が text/html (本来は画像が返るはず): BAN ページ疑い
        if let ct = httpResponse?.value(forHTTPHeaderField: "Content-Type"),
           ct.lowercased().hasPrefix("text/html") {
            let body = String(data: data.prefix(2000), encoding: .utf8) ?? ""
            if body.contains("The ban expires in") || body.contains("temporarily banned") {
                let remaining = Self.extractBanRemaining(from: data)
                LogManager.shared.log("eh-rate", "fetchThumbData BAN (HTML 200) url=\(url.lastPathComponent) remaining=\(remaining ?? "nil")")
                throw EhError.banned(remaining: remaining)
            }
            LogManager.shared.log("eh-rate", "fetchThumbData unexpected HTML url=\(url.lastPathComponent) size=\(data.count)")
            throw EhError.parseFailed
        }

        guard !data.isEmpty else { throw EhError.parseFailed }
        return data
    }

    // MARK: - Add/Remove Favorite

    nonisolated func addFavorite(host: GalleryHost, gid: Int, token: String, category: Int = 0) async throws {
        let urlString = "\(host.baseURL)/gallerypopups.php?gid=\(gid)&t=\(token)&act=addfav"
        guard let url = URL(string: urlString) else { throw EhError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let cookie = Self.buildCookieHeader(for: host)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = "favcat=\(category)&favnote=&apply=Add+to+Favorites&update=1".data(using: .utf8)
        LogManager.shared.log("Favorite", "POST \(urlString) cookie=\(cookie.prefix(80))...")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
        LogManager.shared.log("Favorite", "response: status=\(status) body=\(body.prefix(150))")
    }

    nonisolated func removeFavorite(host: GalleryHost, gid: Int, token: String) async throws {
        let urlString = "\(host.baseURL)/gallerypopups.php?gid=\(gid)&t=\(token)&act=addfav"
        guard let url = URL(string: urlString) else { throw EhError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host), forHTTPHeaderField: "Cookie")
        request.httpBody = "favcat=favdel&favnote=&apply=Apply+Changes&update=1".data(using: .utf8)
        let _ = try await session.data(for: request)
    }

    // MARK: - Cookie Header

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Keychainから直接cookieヘッダを組み立てる（HTTPCookieStorageに依存しない）
    nonisolated private static func buildCookieHeader(for host: GalleryHost) -> String {
        var parts: [String] = []
        // Mac Catalyst は keychain-access-groups entitlement 無しだと KeychainService が
        // errSecMissingEntitlement(-34018) で失敗する。provisioning 契約更新が必要だが
        // 回避策として DEBUG build ではハードコード cookie を使う (iPad sim から吸い出した値)
        #if targetEnvironment(macCatalyst) && DEBUG
        let memberID: String? = "1532300"
        let passHash: String? = "28d002497da9623ccb2f6ffd144f633b"
        let igneous: String? = "1n2bd6yv2ulot91qa"
        #else
        let memberID = KeychainService.load(key: "ipb_member_id")
        let passHash = KeychainService.load(key: "ipb_pass_hash")
        let igneous = KeychainService.load(key: "igneous")
        #endif
        if let memberID {
            parts.append("ipb_member_id=\(memberID)")
        }
        if let passHash {
            parts.append("ipb_pass_hash=\(passHash)")
        }
        // exhentaiの場合はigneousとyayも付与
        if host == .exhentai {
            if let igneous, !igneous.isEmpty {
                parts.append("igneous=\(igneous)")
            }
            parts.append("yay=lousy")
        }
        // コンテンツ警告スキップ
        parts.append("nw=1")
        // 画像サイズを強制的に 1280px（スタンダード）にする
        // EH の account 設定が Original だと xres=org が配信され、動画WebP等で
        // 配信できないページが出る。スタンダード強制で安定性優先
        parts.append("uh=1280")
        parts.append("iir=3")  // 3=1280 in EH inline image resolution table
        return parts.joined(separator: "; ")
    }

    // MARK: - Networking

    nonisolated func fetchHTML(urlString: String, host: GalleryHost) async throws -> String {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let url = URL(string: urlString) else {
            throw EhError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host), forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        LogManager.shared.log("Perf", "fetchHTML: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms \(data.count)B \(urlString.suffix(60))")
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0

        // exhentai: SadPanda判定（画像レスポンスまたは302リダイレクト）
        if host == .exhentai {
            if let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type"),
               contentType.hasPrefix("image/") {
                throw EhError.notLoggedIn
            }
            if statusCode == 302 || statusCode == 403 {
                throw EhError.notLoggedIn
            }
        }

        if statusCode == 503 || statusCode == 429 {
            // 503/429のbodyからban残り時間を探す
            var remaining = Self.extractBanRemaining(from: data)
            // bodyに無ければトップページを別途fetchして探す
            if remaining == nil {
                remaining = try? await fetchBanRemaining(host: host)
            }
            throw EhError.banned(remaining: remaining)
        }

        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .shiftJIS)
                ?? String(data: data, encoding: .ascii) else {
            throw EhError.parseFailed
        }

        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)

        // exhentai: 空レスポンス = SadPanda
        if host == .exhentai && trimmed.isEmpty {
            throw EhError.notLoggedIn
        }

        if html.contains("The ban expires in") || html.contains("temporarily banned") {
            let remaining = Self.extractBanRemaining(from: data)
            throw EhError.banned(remaining: remaining)
        }
        if html.contains("This gallery has been removed") || html.contains("Gallery not found") {
            throw EhError.galleryRemoved
        }

        return html
    }

    // MARK: - レート実測用 /home.php 生 fetch

    /// /home.php を既存 Cookie / UA で fetch し生 HTML を返す。
    /// fetchHTML の ban 検知 throw を避けて、観測ログ用に常に String を返す。
    /// 失敗時は nil（呼び出し側で log 出して無視する想定）
    nonisolated func getHomePage(host: GalleryHost) async -> String? {
        let urlStr = host.baseURL + "/home.php"
        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host), forHTTPHeaderField: "Cookie")
        do {
            let (data, _) = try await session.data(for: request)
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .shiftJIS)
                ?? String(data: data, encoding: .ascii)
        } catch {
            return nil
        }
    }

    // MARK: - Ban残り時間抽出

    /// レスポンスbodyからban残り時間を抽出
    private static func extractBanRemaining(from data: Data) -> String? {
        guard let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { return nil }
        LogManager.shared.log("EhBan", "body(\(data.count)B): \(body.prefix(500))")
        // "The ban expires in 2 minutes and 23 seconds" パターン
        // ピリオドではなく、直接 "expires in" 以降の時間部分を正規表現で抽出
        let pattern = #"The ban expires in (.+?)(?:\.|<|$)"#
        if let match = body.range(of: pattern, options: .regularExpression) {
            let matched = String(body[match])
            // "The ban expires in " を除去して時間部分だけ取得
            let timeStr = matched
                .replacingOccurrences(of: "The ban expires in ", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "<", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !timeStr.isEmpty {
                return timeStr
            }
        }
        return nil
    }

    /// トップページを別途fetchしてban残り時間を取得
    nonisolated private func fetchBanRemaining(host: GalleryHost) async throws -> String? {
        let topURL = host.baseURL + "/"
        guard let url = URL(string: topURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host), forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 5

        // インスタンスのsessionを使う（Cookie手動管理と同じ設定）
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        LogManager.shared.log("EhBan", "topPage status=\(status) size=\(data.count)")
        return Self.extractBanRemaining(from: data)
    }
}

enum EhError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case notLoggedIn
    case banned(remaining: String?)
    case parseFailed
    case galleryRemoved

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidURL: return "無効なURL"
        case .notLoggedIn: return "ログインが必要です（ExHentaiにはigneousが必要です）"
        case .banned(let remaining):
            if let remaining {
                return "アクセスが制限されています（残り \(remaining)）"
            }
            return "アクセスが制限されています"
        case .parseFailed: return "ページの解析に失敗しました"
        case .galleryRemoved: return "ギャラリーが削除されています"
        }
    }
}
