import Foundation

/// nhentai API クライアント
enum NhentaiClient {

    // MARK: - Models

    struct NhGallery: Codable, Identifiable, Hashable, Sendable {
        static func == (lhs: NhGallery, rhs: NhGallery) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        let id: Int
        let media_id: String
        let title: NhTitle
        let images: NhImages
        let num_pages: Int
        let tags: [NhTag]?

        var displayTitle: String { title.japanese ?? title.english ?? title.pretty ?? "\(id)" }
        var englishTitle: String { title.english ?? title.pretty ?? "\(id)" }

        // nhentai APIは大きいIDを文字列で返すことがある
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let intId = try? c.decode(Int.self, forKey: .id) {
                id = intId
            } else {
                let strId = try c.decode(String.self, forKey: .id)
                id = Int(strId) ?? 0
            }
            media_id = try c.decode(String.self, forKey: .media_id)
            title = try c.decode(NhTitle.self, forKey: .title)
            images = try c.decode(NhImages.self, forKey: .images)
            num_pages = try c.decode(Int.self, forKey: .num_pages)
            tags = try c.decodeIfPresent([NhTag].self, forKey: .tags)
        }

        private enum CodingKeys: String, CodingKey {
            case id, media_id, title, images, num_pages, tags
        }

        // NhentaiFavoritesCache用の手動init
        init(id: Int, media_id: String, title: NhTitle, images: NhImages, num_pages: Int, tags: [NhTag]?) {
            self.id = id; self.media_id = media_id; self.title = title
            self.images = images; self.num_pages = num_pages; self.tags = tags
        }
    }

    struct NhTitle: Codable, Sendable {
        let english: String?
        let japanese: String?
        let pretty: String?
    }

    struct NhImages: Codable, Sendable {
        let pages: [NhPage]
        let cover: NhPage?
        let thumbnail: NhPage?
    }

    struct NhPage: Codable, Sendable {
        let t: String  // j=jpg, p=png, g=gif
        let w: Int
        let h: Int

        var ext: String {
            switch t {
            case "j": return "jpg"
            case "p": return "png"
            case "g": return "gif"
            case "w": return "webp"
            default: return "jpg"
            }
        }
    }

    struct NhTag: Codable, Sendable {
        let id: Int
        let type: String
        let name: String
        let url: String?
        let count: Int?
    }

    struct NhSearchResult: Codable, Sendable {
        let result: [NhGallery]
        let num_pages: Int
        let per_page: Int
    }

    // MARK: - API

    /// CDN画像用セッション（並列1制限 = レート制限対策）
    private static let cdnSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 1
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    /// API/HTML用セッション（CDN画像DLにブロックされない）
    private static let apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    /// WKWebViewと同一UA（Cloudflareフィンガープリント一致のため）
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Cloudflare対策: Cookie + Referer + UA 付きリクエストを生成
    private static func buildRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let cookie = NhentaiCookieManager.cookieHeader() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.setValue("https://nhentai.net/", forHTTPHeaderField: "Referer")
        return request
    }

    /// ギャラリー情報取得
    static func fetchGallery(id: Int) async throws -> NhGallery {
        let url = URL(string: "https://nhentai.net/api/gallery/\(id)")!
        let request = buildRequest(url: url)
        let (data, _) = try await apiSession.data(for: request)
        return try JSONDecoder().decode(NhGallery.self, from: data)
    }

    /// タイトル検索（sort: nil, "popular", "popular-today", "popular-week"）
    static func search(query: String, page: Int = 1, sort: String? = nil) async throws -> NhSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var urlString: String
        var clientFilter: String? = nil

        if trimmed.isEmpty && (sort == nil || sort?.isEmpty == true) {
            // 空クエリ＆ソートなし → 全件API（新着順）
            urlString = "https://nhentai.net/api/galleries/all?page=\(page)"
        } else {
            var searchQuery = trimmed
            if searchQuery.isEmpty {
                // 空クエリだがソートあり → search APIに""で投げる
                searchQuery = "\"\""
            } else if !searchQuery.contains(":") && !searchQuery.hasPrefix("\"") {
                // タグ形式でなければ引用符で囲む（フレーズ検索）
                searchQuery = "\"\(searchQuery)\""
                clientFilter = trimmed.lowercased()
            }
            let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
            urlString = "https://nhentai.net/api/galleries/search?query=\(encoded)&page=\(page)"
        }

        if let sort, !sort.isEmpty {
            urlString += "&sort=\(sort)"
        }

        LogManager.shared.log("nhentai", "API: \(urlString)")
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let request = buildRequest(url: url)
        let (data, response) = try await apiSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        LogManager.shared.log("nhentai", "response: status=\(status) size=\(data.count)")
        var result: NhSearchResult
        do {
            result = try JSONDecoder().decode(NhSearchResult.self, from: data)
        } catch let decodingError as DecodingError {
            switch decodingError {
            case .typeMismatch(let type, let ctx):
                LogManager.shared.log("nhentai", "decode typeMismatch: \(type) at \(ctx.codingPath.map(\.stringValue)) - \(ctx.debugDescription)")
            case .valueNotFound(let type, let ctx):
                LogManager.shared.log("nhentai", "decode valueNotFound: \(type) at \(ctx.codingPath.map(\.stringValue))")
            case .keyNotFound(let key, let ctx):
                LogManager.shared.log("nhentai", "decode keyNotFound: \(key.stringValue) at \(ctx.codingPath.map(\.stringValue))")
            case .dataCorrupted(let ctx):
                LogManager.shared.log("nhentai", "decode dataCorrupted: \(ctx.codingPath.map(\.stringValue)) - \(ctx.debugDescription)")
            @unknown default:
                LogManager.shared.log("nhentai", "decode unknown: \(decodingError)")
            }
            throw decodingError
        }

        // クライアント側フィルタ: タイトルに検索語が含まれない結果を除外
        if let filter = clientFilter {
            let filtered = result.result.filter { gallery in
                let titles = [
                    gallery.title.english?.lowercased(),
                    gallery.title.japanese?.lowercased(),
                    gallery.title.pretty?.lowercased()
                ].compactMap { $0 }
                return titles.contains { $0.contains(filter) }
            }
            result = NhSearchResult(result: filtered, num_pages: result.num_pages, per_page: result.per_page)
        }

        return result
    }

    // MARK: - CDN動的解決（HTMLスクレイピング）

    /// CDNホスト名キャッシュ: galleryId -> (imageCDN, thumbCDN)
    /// 例: 638831 -> ("i7", "t7")
    private static var cdnCache: [Int: (image: String, thumb: String)] = [:]

    /// ギャラリーページをスクレイピングして実際のCDN URLを取得
    /// ※nhentaiはSPAのためHTMLに画像URLが含まれず、現在はほぼ機能しない
    /// WebP修正により直接CDNアクセスが動作するため、フォールバック用途のみ
    private static func discoverCDN(galleryId: Int) async -> (image: String, thumb: String)? {
        // galleryId=0（旧互換API）の場合はスキップ
        guard galleryId > 0 else { return nil }
        // キャッシュ確認
        if let cached = cdnCache[galleryId] { return cached }

        let pageURL = URL(string: "https://nhentai.net/g/\(galleryId)/1/")!
        let request = buildRequest(url: pageURL)

        guard let (data, response) = try? await apiSession.data(for: request) else { return nil }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let html = String(data: data, encoding: .utf8) else { return nil }

        // 画像URLを抽出（SPA上では通常見つからない）
        let imgPattern = #"https?://([a-z0-9]+)\.nhentai\.net/galleries/\d+/\d+\.\w+"#
        if let regex = try? NSRegularExpression(pattern: imgPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let img = String(html[range])
            let result = (image: img, thumb: img.replacingOccurrences(of: "i", with: "t"))
            cdnCache[galleryId] = result
            LogManager.shared.log("nhentai", "CDN discovered: gallery=\(galleryId) image=\(result.image)")
            return result
        }

        return nil
    }

    // MARK: - 画像URL

    private static let fallbackImageCDNs = ["i", "i1", "i2", "i3"]
    private static let fallbackThumbCDNs = ["t", "t1", "t2", "t3"]

    /// ページ画像URL（デフォルトCDN）
    static func imageURL(mediaId: String, page: Int, ext: String) -> URL {
        URL(string: "https://i.nhentai.net/galleries/\(mediaId)/\(page).\(ext)")!
    }

    /// サムネURL
    static func thumbURL(mediaId: String, page: Int, ext: String) -> URL {
        URL(string: "https://t.nhentai.net/galleries/\(mediaId)/\(page)t.\(ext)")!
    }

    /// カバーURL
    static func coverURL(mediaId: String, ext: String) -> URL {
        URL(string: "https://t.nhentai.net/galleries/\(mediaId)/cover.\(ext)")!
    }

    // MARK: - 画像データ取得

    /// HTMLレスポンス検出
    private static func isHTMLResponse(_ data: Data) -> Bool {
        guard data.count < 10000, let first = data.first else { return false }
        return first == 0x3C // '<'
    }

    /// 単一URLで画像データ取得（CDNセッション使用）
    private static func fetchRawImage(url: URL) async -> (data: Data, status: Int)? {
        let request = buildRequest(url: url)
        guard let (data, response) = try? await cdnSession.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    /// サムネ/カバー用の軽量取得（apiSession使用、並列制限なし）
    /// サムネ/カバー用
    private static func fetchLightImage(url: URL) async -> (data: Data, status: Int)? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://nhentai.net/", forHTTPHeaderField: "Referer")
        if let cookie = NhentaiCookieManager.cookieHeader() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 && url.pathExtension == "webp" {
                LogManager.shared.log("nhentai", "lightImage: \(url.lastPathComponent) status=\(status)")
            }
            return (data, status)
        } catch {
            LogManager.shared.log("nhentai", "lightImage throw: \(error.localizedDescription) code=\((error as NSError).code) url=\(url.lastPathComponent)")
            return nil
        }
    }

    /// 画像データ取得（単一URL、CDNフォールバック付き）
    static func fetchImageData(url: URL) async throws -> Data {
        // まず直接試行
        if let result = await fetchRawImage(url: url),
           result.status == 200 && !result.data.isEmpty && !isHTMLResponse(result.data) {
            return result.data
        }

        // フォールバック: CDN切替
        let cdns = url.host?.starts(with: "t") == true ? fallbackThumbCDNs : fallbackImageCDNs
        for cdn in cdns {
            let altStr = url.absoluteString
                .replacingOccurrences(of: #"://[a-z]\d*\."#, with: "://\(cdn).", options: .regularExpression)
            guard let altURL = URL(string: altStr), altURL != url else { continue }
            if let result = await fetchRawImage(url: altURL),
               result.status == 200 && !result.data.isEmpty && !isHTMLResponse(result.data) {
                return result.data
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        throw URLError(.badServerResponse)
    }

    /// ページ画像取得（CDN動的解決 + フォールバック）
    static func fetchPageImage(galleryId: Int, mediaId: String, page: Int, ext: String) async throws -> Data {
        // 1. CDN動的解決（ギャラリーページHTMLから実際のCDN URLを取得）
        if let cdn = await discoverCDN(galleryId: galleryId) {
            let url = URL(string: "https://\(cdn.image).nhentai.net/galleries/\(mediaId)/\(page).\(ext)")!
            if let result = await fetchRawImage(url: url),
               result.status == 200 && !result.data.isEmpty && !isHTMLResponse(result.data) {
                return result.data
            }
            LogManager.shared.log("nhentai", "discovered CDN \(cdn.image) failed: page \(page)")
        }

        // 2. フォールバック: 全CDNを試行
        for (i, cdn) in fallbackImageCDNs.enumerated() {
            let url = URL(string: "https://\(cdn).nhentai.net/galleries/\(mediaId)/\(page).\(ext)")!
            if let result = await fetchRawImage(url: url) {
                if result.status == 200 && !result.data.isEmpty && !isHTMLResponse(result.data) {
                    // 成功したCDNをキャッシュ
                    cdnCache[galleryId] = (image: cdn, thumb: cdn.replacingOccurrences(of: "i", with: "t"))
                    LogManager.shared.log("nhentai", "CDN \(cdn) works! cached for gallery \(galleryId)")
                    return result.data
                }
                if i == 0 {
                    let body = String(data: result.data.prefix(200), encoding: .utf8) ?? "(binary)"
                    LogManager.shared.log("nhentai", "CDN \(cdn): page \(page) status=\(result.status) size=\(result.data.count) body=\(body)")
                }
            }
            if i < fallbackImageCDNs.count - 1 {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        throw URLError(.badServerResponse)
    }

    /// ページ画像取得（galleryId不明の場合の旧互換API）
    static func fetchPageImage(mediaId: String, page: Int, ext: String) async throws -> Data {
        return try await fetchPageImage(galleryId: 0, mediaId: mediaId, page: page, ext: ext)
    }

    /// カバー画像取得（拡張子フォールバック付き）
    static func fetchCoverImage(galleryId: Int, mediaId: String, ext: String) async throws -> Data {
        var exts = [ext]
        for e in ["jpg", "webp", "png"] where e != ext { exts.append(e) }

        for tryExt in exts {
            let url = URL(string: "https://t.nhentai.net/galleries/\(mediaId)/cover.\(tryExt)")!
            if let result = await fetchLightImage(url: url),
               result.status == 200 && !result.data.isEmpty && !isHTMLResponse(result.data) {
                return result.data
            }
        }

        throw URLError(.badServerResponse)
    }

    /// サムネ画像取得（拡張子フォールバック付き）
    static func fetchThumbImage(mediaId: String, page: Int, ext: String) async throws -> Data {
        var exts = [ext]
        for e in ["jpg", "webp", "png"] where e != ext { exts.append(e) }

        for tryExt in exts {
            let url = URL(string: "https://t.nhentai.net/galleries/\(mediaId)/\(page)t.\(tryExt)")!
            if let result = await fetchLightImage(url: url),
               result.status == 200 && !result.data.isEmpty && !isHTMLResponse(result.data) {
                return result.data
            }
        }

        throw URLError(.badServerResponse)
    }

    /// カバー画像取得（galleryId不明の旧互換API）
    static func fetchCoverImage(mediaId: String, ext: String) async throws -> Data {
        return try await fetchCoverImage(galleryId: 0, mediaId: mediaId, ext: ext)
    }

    // MARK: - お気に入り操作（要ログイン）

    /// お気に入り登録/解除トグル
    static func toggleFavorite(galleryId: Int) async throws -> Bool {
        let url = URL(string: "https://nhentai.net/api/gallery/\(galleryId)/favorite")!
        var request = buildRequest(url: url)
        request.httpMethod = "POST"
        // CSRFトークン
        if let cookies = NhentaiCookieManager.loadCookies() {
            for part in cookies.components(separatedBy: "; ") {
                if part.hasPrefix("csrftoken=") {
                    let token = String(part.dropFirst("csrftoken=".count))
                    request.setValue(token, forHTTPHeaderField: "X-CSRFToken")
                }
            }
        }

        let (data, response) = try await apiSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        LogManager.shared.log("nhentai", "toggleFavorite id=\(galleryId) status=\(status)")

        // レスポンス: {"favorited": true/false}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let favorited = json["favorited"] as? Bool {
            return favorited
        }
        return status == 200
    }

    /// お気に入り1ページ取得（HTML解析）→ (galleries, hasNextPage)
    static func fetchFavoritesPage(page: Int) async throws -> (galleries: [NhGallery], hasNext: Bool) {
        guard NhentaiCookieManager.isLoggedIn() else {
            LogManager.shared.log("nhFav", "not logged in, skipping")
            return ([], false)
        }

        LogManager.shared.log("nhFav", "fetching page \(page)...")
        let url = URL(string: "https://nhentai.net/favorites/?page=\(page)")!
        let request = buildRequest(url: url)
        let (data, response) = try await apiSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let html = String(data: data, encoding: .utf8) else {
            LogManager.shared.log("nhFav", "page \(page): failed to decode HTML")
            return ([], false)
        }

        LogManager.shared.log("nhFav", "page \(page): status=\(status) html=\(html.count) chars")

        // お気に入りページからギャラリーIDを抽出
        var ids: [Int] = []
        let idPattern = #"/g/(\d+)/"#
        if let regex = try? NSRegularExpression(pattern: idPattern) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                if let range = Range(match.range(at: 1), in: html), let id = Int(html[range]) {
                    if !ids.contains(id) { ids.append(id) }
                }
            }
        }

        LogManager.shared.log("nhFav", "page \(page): found \(ids.count) gallery IDs")

        if ids.isEmpty && html.count > 0 {
            let preview = String(html.prefix(300)).replacingOccurrences(of: "\n", with: " ")
            LogManager.shared.log("nhFav", "page \(page) HTML: \(preview)")
        }

        // 次ページ判定
        let hasNext = html.contains("page=\(page + 1)") || html.contains("class=\"next\"")

        // 各IDのギャラリー情報をAPI取得
        var galleries: [NhGallery] = []
        for (i, id) in ids.enumerated() {
            if let g = try? await fetchGallery(id: id) {
                galleries.append(g)
            }
            if i < ids.count - 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        LogManager.shared.log("nhFav", "page \(page): \(galleries.count)/\(ids.count) resolved, hasNext=\(hasNext)")
        return (galleries, hasNext)
    }

    /// お気に入り全件取得（全ページ巡回）
    static func fetchAllFavorites() async throws -> [NhGallery] {
        var all: [NhGallery] = []
        var page = 1

        while true {
            let (galleries, hasNext) = try await fetchFavoritesPage(page: page)
            all.append(contentsOf: galleries)
            if !hasNext || galleries.isEmpty { break }
            page += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000) // ページ間1秒
        }

        LogManager.shared.log("nhentai", "favorites total: \(all.count) items (\(page) pages)")
        return all
    }

    /// お気に入り一覧取得（旧互換API）
    static func fetchFavorites(page: Int = 1) async throws -> [NhGallery] {
        let (galleries, _) = try await fetchFavoritesPage(page: page)
        return galleries
    }

    // MARK: - ヘルパー

    /// E-Hentaiタイトルからnhentai検索クエリを生成
    static func buildSearchQuery(from title: String) -> String {
        var q = title
        // [サークル名] を除去
        q = q.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        // (イベント名) を除去
        q = q.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        // | 以降を除去
        if let barIndex = q.firstIndex(of: "|") {
            q = String(q[q.startIndex..<barIndex])
        }
        return q.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// CDNキャッシュクリア
    static func clearCDNCache() {
        cdnCache.removeAll()
    }
}
