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
        // nonisolated init から @Published isEnabled は読めないため永続値スナップショットを読む (A2-c)
        thumbConfig.httpMaximumConnectionsPerHost = SafetyMode.shared.isEnabledSnapshot ? 6 : 20
        thumbConfig.requestCachePolicy = .returnCacheDataElseLoad
        self.thumbSession = URLSession(configuration: thumbConfig)
    }

    // MARK: - Gallery List

    nonisolated func fetchGalleryList(host: GalleryHost, page: Int = 0, searchQuery: String? = nil, categoryFilter: Int? = nil, minRating: Int? = nil) async throws -> (galleries: [Gallery], pageNumber: PageNumber) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var urlString = host.baseURL + "/"
        var queryItems: [String] = []

        if let query = searchQuery, !query.isEmpty {
            queryItems.append("f_search=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")
        }
        if let cats = categoryFilter {
            queryItems.append("f_cats=\(cats)")
        }
        // 最低評価フィルタ (N★以上のみ)。E-H 公式: f_sr=on で有効化, f_srdd=2..5。
        if let r = minRating, (2...5).contains(r) {
            queryItems.append("f_sr=on")
            queryItems.append("f_srdd=\(r)")
        }
        if !queryItems.isEmpty {
            urlString += "?" + queryItems.joined(separator: "&")
        }

        LogManager.shared.log("Search", "fetchGalleryList host=\(host) URL: \(urlString)")

        // 検索系の共通フォールバック経由で取得 (exhentai 空 → e-hentai)
        let (galleries, pageNumber) = try await fetchListWithExhentaiFallback(urlString: urlString, host: host)

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
        LogManager.shared.log("Search", "fetchByURL host=\(host) URL: \(urlString)")
        // 検索結果のページ送りも同じ exhentai→e-hentai フォールバックを通す
        let (galleries, pageNumber) = try await fetchListWithExhentaiFallback(urlString: urlString, host: host)
        LogManager.shared.log("Search", "  fetchByURL \(galleries.count)件 hasNext=\(pageNumber.hasNext)")
        return (galleries, pageNumber)
    }

    /// 検索系の共通フォールバック。exhentai が結果を出せない場合 (200+0B / 未認証 /
    /// SadPanda / Cloudflare 等) は、同一 URL のホストだけ e-hentai (public) に差し替えて
    /// 再取得する。検索はログイン不要なので exhentai のログイン状態に関係なく結果を必ず出す保険。
    /// 田中報告 2026-06-22 (bundle id を com.kanayayuutou.cortexapp に変更後、exhentai が
    /// 200+0B body を返すようになった。原因未確定で今は追わない)。
    ///
    /// 重要: exhentai の 200+0B body は fetchHTML 内で trimmed.isEmpty 判定により
    /// EhError.notLoggedIn を throw する (空配列を返すのではない)。よって「空配列なら
    /// フォールバック」だけでは発火しない。throw 経路もここで捕捉して e-hentai へ回す。
    /// fetchGalleryList / fetchByURL の両検索経路から共有する。
    nonisolated private func fetchListWithExhentaiFallback(urlString: String, host: GalleryHost) async throws -> (galleries: [Gallery], pageNumber: PageNumber) {
        // exhentai 以外 (e-hentai 直) はそのまま取得
        guard host == .exhentai else {
            let html = try await fetchHTML(urlString: urlString, host: host)
            return (HTMLParser.parseGalleryList(html: html), HTMLParser.parsePageNumber(html: html))
        }

        // exhentai: まず通常取得を試みる。0件 or throw (200+0B / notLoggedIn / parseFailed 等) なら
        // e-hentai にフォールバック。検索 cancel だけは尊重して rethrow する。
        do {
            let html = try await fetchHTML(urlString: urlString, host: .exhentai)
            let galleries = HTMLParser.parseGalleryList(html: html)
            if !galleries.isEmpty {
                return (galleries, HTMLParser.parsePageNumber(html: html))
            }
            LogManager.shared.log("Search", "exhentai 200+\(html.count)B だが 0件 → e-hentai フォールバック")
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw e
        } catch {
            LogManager.shared.log("Search", "exhentai 取得失敗(\(error)) → e-hentai フォールバック")
        }

        // フォールバック: URL のホストだけ e-hentai に差し替えて再取得
        let ehURL = urlString.replacingOccurrences(
            of: GalleryHost.exhentai.rawValue,
            with: GalleryHost.ehentai.rawValue
        )
        let ehHtml = try await fetchHTML(urlString: ehURL, host: .ehentai)
        let ehGalleries = HTMLParser.parseGalleryList(html: ehHtml)
        LogManager.shared.log("Search", "  e-hentai フォールバック \(ehGalleries.count)件 (\(ehHtml.count)B) URL: \(ehURL)")
        return (ehGalleries, HTMLParser.parsePageNumber(html: ehHtml))
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
        // 画像ページ HTML 取得時に uh=1280/iir=3 を含めると、server が HTML 内に
        // resampled image URL を埋め込み、後の fetchImageData が static にダウンサンプル
        // された data を取得してしまう。専用 fetch で Cookie から uh/iir を外す
        // (田中報告 2026-04-25「DLなら動画/Readerはstatic」根因、DL も同じ fetchImageURL を使うが
        // 今回 forImageFetch=true 通すことで両経路とも Original 配信に揃える)。
        let html = try await fetchHTMLForImagePage(urlString: pageURL.absoluteString, host: host)
        if let url = HTMLParser.parseFullImageURL(html: html) {
            return url
        }
        throw EhError.parseFailed
    }

    /// 画像ページ HTML 専用 fetch (Cookie から uh/iir 削除で Original 配信を狙う)。
    /// `fetchHTMLViaBGOrFallback` の BG/FG 切替・retry は省略 (foreground 想定の reader/DL 経路用)。
    nonisolated private func fetchHTMLForImagePage(urlString: String, host: GalleryHost) async throws -> String {
        guard let url = URL(string: urlString) else { throw EhError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host, forImageFetch: true), forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw EhError.parseFailed
        }
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw EhError.parseFailed
        }
        return html
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
            let isBackgrounded = await MainActor.run { UIApplication.shared.applicationState != .active }
            // BG 中は FG session の fetchHTML が empty body になりがちなので、
            // 最初から BG session 経由 (htmlFetchSession) で HTML を取得する
            if isBackgrounded {
                if let url = URL(string: urlString),
                   let html = await BackgroundDownloadManager.shared.fetchHTMLViaBG(
                    url: url,
                    session: BackgroundDownloadManager.shared.htmlFetchSession,
                    headers: [
                        "User-Agent": Self.userAgent,
                        "Cookie": Self.buildCookieHeader(for: host)
                    ]
                   ),
                   !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return html
                }
                // BG session も失敗: foreground 復帰を最大 300 秒待つ
                bgWaitCycles += 1
                if bgWaitCycles > maxBgWaitCycles { break }
                LogManager.shared.log("Download", "fetchHTML BG fetch failed (cycle \(bgWaitCycles)/\(maxBgWaitCycles)), waiting foreground url=\(urlString.suffix(60))")
                var waited = 0
                while waited < 300 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waited += 1
                    let nowActive = await MainActor.run { UIApplication.shared.applicationState == .active }
                    if nowActive { break }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
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
                if fgRetries >= maxFgRetries { break }
                let backoffMs: UInt64 = UInt64(500 * (1 << fgRetries))
                LogManager.shared.log("Download", "fetchHTML retry \(fgRetries+1)/\(maxFgRetries) after \(backoffMs)ms (err=\(error)) url=\(urlString.suffix(60))")
                try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
                fgRetries += 1
            }
        }
        throw lastError
    }

    /// 画像データをcookie付きでダウンロード（AsyncImageの代わりに使用）
    /// onProgress 指定時のみ DL 進捗 (0...1) を報告 (大容量の標準画質/WebP をリーダーで
    /// バー表示するため、田中要望 2026-06-09)。nil の通常経路 (prefetch/サムネ等) は従来の
    /// session.data(for:) のまま = バイト単位の挙動不変。
    nonisolated func fetchImageData(url: URL, host: GalleryHost, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        let t0 = CFAbsoluteTimeGetCurrent()
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // forImageFetch=true: uh=1280/iir=3 を含めない → Original 配信 (動画 WebP も原本のまま)
        request.setValue(Self.buildCookieHeader(for: host, forImageFetch: true), forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        if let onProgress {
            (data, response) = try await Self.dataWithProgress(session: session, request: request, onProgress: onProgress)
        } else {
            (data, response) = try await session.data(for: request)
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw EhError.parseFailed
        }
        guard !data.isEmpty else {
            throw EhError.parseFailed
        }
        LogManager.shared.log("Perf", "fetchImageData: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms \(data.count)B \(url.lastPathComponent)")
        return data
    }

    /// URLSessionTask.progress (Content-Length 既知時に fractionCompleted が進む) を KVO で
    /// 観測してチャンク粒度の進捗を報告。バイト逐次反復より高速。Content-Length 不明なら
    /// fractionCompleted は 0 のまま → 呼び出し側はバー非表示 (スピナー fallback) にする。
    private static func dataWithProgress(session: URLSession, request: URLRequest, onProgress: @escaping @Sendable (Double) -> Void) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
            var obs: NSKeyValueObservation?
            let task = session.dataTask(with: request) { data, response, error in
                obs?.invalidate(); obs = nil
                if let error {
                    cont.resume(throwing: error)
                } else if let data, let response {
                    cont.resume(returning: (data, response))
                } else {
                    cont.resume(throwing: EhError.parseFailed)
                }
            }
            // 2026-06-10: KVO はチャンク毎 (1 DL あたり毎秒数十回 × 並列 20) に発火し、その都度
            // onProgress → main ホップ + holder 再描画が走りスクロールを荒らした → 2% 刻みに間引く。
            let throttle = ProgressReportThrottle()
            obs = task.progress.observe(\.fractionCompleted) { prog, _ in
                let f = prog.fractionCompleted
                if throttle.shouldReport(f) { onProgress(f) }
            }
            task.resume()
        }
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

    /// Keychainから直接cookieヘッダを組み立てる（HTTPCookieStorageに依存しない）。
    /// `forImageFetch=true` は画像取得 (`fetchImageData`) 専用で、`uh`/`iir` の resample 指示
    /// を含めない。`uh=1280; iir=3` を付けると E-Hentai が動画 WebP を 1 frame static に
    /// ダウンサンプリングして配信し、通常リーダーで動画として認識できなくなる
    /// (田中報告 2026-04-25「DL すれば動画になるのに通常リーダーで static 扱い」根因、
    /// DL 経路は Cookie 無しなので Original 動画 WebP が降ってくる)。
    nonisolated private static func buildCookieHeader(for host: GalleryHost, forImageFetch: Bool = false) -> String {
        var parts: [String] = []
        let memberID = KeychainService.load(key: "ipb_member_id")
        let passHash = KeychainService.load(key: "ipb_pass_hash")
        let igneous = KeychainService.load(key: "igneous")
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
        // HTML fetch 等は uh=1280 で安定 (GP 消費抑制)、画像取得は無指定で Original 配信を狙う
        if !forImageFetch {
            parts.append("uh=1280")
            parts.append("iir=3")  // 3=1280 in EH inline image resolution table
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - Networking

    /// exhentai は igneous が stale になると 200+0B (or sad panda image / 302) を返す。
    /// その時 fetchHTMLOnce が notLoggedIn を throw するので、1 回だけ igneous を自動 refresh
    /// (member/pass は有効なので再ログイン不要) して retry する。
    /// 田中報告 2026-06-22: bundle id 変更後 exhentai ログイン不可。真因は stale igneous +
    /// アプリが Set-Cookie の新 igneous を破棄していたこと (cookie storage 無効化のため)。
    /// 実測 (cookie 受理 jar で e-hentai→exhentai bounce) で新 igneous 取得 → exhentai が
    /// 63829B 本文を返すことを確認済。refresh は同手順を URLSession で再現する。
    nonisolated func fetchHTML(urlString: String, host: GalleryHost) async throws -> String {
        do {
            return try await fetchHTMLOnce(urlString: urlString, host: host)
        } catch EhError.notLoggedIn where host == .exhentai {
            LogManager.shared.log("EhAuth", "exhentai notLoggedIn → igneous 自動 refresh 試行")
            let refreshed = await Self.igneousRefresher.refresh {
                await self.performIgneousRefresh()
            }
            guard refreshed else {
                LogManager.shared.log("EhAuth", "igneous refresh 失敗 → notLoggedIn 継続")
                throw EhError.notLoggedIn
            }
            LogManager.shared.log("EhAuth", "igneous refresh 成功 → 1 回だけ retry")
            return try await fetchHTMLOnce(urlString: urlString, host: host)
        }
    }

    /// 単発の HTML 取得 (refresh / retry なし)。
    nonisolated private func fetchHTMLOnce(urlString: String, host: GalleryHost) async throws -> String {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let url = URL(string: urlString) else {
            throw EhError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.buildCookieHeader(for: host), forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0
        LogManager.shared.log("Perf", "fetchHTML: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms status=\(statusCode) \(data.count)B \(urlString.suffix(60))")

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

        // 非 2xx (404/500 等) の素通し防止: 旧実装はそのまま html を返し、
        // パーサが silent に空配列を返して「0件」表示になっていた。
        // 503/429 (ban) と exhentai の 302/403 (SadPanda) は上で個別処理済み。
        if !(200...299).contains(statusCode) {
            LogManager.shared.log("EhClient", "fetchHTML http \(statusCode) → throw parseFailed \(urlString.suffix(60))")
            throw EhError.parseFailed
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

    // MARK: - igneous 自動 refresh

    /// stale な exhentai igneous を自動更新する単一フライト coordinator。
    /// 並行リクエストが同時に notLoggedIn を踏んでも refresh は 1 本にまとめる。
    static let igneousRefresher = IgneousRefresher()

    /// 有効な member/pass を cookie 受理 jar に種付けし、e-hentai→exhentai を辿って
    /// exhentai が Set-Cookie で発行する real igneous を回収・Keychain 保存する。
    /// 成功 (real igneous 保存) で true。再ログイン不要 (member/pass は既に有効)。
    nonisolated private func performIgneousRefresh() async -> Bool {
        guard let memberID = KeychainService.load(key: "ipb_member_id"),
              let passHash = KeychainService.load(key: "ipb_pass_hash"),
              !memberID.isEmpty, !passHash.isEmpty else {
            LogManager.shared.log("EhAuth", "refresh: member/pass 無し → 中止 (要ログイン)")
            return false
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        let store = cfg.httpCookieStorage ?? HTTPCookieStorage.shared
        for domain in [".e-hentai.org", ".exhentai.org"] {
            for (n, v) in [("ipb_member_id", memberID), ("ipb_pass_hash", passHash)] {
                if let c = HTTPCookie(properties: [.domain: domain, .path: "/", .name: n, .value: v, .secure: "TRUE"]) {
                    store.setCookie(c)
                }
            }
        }
        let refreshSession = URLSession(configuration: cfg)
        func get(_ urlStr: String) async {
            guard let url = URL(string: urlStr) else { return }
            var req = URLRequest(url: url)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            _ = try? await refreshSession.data(for: req)
        }
        // 実測で確認した正規 bounce: e-hentai でセッション確立 → exhentai で igneous 発行。
        await get("https://e-hentai.org/")
        await get("https://exhentai.org/")
        guard let exURL = URL(string: "https://exhentai.org/"),
              let ig = store.cookies(for: exURL)?.first(where: { $0.name == "igneous" })?.value,
              !ig.isEmpty, ig != "mystery" else {
            LogManager.shared.log("EhAuth", "refresh: real igneous 取れず (mystery/無し)")
            return false
        }
        KeychainService.save(key: "igneous", value: ig)
        LogManager.shared.log("EhAuth", "refresh: 新 igneous 保存 (len=\(ig.count))")
        return true
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

/// DL 進捗報告の間引き (2026-06-10)。KVO のチャンク毎発火をそのまま main へ流すと
/// 並列 DL 中に毎秒数百回の main ホップ + SwiftUI 再描画が発生しスクロールが荒れるため、
/// 2% 以上進んだ時と完了時のみ報告する。E-H / nhentai 両クライアントで共用。
nonisolated final class ProgressReportThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1

    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fraction >= 1.0 || fraction - last >= 0.02 else { return false }
        last = fraction
        return true
    }
}

/// exhentai igneous の自動 refresh を単一フライト化 + スロットルする coordinator。
/// 並列リクエスト (一覧 / サムネ / 画像) が同時に stale igneous を踏んでも、
/// refresh bounce は 1 本だけ走らせ、他は同じ結果を待つ (thundering herd 防止)。
actor IgneousRefresher {
    private var inFlight: Task<Bool, Never>?
    private var lastSuccess: CFAbsoluteTime = 0

    /// 直近 30s 以内に成功済みなら即 true (Keychain に新 igneous 反映済とみなす)。
    /// in-flight があれば相乗り、無ければ op を 1 本起動する。
    func refresh(_ op: @escaping @Sendable () async -> Bool) async -> Bool {
        if lastSuccess > 0, CFAbsoluteTimeGetCurrent() - lastSuccess < 30 {
            return true
        }
        if let t = inFlight {
            return await t.value
        }
        let task = Task { await op() }
        inFlight = task
        let ok = await task.value
        inFlight = nil
        if ok { lastSuccess = CFAbsoluteTimeGetCurrent() }
        return ok
    }
}
