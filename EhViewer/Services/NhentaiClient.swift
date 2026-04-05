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
        let images: NhImages?
        let num_pages: Int
        let tags: [NhTag]?
        let thumbnailPath: String?  // v2 search: サムネパス

        var displayTitle: String { title.japanese ?? title.english ?? title.pretty ?? "\(id)" }
        var englishTitle: String { title.english ?? title.pretty ?? "\(id)" }

        // v1 + v2 両対応デコーダー
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DecodingKeys.self)

            // ID: Int or String
            if let intId = try? c.decode(Int.self, forKey: .id) {
                id = intId
            } else {
                let strId = try c.decode(String.self, forKey: .id)
                id = Int(strId) ?? 0
            }

            media_id = try c.decode(String.self, forKey: .media_id)

            // title: v1は NhTitle オブジェクト、v2は english_title / japanese_title フラットフィールド
            if let titleObj = try? c.decode(NhTitle.self, forKey: .title) {
                title = titleObj
            } else {
                let en = try c.decodeIfPresent(String.self, forKey: .english_title)
                let jp = try c.decodeIfPresent(String.self, forKey: .japanese_title)
                title = NhTitle(english: en, japanese: jp, pretty: en)
            }

            // images: v1は NhImages オブジェクト、v2はトップレベルに pages/cover/thumbnail
            if let imagesObj = try? c.decode(NhImages.self, forKey: .images) {
                images = imagesObj
            } else {
                let pages = (try? c.decodeIfPresent([NhPage].self, forKey: .pages)) ?? []
                let cover = try? c.decodeIfPresent(NhPage.self, forKey: .cover)
                let thumb = try? c.decodeIfPresent(NhPage.self, forKey: .thumbnail)
                if !pages.isEmpty || cover != nil {
                    images = NhImages(pages: pages, cover: cover, thumbnail: thumb)
                } else {
                    images = nil
                }
            }

            // num_pages
            num_pages = (try? c.decode(Int.self, forKey: .num_pages)) ?? 0

            // tags: v1は [NhTag]、v2検索結果は tag_ids: [Int]
            if let tagObjs = try? c.decodeIfPresent([NhTag].self, forKey: .tags) {
                tags = tagObjs
            } else {
                tags = nil
            }

            // v2 search: thumbnail (文字列パス)
            if let thumbStr = try? c.decodeIfPresent(String.self, forKey: .thumbnail) {
                thumbnailPath = thumbStr
            } else {
                thumbnailPath = nil
            }
        }

        private enum DecodingKeys: String, CodingKey {
            case id, media_id, title, images, num_pages, tags
            case english_title, japanese_title, tag_ids
            case pages, cover, thumbnail
        }

        private enum EncodingKeys: String, CodingKey {
            case id, media_id, title, images, num_pages, tags, thumbnailPath
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: EncodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(media_id, forKey: .media_id)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(images, forKey: .images)
            try c.encode(num_pages, forKey: .num_pages)
            try c.encodeIfPresent(tags, forKey: .tags)
            try c.encodeIfPresent(thumbnailPath, forKey: .thumbnailPath)
        }

        // 手動init
        init(id: Int, media_id: String, title: NhTitle, images: NhImages?, num_pages: Int, tags: [NhTag]?, thumbnailPath: String? = nil) {
            self.id = id; self.media_id = media_id; self.title = title
            self.images = images; self.num_pages = num_pages; self.tags = tags
            self.thumbnailPath = thumbnailPath
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
        let t: String  // j=jpg, p=png, g=gif, w=webp
        let w: Int
        let h: Int
        let path: String?      // v2: "galleries/XXXX/1.webp"
        let thumbPath: String?  // v2: "galleries/XXXX/1t.webp"

        var ext: String {
            // v2: pathから拡張子を取得
            if let path, let lastDot = path.lastIndex(of: ".") {
                return String(path[path.index(after: lastDot)...])
            }
            switch t {
            case "j": return "jpg"
            case "p": return "png"
            case "g": return "gif"
            case "w": return "webp"
            default: return "jpg"
            }
        }

        // v1 + v2 両対応デコーダー
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // v2: path, width, height, thumbnail
            path = try c.decodeIfPresent(String.self, forKey: .path)
            thumbPath = try c.decodeIfPresent(String.self, forKey: .thumbnail)
            if let width = try? c.decode(Int.self, forKey: .width) {
                w = width
                h = (try? c.decode(Int.self, forKey: .height)) ?? 0
                // pathから拡張子コードを推定
                if let p = path, p.hasSuffix(".webp") { t = "w" }
                else if let p = path, p.hasSuffix(".png") { t = "p" }
                else if let p = path, p.hasSuffix(".gif") { t = "g" }
                else { t = "j" }
            } else {
                // v1: t, w, h（thumbPathはv2のみ）
                t = (try? c.decode(String.self, forKey: .t)) ?? "j"
                w = (try? c.decode(Int.self, forKey: .w)) ?? 0
                h = (try? c.decode(Int.self, forKey: .h)) ?? 0
                if thumbPath == nil {
                    // v1にはthumbnailフィールドがないのでnilのまま
                }
            }
        }

        init(t: String, w: Int, h: Int, path: String? = nil, thumbPath: String? = nil) {
            self.t = t; self.w = w; self.h = h; self.path = path; self.thumbPath = thumbPath
        }

        private enum CodingKeys: String, CodingKey {
            case t, w, h, path, width, height, thumbnail, thumbPath
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(t, forKey: .t)
            try c.encode(w, forKey: .w)
            try c.encode(h, forKey: .h)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(thumbPath, forKey: .thumbPath)
        }
    }

    struct NhTag: Codable, Sendable {
        let id: Int
        let type: String
        let name: String
        let url: String?
        let count: Int?
        let slug: String?
    }

    struct NhSearchResult: Codable, Sendable {
        let result: [NhGallery]
        let num_pages: Int
        let per_page: Int
        let total: Int?

        init(result: [NhGallery], num_pages: Int, per_page: Int, total: Int? = nil) {
            self.result = result; self.num_pages = num_pages; self.per_page = per_page; self.total = total
        }
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

    /// ギャラリー情報取得（v2 API）
    static func fetchGallery(id: Int) async throws -> NhGallery {
        let urlStr = "https://nhentai.net/api/v2/galleries/\(id)"
        let data = try await NhentaiWebBridge.shared.fetch(url: urlStr)
        return try JSONDecoder().decode(NhGallery.self, from: data)
    }

    /// タイトル検索（v2 API）
    /// sort: nil=date, "popular", "popular-today", "popular-week", "popular-month"
    static func search(query: String, page: Int = 1, sort: String? = nil) async throws -> NhSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var urlString: String
        var clientFilter: String? = nil

        if trimmed.isEmpty && (sort == nil || sort?.isEmpty == true) {
            // 空クエリ＆ソートなし → 全件API（新着順）
            urlString = "https://nhentai.net/api/v2/galleries?page=\(page)"
        } else if !trimmed.isEmpty {
            var searchQuery = trimmed
            if !searchQuery.contains(":") && !searchQuery.hasPrefix("\"") {
                searchQuery = "\"\(searchQuery)\""
                clientFilter = trimmed.lowercased()
            }
            let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
            urlString = "https://nhentai.net/api/v2/search?query=\(encoded)&page=\(page)"
        } else {
            // 空クエリだがソートあり
            urlString = "https://nhentai.net/api/v2/galleries?page=\(page)"
        }

        if let sort, !sort.isEmpty {
            let sortValue = sort == "popular" ? "popular" : sort
            urlString += "&sort=\(sortValue)"
        }

        LogManager.shared.log("nhentai", "API: \(urlString)")
        let data = try await NhentaiWebBridge.shared.fetch(url: urlString)
        LogManager.shared.log("nhentai", "response: size=\(data.count)")
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

    /// ページ画像URL（v2 path対応）
    static func imageURL(mediaId: String, page: Int, ext: String, path: String? = nil) -> URL {
        if let path {
            return URL(string: "https://i.nhentai.net/\(path)")!
        }
        return URL(string: "https://i.nhentai.net/galleries/\(mediaId)/\(page).\(ext)")!
    }

    /// サムネURL（v2 thumbnail path対応）
    static func thumbURL(mediaId: String, page: Int, ext: String, path: String? = nil) -> URL {
        if let path {
            return URL(string: "https://t.nhentai.net/\(path)")!
        }
        return URL(string: "https://t.nhentai.net/galleries/\(mediaId)/\(page)t.\(ext)")!
    }

    /// カバーURL（v2 path対応）
    static func coverURL(mediaId: String, ext: String, path: String? = nil) -> URL {
        if let path {
            return URL(string: "https://t.nhentai.net/\(path)")!
        }
        return URL(string: "https://t.nhentai.net/galleries/\(mediaId)/cover.\(ext)")!
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
    static func fetchPageImage(galleryId: Int, mediaId: String, page: Int, ext: String, path: String? = nil) async throws -> Data {
        // 0. v2 path直接アクセス
        if let path {
            for cdn in fallbackImageCDNs {
                let url = URL(string: "https://\(cdn).nhentai.net/\(path)")!
                if let result = await fetchRawImage(url: url),
                   result.status == 200 && !result.data.isEmpty && !isHTMLResponse(result.data) {
                    return result.data
                }
            }
        }

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

    /// カバー画像取得（v2 path対応 + 拡張子フォールバック）
    static func fetchCoverImage(galleryId: Int, mediaId: String, ext: String, path: String? = nil) async throws -> Data {
        // v2: pathが指定されていればそれを使う
        if let path {
            for cdn in fallbackThumbCDNs {
                let url = URL(string: "https://\(cdn).nhentai.net/\(path)")!
                if let result = await fetchLightImage(url: url),
                   result.status == 200 && !result.data.isEmpty && !isHTMLResponse(result.data) {
                    return result.data
                }
            }
        }

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

    /// サムネ画像取得（v2 path対応 + 拡張子フォールバック）
    static func fetchThumbImage(mediaId: String, page: Int, ext: String, path: String? = nil) async throws -> Data {
        // v2: thumbPathが指定されていればそれを使う
        if let path {
            for cdn in fallbackThumbCDNs {
                let url = URL(string: "https://\(cdn).nhentai.net/\(path)")!
                if let result = await fetchLightImage(url: url),
                   result.status == 200 && !result.data.isEmpty && !isHTMLResponse(result.data) {
                    return result.data
                }
            }
        }

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

    /// お気に入り登録/解除トグル（WKWebViewでギャラリーページのfavoriteボタンをJSクリック）
    static func toggleFavorite(galleryId: Int) async throws -> Bool {
        let result = try await NhentaiWebBridge.shared.toggleFavoriteViaPage(galleryId: galleryId)
        LogManager.shared.log("nhentai", "toggleFavorite id=\(galleryId) result=\(result)")
        return result
    }

    /// お気に入り1ページ取得（HTML解析）→ (galleries, hasNextPage)
    static func fetchFavoritesPage(page: Int) async throws -> (galleries: [NhGallery], hasNext: Bool) {
        guard NhentaiCookieManager.isLoggedIn() else {
            LogManager.shared.log("nhFav", "not logged in, skipping")
            return ([], false)
        }

        LogManager.shared.log("nhFav", "fetching page \(page)...")
        let urlStr = "https://nhentai.net/api/v2/favorites?page=\(page)"

        do {
            let data = try await NhentaiWebBridge.shared.fetch(url: urlStr)
            let decoded = try JSONDecoder().decode(NhSearchResult.self, from: data)
            let hasNext = page < decoded.num_pages
            LogManager.shared.log("nhFav", "page \(page): \(decoded.result.count) items, hasNext=\(hasNext)")
            return (decoded.result, hasNext)
        } catch {
            LogManager.shared.log("nhFav", "v2 API failed: \(error.localizedDescription), falling back to HTML")
        }

        // フォールバック: HTML解析
        let htmlUrlStr = "https://nhentai.net/favorites/?page=\(page)"
        let (html, status) = try await NhentaiWebBridge.shared.fetchHTML(url: htmlUrlStr)

        guard !html.isEmpty else {
            LogManager.shared.log("nhFav", "page \(page): empty HTML")
            return ([], false)
        }

        LogManager.shared.log("nhFav", "page \(page): status=\(status) html=\(html.count) chars")

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

        let hasNext = html.contains("page=\(page + 1)") || html.contains("class=\"next\"")

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
