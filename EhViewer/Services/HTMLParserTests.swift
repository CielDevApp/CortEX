import Foundation

/// HTMLParserの回帰テスト（アプリ内実行）
/// デバッグビルド時にLogManagerに結果出力
enum HTMLParserTests {

    static func runAll() {
        var passed = 0
        var failed = 0

        func assert(_ condition: Bool, _ name: String) {
            if condition {
                passed += 1
            } else {
                failed += 1
                LogManager.shared.log("Test", "FAIL: \(name)")
            }
        }

        // 1. ギャラリーURL抽出
        let galleryHTML = """
        <tr><td><a href="https://exhentai.org/g/12345/abc123def/">
        <div class="glink">Test Gallery Title</div>
        </a></td></tr>
        """
        let galleries = HTMLParser.parseGalleryList(html: galleryHTML)
        assert(galleries.count == 1, "parseGalleryList: count")
        assert(galleries.first?.gid == 12345, "parseGalleryList: gid")
        assert(galleries.first?.token == "abc123def", "parseGalleryList: token")
        assert(galleries.first?.title == "Test Gallery Title", "parseGalleryList: title")

        // 2. 空HTMLでクラッシュしない
        let emptyGalleries = HTMLParser.parseGalleryList(html: "")
        assert(emptyGalleries.isEmpty, "parseGalleryList: empty")

        // 3. ページ番号パース
        let pageHTML = """
        <table class="ptt"><tr>
        <td class="ptds"><a>3</a></td>
        <td><a href="?page=4">4</a></td>
        <td><a href="?page=5">5</a></td>
        </tr></table>
        """
        let pageNum = HTMLParser.parsePageNumber(html: pageHTML)
        assert(pageNum.current == 3, "parsePageNumber: current")
        assert(pageNum.maximum >= 5, "parsePageNumber: maximum")

        // 4. nextURL抽出
        let nextHTML = """
        <a id="unext" href="https://exhentai.org/favorites.php?next=12345">Next</a>
        """
        let nextPage = HTMLParser.parsePageNumber(html: nextHTML)
        assert(nextPage.nextURL != nil, "parsePageNumber: nextURL exists")
        assert(nextPage.hasNext, "parsePageNumber: hasNext")

        // 5. nextURLなし
        let noNextHTML = "<div>no pagination</div>"
        let noNext = HTMLParser.parsePageNumber(html: noNextHTML)
        assert(noNext.nextURL == nil, "parsePageNumber: no nextURL")

        // 6. 画像ページURL抽出
        let imgPageHTML = """
        <div id="gdt">
        <a href="https://exhentai.org/s/abc123/12345-1">thumb</a>
        <a href="https://exhentai.org/s/def456/12345-2">thumb</a>
        </div>
        <table class="ptt"></table>
        """
        let imgURLs = HTMLParser.parseImagePageURLs(html: imgPageHTML)
        assert(imgURLs.count == 2, "parseImagePageURLs: count")

        // 7. フル画像URL抽出
        let fullImgHTML = """
        <img id="img" src="https://hath.network/h/abc123.jpg" />
        """
        let fullURL = HTMLParser.parseFullImageURL(html: fullImgHTML)
        assert(fullURL != nil, "parseFullImageURL: exists")
        assert(fullURL?.absoluteString.contains("abc123") == true, "parseFullImageURL: content")

        // 8. フル画像URLなし
        let noImgHTML = "<div>no image</div>"
        assert(HTMLParser.parseFullImageURL(html: noImgHTML) == nil, "parseFullImageURL: nil")

        // 9. HTMLエンティティデコード
        let decoded = HTMLParser.decodeHTMLEntities("Hello &amp; World &lt;test&gt;")
        assert(decoded == "Hello & World <test>", "decodeHTMLEntities: basic")

        // 10. 数値エンティティ
        let numDecoded = HTMLParser.decodeHTMLEntities("&#65;&#66;&#67;")
        assert(numDecoded == "ABC", "decodeHTMLEntities: numeric")

        // 11. 16進エンティティ
        let hexDecoded = HTMLParser.decodeHTMLEntities("&#x41;&#x42;")
        assert(hexDecoded == "AB", "decodeHTMLEntities: hex")

        // 12. レーティング抽出（正規表現）
        let ratingHTML = """
        <div class="ir" style="background-position:-16px -21px"></div>
        """
        // -16px = 4.0, -21px = -0.5 → 3.5
        if let match = HTMLParser.firstMatch(ratingHTML, pattern: #"background-position:\s*(-?\d+)px\s+(-?\d+)px"#) {
            assert(match.count >= 3, "rating: match groups")
        }

        LogManager.shared.log("Test", "HTMLParser tests: \(passed) passed, \(failed) failed")
    }
}
