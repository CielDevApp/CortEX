import Foundation

// MARK: - ShikigamiKit 定数 (指示書 2026-07-21)
//
// アプリ内 SHIKIGAMI = Cort:EX 自身が母艦(shikigami-mac)へ打電するテレメトリ。
// ⚠️ 送信先 IP/port は「いかなる理由でも」ここに書かない (第18条 + 指示書§6)。
// 送信先はデバッグ設定画面から入力され UserDefaults に保存、実行時に読む。

enum ShikigamiConfig {
    /// 送信元識別。母艦 bridge が言上帳へ書く時のアプリ名。
    static let appTag = "CORTEX"
    /// 弾② メモリ打電の間隔 (Phase 2)
    static let memoryPollInterval: TimeInterval = 5
    /// 弾④ decode 統計の間隔 (Phase 2)
    static let decodeReportInterval: TimeInterval = 60
}
