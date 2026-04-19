import Foundation
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

/// ダウンロード進捗のLive Activity属性
/// Mac Catalyst では ActivityKit 非対応のためビルド除外
struct DownloadActivityAttributes: ActivityAttributes {
    /// 固定情報（Activity作成時に設定）
    let galleryTitle: String
    let totalPages: Int
    let gid: Int

    /// 動的に更新される状態
    struct ContentState: Codable, Hashable {
        var currentPage: Int
        var progress: Double
        var isComplete: Bool
        var isFailed: Bool
    }
}
#endif
