import Foundation
import TipKit

// MARK: - リーダーTips

struct ReaderControlsTip: Tip {
    var title: Text { Text("コントロール表示") }
    var message: Text? { Text("長押しでコントロールの表示/非表示を切り替え") }
    var image: Image? { Image(systemName: "hand.tap") }
}

struct ReaderSwipeDismissTip: Tip {
    var title: Text { Text("リーダーを閉じる") }
    var message: Text? { Text("上下にスワイプでリーダーを閉じます") }
    var image: Image? { Image(systemName: "arrow.up.and.down") }
}

struct RTLSliderTip: Tip {
    @Parameter
    static var isRTLMode: Bool = false

    var title: Text { Text("右綴じモード") }
    var message: Text? { Text("右綴じ時はスライダーの方向も反転します") }
    var image: Image? { Image(systemName: "arrow.right.to.line") }

    var rules: [Tips.Rule] {
        [#Rule(Self.$isRTLMode) { $0 }]
    }
}

// MARK: - ガチャTip

struct GachaSwipeTip: Tip {
    var title: Text { Text("結果を閉じる") }
    var message: Text? { Text("左右にスワイプで結果画面を閉じます") }
    var image: Image? { Image(systemName: "hand.draw") }
}

// MARK: - エクストリームTip

struct ExtremeAutoOffTip: Tip {
    @Parameter
    static var extremeEnabled: Bool = false

    var title: Text { Text("自動OFF") }
    var message: Text? { Text("エクストリームモードはアプリ再起動で自動的にOFFになります") }
    var image: Image? { Image(systemName: "bolt.slash") }

    var rules: [Tips.Rule] {
        [#Rule(Self.$extremeEnabled) { $0 }]
    }
}

// MARK: - 自動保存Tip

struct AutoSaveTip: Tip {
    @Parameter
    static var autoSaveEnabled: Bool = false

    var title: Text { Text("自動保存") }
    var message: Text? { Text("閲覧した作品は自動的にローカルに保存されます") }
    var image: Image? { Image(systemName: "arrow.down.circle") }

    var rules: [Tips.Rule] {
        [#Rule(Self.$autoSaveEnabled) { $0 }]
    }
}

// MARK: - 横モードTip

struct HorizontalReaderTip: Tip {
    var title: Text { Text("端タップでページ送り") }
    var message: Text? { Text("画面の左右端をタップでページを送れます。中央タップでコントロール表示") }
    var image: Image? { Image(systemName: "hand.point.left.fill") }
}

// MARK: - 見開きTip

struct SpreadModeTip: Tip {
    var title: Text { Text("iPad見開きモード") }
    var message: Text? { Text("iPadを横向きにすると2ページ同時に表示。ダブルタップでズーム") }
    var image: Image? { Image(systemName: "book.pages") }
}

// MARK: - nhentaiTip

struct NhentaiSearchTip: Tip {
    var title: Text { Text("nhentai検索") }
    var message: Text? { Text("タイトルは自動で引用符付きフレーズ検索になります。タグ検索は group:名前 の形式で") }
    var image: Image? { Image(systemName: "magnifyingglass") }
}

// MARK: - お気に入りTip

struct FavoritesSyncTip: Tip {
    var title: Text { Text("お気に入り同期") }
    var message: Text? { Text("↻ボタンでnhentaiのお気に入りをサーバーと同期。キャッシュされるので次回から即表示") }
    var image: Image? { Image(systemName: "heart.circle") }
}

// MARK: - 削除作品Tip

struct RemovedGalleryTip: Tip {
    var title: Text { Text("削除作品の復活") }
    var message: Text? { Text("nhentai・nyahentai・hitomi.laの3サイトから自動検索。タイトルコピーで手動検索も可能") }
    var image: Image? { Image(systemName: "arrow.counterclockwise") }
}
