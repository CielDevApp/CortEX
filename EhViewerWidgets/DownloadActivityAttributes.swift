import Foundation
import ActivityKit

/// ダウンロード進捗のLive Activity属性（Widget Extension用コピー）
/// メインアプリ側の EhViewer/Models/DownloadActivity.swift と同一の定義
struct DownloadActivityAttributes: ActivityAttributes {
    let galleryTitle: String
    let totalPages: Int
    let gid: Int

    struct ContentState: Codable, Hashable {
        var currentPage: Int
        var progress: Double
        var isComplete: Bool
        var isFailed: Bool
    }
}
