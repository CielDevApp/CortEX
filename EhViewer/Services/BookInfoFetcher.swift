import Foundation

/// Phase R-7: ISBN から書名/著者を取得 (openBD 優先 → Google Books フォールバック)。API key 不要。
struct BookInfo {
    let isbn: String
    let title: String
    let author: String?
}

enum BookInfoFetcher {
    static func fetch(isbn: String) async -> BookInfo? {
        if let b = await openBD(isbn) { return b }
        return await googleBooks(isbn)
    }

    /// https://api.openbd.jp/v1/get?isbn=XXXX  (日本の書籍に強い)
    private static func openBD(_ isbn: String) async -> BookInfo? {
        guard let url = URL(string: "https://api.openbd.jp/v1/get?isbn=\(isbn)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let first = arr.first as? [String: Any],
              let summary = first["summary"] as? [String: Any] else { return nil }
        let title = (summary["title"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let author = (summary["author"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return BookInfo(isbn: isbn, title: title, author: author)
    }

    /// https://www.googleapis.com/books/v1/volumes?q=isbn:XXXX
    private static func googleBooks(_ isbn: String) async -> BookInfo? {
        guard let url = URL(string: "https://www.googleapis.com/books/v1/volumes?q=isbn:\(isbn)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let vol = items.first?["volumeInfo"] as? [String: Any],
              let title = vol["title"] as? String, !title.isEmpty else { return nil }
        let author = (vol["authors"] as? [String])?.joined(separator: ", ")
        return BookInfo(isbn: isbn, title: title, author: author)
    }
}
