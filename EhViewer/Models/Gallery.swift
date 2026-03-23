import Foundation

enum GalleryHost: String, CaseIterable, Sendable {
    case ehentai = "e-hentai.org"
    case exhentai = "exhentai.org"

    var baseURL: String { "https://\(rawValue)" }
}

enum GalleryCategory: String, CaseIterable, Sendable, Codable {
    case doujinshi = "Doujinshi"
    case manga = "Manga"
    case artistCG = "Artist CG"
    case gameCG = "Game CG"
    case western = "Western"
    case nonH = "Non-H"
    case imageSet = "Image Set"
    case cosplay = "Cosplay"
    case asianPorn = "Asian Porn"
    case misc = "Misc"

    /// e-hentaiのカテゴリビット値（f_catsで使用）
    var catBit: Int {
        switch self {
        case .doujinshi: return 2
        case .manga: return 4
        case .artistCG: return 8
        case .gameCG: return 16
        case .western: return 512
        case .nonH: return 256
        case .imageSet: return 32
        case .cosplay: return 64
        case .asianPorn: return 128
        case .misc: return 1
        }
    }

    /// 指定カテゴリのみ表示する f_cats 値（他を全て除外）
    static func excludeAllExcept(_ categories: [GalleryCategory]) -> Int {
        let all = 1023 // 全カテゴリのビットOR
        let include = categories.reduce(0) { $0 | $1.catBit }
        return all - include
    }

    var color: String {
        switch self {
        case .doujinshi: return "FC4C4C"
        case .manga: return "F09F17"
        case .artistCG: return "D1A918"
        case .gameCG: return "59A95E"
        case .western: return "8DB31E"
        case .nonH: return "A5B6C7"
        case .imageSet: return "4B70C2"
        case .cosplay: return "9E6FC2"
        case .asianPorn: return "E396C2"
        case .misc: return "777777"
        }
    }
}

struct Gallery: Identifiable, Hashable, Sendable, Codable {
    let gid: Int
    let token: String
    var title: String
    var category: GalleryCategory?
    var coverURL: URL?
    var rating: Double
    var pageCount: Int
    var postedDate: String
    var uploader: String?
    var tags: [String]

    var id: Int { gid }

    func galleryURL(host: GalleryHost) -> String {
        "\(host.baseURL)/g/\(gid)/\(token)/"
    }
}

struct GalleryDetail: Sendable {
    var gallery: Gallery
    var jpnTitle: String?
    var language: String?
    var fileSize: String?
    var favoritedCount: Int?
    var isFavorited: Bool
    var previewURLs: [URL]
    var thumbnailPageURLs: [URL]
    var normalizedTags: [String: [String]]
}

struct PageNumber: Sendable {
    var current: Int
    var maximum: Int
    /// searchnavベースのページネーション用 次ページURL
    var nextURL: String?
    var hasNext: Bool { nextURL != nil || current < maximum }
}

/// スプライトシート方式のサムネイル情報
struct ThumbnailInfo: Sendable, Identifiable {
    let index: Int
    let spriteURL: URL
    let offsetX: CGFloat
    let width: CGFloat
    let height: CGFloat

    var id: Int { index }
}
