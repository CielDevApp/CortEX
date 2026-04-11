import Foundation

enum HTMLParser: Sendable {

    // MARK: - Gallery List Parsing

    nonisolated static func parseGalleryList(html: String) -> [Gallery] {
        var galleries: [Gallery] = []

        let trBlocks = matchAll(html, pattern: #"<tr[^>]*>[\s\S]*?</tr>"#)
        for trBlock in trBlocks {
            if let gallery = parseGalleryRow(trBlock) {
                galleries.append(gallery)
            }
        }

        // Fallback: thumbnail mode
        if galleries.isEmpty {
            let thumbBlocks = matchAll(html, pattern: #"<div class="gl1t"[\s\S]*?(?=<div class="gl1t"|$)"#)
            for block in thumbBlocks {
                if let gallery = parseGalleryThumb(block) {
                    galleries.append(gallery)
                }
            }
        }

        return galleries
    }

    nonisolated private static func parseGalleryRow(_ html: String) -> Gallery? {
        guard let urlMatch = firstMatch(html, pattern: #"href="https?://[^/]+/g/(\d+)/([a-f0-9]+)/"#),
              urlMatch.count >= 3,
              let gid = Int(urlMatch[1]) else {
            return nil
        }
        let token = urlMatch[2]

        let title = extractText(from: html, className: "glink")
            ?? firstMatch(html, pattern: #"class="glink"[^>]*>([^<]+)<"#).flatMap { $0.count >= 2 ? $0[1] : nil }
            ?? "Unknown"

        let coverURL = extractCoverURL(from: html)
        let category = extractCategory(from: html)
        let rating = extractRating(from: html)
        let pageCount = firstMatch(html, pattern: #"(\d+)\s*page"#).flatMap { $0.count >= 2 ? Int($0[1]) : nil } ?? 0
        let postedDate = firstMatch(html, pattern: #"(\d{4}-\d{2}-\d{2}\s*\d{2}:\d{2})"#).flatMap { $0.count >= 2 ? $0[1] : nil } ?? ""
        let uploader = firstMatch(html, pattern: #"href="[^"]*uploader[^"]*"[^>]*>([^<]+)<"#)
            .flatMap { $0.count >= 2 ? $0[1] : nil }

        let tagMatches = matchAll(html, pattern: #"title="([^"]+)"[^>]*class="gt[l]?"#)
            + matchAll(html, pattern: #"class="gt[l]?"[^>]*title="([^"]+)""#)
        let tags = tagMatches.compactMap { match -> String? in
            guard let titleMatch = firstMatch(match, pattern: #"title="([^"]+)""#), titleMatch.count >= 2 else { return nil }
            return titleMatch[1]
        }

        return Gallery(
            gid: gid, token: token,
            title: decodeHTMLEntities(title),
            category: category, coverURL: coverURL,
            rating: rating, pageCount: pageCount,
            postedDate: postedDate, uploader: uploader,
            tags: tags
        )
    }

    nonisolated private static func parseGalleryThumb(_ html: String) -> Gallery? {
        guard let urlMatch = firstMatch(html, pattern: #"href="https?://[^/]+/g/(\d+)/([a-f0-9]+)/"#),
              urlMatch.count >= 3,
              let gid = Int(urlMatch[1]) else {
            return nil
        }
        let token = urlMatch[2]
        let title = extractText(from: html, className: "glink") ?? "Unknown"
        let coverURL = extractCoverURL(from: html)
        let category = extractCategory(from: html)

        return Gallery(
            gid: gid, token: token,
            title: decodeHTMLEntities(title),
            category: category, coverURL: coverURL,
            rating: 0, pageCount: 0,
            postedDate: "", uploader: nil,
            tags: []
        )
    }

    // MARK: - Gallery Detail Parsing

    nonisolated static func parseGalleryDetail(html: String, gallery: Gallery) -> GalleryDetail {
        let t0 = CFAbsoluteTimeGetCurrent()
        let enTitle = firstMatch(html, pattern: #"<h1 id="gn">([^<]+)</h1>"#)
            .flatMap { $0.count >= 2 ? decodeHTMLEntities($0[1]) : nil }

        let jpnTitle = firstMatch(html, pattern: #"<h1 id="gj">([^<]+)</h1>"#)
            .flatMap { $0.count >= 2 ? decodeHTMLEntities($0[1]) : nil }

        let coverURL = firstMatch(html, pattern: #"id="gd1"[\s\S]*?url\(([^)]+)\)"#)
            .flatMap { $0.count >= 2 ? URL(string: $0[1]) : nil }
            ?? gallery.coverURL

        let categoryText = firstMatch(html, pattern: #"<div id="gdc"[\s\S]*?>[\s\S]*?<[^>]+>([^<]+)<"#)
            .flatMap { $0.count >= 2 ? $0[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        let category = categoryText.flatMap { GalleryCategory(rawValue: $0) } ?? gallery.category

        let uploader = firstMatch(html, pattern: #"<div id="gdn"[\s\S]*?<a[^>]*>([^<]+)</a>"#)
            .flatMap { $0.count >= 2 ? decodeHTMLEntities($0[1]) : nil }
            ?? gallery.uploader

        // 言語: "Japanese  TR" → "Japanese" のように不要なフラグを除去
        let rawLanguage = extractInfoValue(html, label: "Language")
        let language = rawLanguage.flatMap { raw -> String? in
            let cleaned = raw.components(separatedBy: .whitespaces).first { !$0.isEmpty }
            return cleaned
        }
        let fileSize = extractInfoValue(html, label: "File Size")
        let pageCountStr = extractInfoValue(html, label: "Length")
        let pageCount = pageCountStr.flatMap { str -> Int? in
            firstMatch(str, pattern: #"(\d+)"#).flatMap { $0.count >= 2 ? Int($0[1]) : nil }
        } ?? gallery.pageCount

        let favoritedStr = extractInfoValue(html, label: "Favorited")
        let favoritedCount = favoritedStr.flatMap { str -> Int? in
            firstMatch(str, pattern: #"(\d+)"#).flatMap { $0.count >= 2 ? Int($0[1]) : nil }
        }

        let ratingText = firstMatch(html, pattern: #"id="rating_label"[^>]*>([^<]+)<"#)
            .flatMap { $0.count >= 2 ? $0[1] : nil }
        let rating: Double
        if let ratingText, let r = Double(ratingText.replacingOccurrences(of: "Average: ", with: "").trimmingCharacters(in: .whitespaces)) {
            rating = r
        } else {
            rating = gallery.rating
        }

        let postedDate = extractInfoValue(html, label: "Posted") ?? gallery.postedDate

        let isFavorited: Bool
        if let favText = firstMatch(html, pattern: #"id="favoritelink"[^>]*>([^<]+)<"#).flatMap({ $0.count >= 2 ? $0[1] : nil }) {
            isFavorited = !favText.contains("Add to Favorites")
        } else {
            isFavorited = false
        }

        // Tags
        // 実際のHTML構造:
        // <div id="taglist"><table>
        //   <tr><td class="tc">parody:</td><td>
        //     <div id="td_parody:the_idolmaster" class="gtl"><a ...>the idolmaster</a></div>
        //   </td></tr>
        // </table></div>
        var normalizedTags: [String: [String]] = [:]

        // id="td_{namespace}:{tag_name}" の形式で全タグを抽出
        let tagDivs = matchAll(html, pattern: #"id="td_([^:]+):([^"]+)"[^>]*class="gt[^"]*"[^>]*>[\s\S]*?</div>"#)
        for block in tagDivs {
            if let m = firstMatch(block, pattern: #"id="td_([^:]+):([^"]+)""#), m.count >= 3 {
                let ns = m[1]
                // タグ名は <a> の中身から取得。なければid属性から復元
                let tagName: String
                if let aMatch = firstMatch(block, pattern: #"<a[^>]*>([^<]+)</a>"#), aMatch.count >= 2 {
                    tagName = aMatch[1]
                } else {
                    tagName = m[2].replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "+", with: " ")
                }
                normalizedTags[ns, default: []].append(tagName)
            }
        }

        let previewURLs = matchAll(html, pattern: #"<div id="gdt"[\s\S]*?</div>\s*</div>"#)
            .flatMap { block -> [URL] in
                matchAll(block, pattern: #"<a href="([^"]+)"#)
                    .compactMap { link -> URL? in
                        guard let m = firstMatch(link, pattern: #"href="([^"]+)""#), m.count >= 2 else { return nil }
                        return URL(string: m[1])
                    }
            }

        var updatedGallery = gallery
        updatedGallery.title = enTitle ?? gallery.title
        updatedGallery.category = category
        updatedGallery.coverURL = coverURL
        updatedGallery.rating = rating
        updatedGallery.pageCount = pageCount
        updatedGallery.postedDate = postedDate
        updatedGallery.uploader = uploader

        let comments = parseComments(html: html)
        LogManager.shared.log("Perf", "parseGalleryDetail: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms html=\(html.count) tags=\(normalizedTags.count) comments=\(comments.count)")

        return GalleryDetail(
            gallery: updatedGallery,
            jpnTitle: jpnTitle,
            language: language,
            fileSize: fileSize,
            favoritedCount: favoritedCount,
            isFavorited: isFavorited,
            previewURLs: [],
            thumbnailPageURLs: previewURLs,
            normalizedTags: normalizedTags,
            comments: comments
        )
    }

    // MARK: - Comment Parsing

    /// E-Hentaiのコメントを解析
    /// HTML構造: div#cdiv > div.c1 > div.c3(投稿者/日時) + div.c5(スコア) + div.c6(本文)
    nonisolated static func parseComments(html: String) -> [GalleryComment] {
        var comments: [GalleryComment] = []

        guard let cdivMatch = firstMatch(html, pattern: #"id="cdiv"[^>]*>([\s\S]*)"#),
              cdivMatch.count >= 2 else { return [] }
        let cdiv = cdivMatch[1]

        let c1Blocks = matchAll(cdiv, pattern: #"<div class="c1"[\s\S]*?(?=<div class="c1"|<div class="c7"|$)"#)

        for block in c1Blocks {
            // c3: "Posted on DD MMMM YYYY, HH:MM by:   Author"
            guard let c3Match = firstMatch(block, pattern: #"<div class="c3">([\s\S]*?)</div>"#),
                  c3Match.count >= 2 else { continue }
            let c3 = c3Match[1].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

            var author = ""
            var dateStr = ""
            if let byRange = c3.range(of: " by:") {
                let beforeBy = c3[c3.startIndex..<byRange.lowerBound]
                author = String(c3[byRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let postedRange = beforeBy.range(of: "Posted on ") {
                    dateStr = String(beforeBy[postedRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // c5: スコア
            let score = firstMatch(block, pattern: #"<div class="c5[^"]*"[^>]*>[\s\S]*?<span[^>]*>([^<]+)</span>"#)
                .flatMap { $0.count >= 2 ? $0[1] : nil }

            // c6: 本文（HTMLタグ除去）
            var content = ""
            if let c6Match = firstMatch(block, pattern: #"<div class="c6"[^>]*>([\s\S]*?)</div>"#),
               c6Match.count >= 2 {
                content = c6Match[1]
                    .replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                content = decodeHTMLEntities(content) ?? content
            }

            guard !author.isEmpty, !content.isEmpty else { continue }

            comments.append(GalleryComment(
                author: author,
                date: dateStr,
                score: score,
                content: content
            ))
        }

        return comments
    }

    // MARK: - Image URL Parsing

    nonisolated static func parseImagePageURLs(html: String) -> [URL] {
        // gdtセクション: id="gdt" から次の主要セクションまで
        let gdtBlock: String
        if let m = firstMatch(html, pattern: #"id="gdt"[\s\S]*?>([\s\S]*?)(?:<div class="c"|<table class="ptt")"#), m.count >= 2 {
            gdtBlock = m[1]
        } else {
            gdtBlock = html
        }

        return matchAll(gdtBlock, pattern: #"href="(https?://[^"]+/s/[^"]+)""#)
            .compactMap { link -> URL? in
                guard let m = firstMatch(link, pattern: #"href="([^"]+)""#), m.count >= 2 else { return nil }
                return URL(string: m[1])
            }
    }

    /// ギャラリーページからサムネイル情報を抽出する
    ///
    /// 実際のHTML構造 (gt200モード):
    /// ```
    /// <div id="gdt" class="gt200">
    ///   <a href="https://e-hentai.org/s/xxx/123-1">
    ///     <div title="Page 1: ..." style="width:200px;height:200px;background:transparent url(SPRITE_URL) -0px 0 no-repeat"></div>
    ///   </a>
    ///   ...
    /// </div>
    /// ```
    /// サムネイルはスプライトシート（1画像に複数サムネが横並び）
    nonisolated static func parseThumbnailInfos(html: String) -> [ThumbnailInfo] {
        var results: [ThumbnailInfo] = []

        // gdt セクションを抽出
        guard let gdtMatch = firstMatch(html, pattern: #"id="gdt"[\s\S]*?>([\s\S]*?)(?:</div>\s*<div class="|</div>\s*<table)"#),
              gdtMatch.count >= 2 else {
            return results
        }
        let gdtBlock = gdtMatch[1]

        // 各 <a> 内の <div style="...background:...url(...)..."> を抽出
        // パターン: style="width:Wpx;height:Hpx;background:transparent url(URL) -Xpx 0 no-repeat"
        let entries = matchAll(gdtBlock, pattern: #"<a[^>]*>[\s\S]*?</a>"#)

        for (index, entry) in entries.enumerated() {
            // background:transparent url(...) -Xpx 0
            guard let styleMatch = firstMatch(entry, pattern: #"url\(([^)]+)\)\s+(-?\d+)px"#),
                  styleMatch.count >= 3,
                  let url = URL(string: styleMatch[1]) else {
                continue
            }
            let offsetX = CGFloat(Int(styleMatch[2]) ?? 0)

            // width, height
            let width: CGFloat
            if let wMatch = firstMatch(entry, pattern: #"width:\s*(\d+)px"#), wMatch.count >= 2 {
                width = CGFloat(Int(wMatch[1]) ?? 200)
            } else {
                width = 200
            }
            let height: CGFloat
            if let hMatch = firstMatch(entry, pattern: #"height:\s*(\d+)px"#), hMatch.count >= 2 {
                height = CGFloat(Int(hMatch[1]) ?? 200)
            } else {
                height = 200
            }

            results.append(ThumbnailInfo(
                index: index,
                spriteURL: url,
                offsetX: offsetX, // 負の値（例: -200）
                width: width,
                height: height
            ))
        }

        // gdtl モード（ラージサムネイル、スプライトではなく個別画像）
        if results.isEmpty {
            let imgEntries = matchAll(gdtBlock, pattern: #"<a[^>]*>[\s\S]*?<img[^>]*src="([^"]+)"[\s\S]*?</a>"#)
            for (index, entry) in imgEntries.enumerated() {
                if let m = firstMatch(entry, pattern: #"src="([^"]+)""#), m.count >= 2,
                   let url = URL(string: m[1]) {
                    results.append(ThumbnailInfo(
                        index: index,
                        spriteURL: url,
                        offsetX: 0,
                        width: 0, // 0 = 個別画像（スプライトではない）
                        height: 0
                    ))
                }
            }
        }

        return results
    }

    nonisolated static func parseFullImageURL(html: String) -> URL? {
        if let match = firstMatch(html, pattern: #"id="img"[^>]*src="([^"]+)""#), match.count >= 2 {
            return URL(string: match[1])
        }
        if let match = firstMatch(html, pattern: #"<img[^>]*id="img"[^>]*src="([^"]+)""#), match.count >= 2 {
            return URL(string: match[1])
        }
        return nil
    }

    /// 画像ページからnlトークンを取得（別ミラーサーバー要求用）
    nonisolated static func parseNLToken(html: String) -> String? {
        if let match = firstMatch(html, pattern: #"nl\(['\"]([^'\"]+)['\"]\)"#), match.count >= 2 {
            return match[1]
        }
        return nil
    }

    // MARK: - Page Number Parsing

    nonisolated static func parsePageNumber(html: String) -> PageNumber {
        // 1. pttテーブル方式（ギャラリー詳細ページのサムネ等）
        let current = firstMatch(html, pattern: #"<td class="ptds"[^>]*><a[^>]*>(\d+)</a>"#)
            .flatMap { $0.count >= 2 ? Int($0[1]) : nil }
            ?? firstMatch(html, pattern: #"<td class="ptds"[^>]*>(\d+)</td>"#)
            .flatMap { $0.count >= 2 ? Int($0[1]) : nil }
            ?? 0

        let pageLinks = matchAll(html, pattern: #"class="ptt"[\s\S]*?</table>"#)
        let allPages = matchAll(pageLinks.joined(), pattern: #">(\d+)</a>"#)
            .compactMap { link -> Int? in
                firstMatch(link, pattern: #">(\d+)<"#).flatMap { $0.count >= 2 ? Int($0[1]) : nil }
            }
        let maximum = allPages.max() ?? current

        // 2. searchnav方式（フロントページ、お気に入り等）
        // <a id="unext" href="...?next=12345">Next</a>
        let nextURL: String?
        if let m = firstMatch(html, pattern: #"id="unext"[^>]*href="([^"]+)""#), m.count >= 2 {
            nextURL = decodeHTMLEntities(m[1])
        } else if let m = firstMatch(html, pattern: #"id="next"[^>]*href="([^"]+)""#), m.count >= 2 {
            nextURL = decodeHTMLEntities(m[1])
        } else {
            nextURL = nil
        }

        return PageNumber(current: current, maximum: maximum, nextURL: nextURL)
    }

    // MARK: - Helpers

    nonisolated private static func extractCoverURL(from html: String) -> URL? {
        if let match = firstMatch(html, pattern: #"<img[^>]*data-src="([^"]+)"#), match.count >= 2 {
            return URL(string: match[1])
        }
        if let match = firstMatch(html, pattern: #"<img[^>]*src="(https?://[^"]*(?:hentai|ehgt)[^"]*)"#), match.count >= 2 {
            return URL(string: match[1])
        }
        if let match = firstMatch(html, pattern: #"url\((https?://[^)]+)\)"#), match.count >= 2 {
            return URL(string: match[1])
        }
        return nil
    }

    nonisolated private static func extractCategory(from html: String) -> GalleryCategory? {
        for cat in GalleryCategory.allCases {
            if html.contains(">\(cat.rawValue)<") || html.contains(">\(cat.rawValue.lowercased())<") {
                return cat
            }
        }
        if let match = firstMatch(html, pattern: #"class="c[st][^"]*"[^>]*>([^<]+)<"#), match.count >= 2 {
            return GalleryCategory(rawValue: match[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    nonisolated private static func extractRating(from html: String) -> Double {
        guard let match = firstMatch(html, pattern: #"class="ir[^"]*"[^>]*style="background-position:\s*(-?\d+)px\s+(-?\d+)px"#),
              match.count >= 3,
              let x = Int(match[1]),
              let y = Int(match[2]) else {
            return 0
        }
        var rating: Double
        switch x {
        case 0: rating = 5.0
        case -16: rating = 4.0
        case -32: rating = 3.0
        case -48: rating = 2.0
        case -64: rating = 1.0
        case -80: rating = 0.0
        default: rating = 0.0
        }
        if y == -21 { rating -= 0.5 }
        return max(0, rating)
    }

    nonisolated private static func extractText(from html: String, className: String) -> String? {
        if let match = firstMatch(html, pattern: "class=\"\(className)\"[^>]*>([^<]+)<"), match.count >= 2 {
            return match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    nonisolated private static func extractInfoValue(_ html: String, label: String) -> String? {
        let pattern = #"class="gdt1"[^>]*>\#(label):?</td>\s*<td[^>]*class="gdt2"[^>]*>([\s\S]*?)</td>"#
        if let match = firstMatch(html, pattern: pattern), match.count >= 2 {
            let raw = stripHTML(match[1])
            return decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    nonisolated static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    nonisolated static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&#x27;", "'"), ("&#x2F;", "/"), ("&nbsp;", " "),
            ("&ndash;", "–"), ("&mdash;", "—"), ("&laquo;", "«"),
            ("&raquo;", "»"), ("&copy;", "©"), ("&reg;", "®"),
            ("&trade;", "™"), ("&hellip;", "…"), ("&times;", "×"),
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // &#xHEX; 形式（16進数）
        let hexPattern = #"&#x([0-9a-fA-F]+);"#
        if let regex = try? NSRegularExpression(pattern: hexPattern) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                if match.numberOfRanges >= 2 {
                    let hexStr = nsString.substring(with: match.range(at: 1))
                    if let code = UInt32(hexStr, radix: 16), let scalar = Unicode.Scalar(code) {
                        result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
                    }
                }
            }
        }
        // &#DEC; 形式（10進数）
        let numericPattern = #"&#(\d+);"#
        if let regex = try? NSRegularExpression(pattern: numericPattern) {
            let nsString = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
            for match in matches.reversed() {
                if match.numberOfRanges >= 2 {
                    let codeStr = nsString.substring(with: match.range(at: 1))
                    if let code = Int(codeStr), let scalar = Unicode.Scalar(code) {
                        result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
                    }
                }
            }
        }
        return result
    }

    // MARK: - Regex Helpers

    /// パターンキャッシュ（NSRegularExpressionのコンパイルコスト削減）
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    nonisolated static func firstMatch(_ string: String, pattern: String) -> [String]? {
        guard let regex = cachedRegex(pattern) else { return nil }
        let nsString = string as NSString
        guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: nsString.length)) else { return nil }
        var results: [String] = []
        for i in 0..<match.numberOfRanges {
            let range = match.range(at: i)
            if range.location != NSNotFound {
                results.append(nsString.substring(with: range))
            } else {
                results.append("")
            }
        }
        return results
    }

    nonisolated static func matchAll(_ string: String, pattern: String) -> [String] {
        guard let regex = cachedRegex(pattern) else { return [] }
        let nsString = string as NSString
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: nsString.length))
        return matches.map { nsString.substring(with: $0.range) }
    }
}
