import Foundation

/// ビルドバージョン識別子。コード変更時にタイムスタンプを更新する。
/// 起動時ログに出力され、実機に入ってるビルドが最新か一目で確認できる。
enum BuildInfo {
    /// 変更したら手動更新する形式: YYYY-MM-DD HH:mm + 変更内容簡易サマリ
    static let tag = "2026-04-19 22:05 VT-HW-HEVC + formatDescHint"
}
