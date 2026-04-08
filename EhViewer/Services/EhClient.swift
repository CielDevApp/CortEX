import Foundation

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
        thumbConfig.httpMaximumConnectionsPerHost = ExtremeMode.shared.isEnabled ? 20 : 6
        thumbConfig.requestCachePolicy = .returnCacheDataElseLoad
        self.thumbSession = URLSession(configuration: thumbConfig)
    }

    // MARK: - Gallery List

    nonisolated func fetchGalleryList(host: GalleryHost, page: Int = 0, searchQuery: String? = nil, categoryFilter: Int? = nil) async throws -> (galleries: [Gallery], pageNumber: PageNumber) {
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
        let chunks = stride(from: 0, to: galleries.count, by: 25).map {
            Array(galleries[$0..<min($0 + 25, galleries.count)])
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

            LogManager.shared.log("EhAPI", "gdata: \(gmetadata.count) fetched, \(parsed) ok, \(errors) deleted")
            // レートリミット対策
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return result
    }

    // MARK: - Gallery Detail

    nonisolated func fetchGalleryDetail(host: GalleryHost, gallery: Gallery) async throws -> GalleryDetail {
        let urlString = gallery.galleryURL(host: host) + "?hc=1"
        let html = try await fetchHTML(urlString: urlString, host: host)
        return HTMLParser.parseGalleryDetail(html: html, gallery: gallery)
    }

    // MARK: - Image Pages

    nonisolated func fetchImagePageURLs(host: GalleryHost, gallery: Gallery, page: Int = 0) async throws -> [URL] {
        var urlString = gallery.galleryURL(host: host)
        if page > 0 {
            urlString += "?p=\(page)"
        }
        let html = try await fetchHTML(urlString: urlString, host: host)
        return HTMLParser.parseImagePageURLs(html: html)
    }

    /// ギャラリーページからサムネイル情報を取得
    nonisolated func fetchThumbnailInfos(host: GalleryHost, gallery: Gallery, page: Int = 0) async throws -> [ThumbnailInfo] {
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
        return infos
    }

    nonisolated func fetchImageURL(pageURL: URL) async throws -> URL {
        // 画像ページURLからホストを判定
        let host: GalleryHost = pageURL.host?.contains("exhentai") == true ? .exhentai : .ehentai
        let html = try await fetchHTML(urlString: pageURL.absoluteString, host: host)
        if let url = HTMLParser.parseFullImageURL(html: html) {
            return url
        }
        throw EhError.parseFailed
    }

    /// 別ミラーサーバーから画像URLを取得（nlトークン使用）
    nonisolated func fetchImageURLWithMirror(pageURL: URL) async throws -> URL {
        let host: GalleryHost = pageURL.host?.contains("exhentai") == true ? .exhentai : .ehentai

        // まずページHTMLを取得してnlトークンを探す
        let html = try await fetchHTML(urlString: pageURL.absoluteString, host: host)
        if let nlToken = HTMLParser.parseNLToken(html: html) {
            // nlトークンで別サーバーを要求
            let mirrorURLStr = pageURL.absoluteString + (pageURL.query != nil ? "&" : "?") + "nl=\(nlToken)"
            LogManager.shared.log("Download", "requesting mirror: \(mirrorURLStr)")
            let mirrorHTML = try await fetchHTML(urlString: mirrorURLStr, host: host)
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

    /// 画像データをcookie付きでダウンロード（AsyncImageの代わりに使用）
    nonisolated func fetchImageData(url: URL, host: GalleryHost) async throws -> Data {
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
        return data
    }

    /// サムネ高速取得（並列15接続、短タイムアウト）
    nonisolated func fetchThumbData(url: URL, host: GalleryHost) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host), forHTTPHeaderField: "Cookie")

        let (data, response) = try await thumbSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
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
        if let memberID = KeychainService.load(key: "ipb_member_id") {
            parts.append("ipb_member_id=\(memberID)")
        }
        if let passHash = KeychainService.load(key: "ipb_pass_hash") {
            parts.append("ipb_pass_hash=\(passHash)")
        }
        // exhentaiの場合はigneousとyayも付与
        if host == .exhentai {
            if let igneous = KeychainService.load(key: "igneous"), !igneous.isEmpty {
                parts.append("igneous=\(igneous)")
            }
            parts.append("yay=lousy")
        }
        // コンテンツ警告スキップ
        parts.append("nw=1")
        return parts.joined(separator: "; ")
    }

    // MARK: - Networking

    nonisolated func fetchHTML(urlString: String, host: GalleryHost) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw EhError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host), forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
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
            throw EhError.banned
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

        if html.contains("The ban expires in") {
            throw EhError.banned
        }
        if html.contains("This gallery has been removed") || html.contains("Gallery not found") {
            throw EhError.galleryRemoved
        }

        return html
    }
}

enum EhError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case notLoggedIn
    case banned
    case parseFailed
    case galleryRemoved

    nonisolated var errorDescription: String? {
        switch self {
        case .invalidURL: return "無効なURL"
        case .notLoggedIn: return "ログインが必要です（ExHentaiにはigneousが必要です）"
        case .banned: return "アクセスが制限されています"
        case .parseFailed: return "ページの解析に失敗しました"
        case .galleryRemoved: return "ギャラリーが削除されています"
        }
    }
}
