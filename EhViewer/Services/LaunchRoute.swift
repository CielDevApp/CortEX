import Foundation

// MARK: - リーダー起動経路 (2026-07-21 第21条・田中厳命)
//
// 「どの経路から開いたか」をコードに刻む。紙の上の対応表だけでは、田中が言葉で伝えた経路
// (「サムネから」「ジャケットのページ詳細から」) を Code が雰囲気でコード上の経路へ対応付け、
// 雰囲気で外す。今日の6連敗の根っこがこれ。
//
// **デフォルト値を与えないこと。** 与えると未分類の経路が silent に生まれ、計装の意味が消える。
// 起動のたびに `ROUTE <経路> gid=... reader=... dir=...` をログ + 打電する。

enum LaunchRoute: String {
    // ライブラリ (ローカル)
    case libraryCardTile        // カードの序盤ページタイル → 該当ページへワープ
    case libraryCardRead        // カードの「読む」ボタン
    case libraryCardJacket      // カードのジャケット → ページ詳細
    case libraryDetailSheet     // ライブラリ内シート (ページ詳細) 経由
    case libraryLiveDL          // DL 中作品
    case libraryPreviewOverlay  // 全ページプレビューのタイル
    // オンライン E-H
    case onlineList             // 一覧の長押しプレビュー
    case onlineDetail           // 詳細画面「読む」
    case onlineHistory
    case onlineFavorites
    case onlineTagSearch
    // オンライン nhentai
    case nhList
    case nhDetail
    case nhDetailPreview
    case nhHistory
    case nhFavorites
    // cortex:// URL スキーム経由 (2026-07-21: enum 必須化で発見された未分類経路)
    case urlSchemeOnline
    case urlSchemeLocal
}
