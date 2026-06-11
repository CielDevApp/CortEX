import Foundation

extension Array where Element: Identifiable {
    /// 既存 id と重複しない要素だけ末尾に追加し、除外した件数を返す。
    ///
    /// B3 (2026-06-11): GalleryListViewModel / NhentaiListViewModel の append ページングで
    /// 同 id が混入すると LazyVGrid + .id(...) で SwiftUI が同一 view と見なし row 抜け/空白化
    /// する。この重複除外は 2026-04-27 に E-H/nh 両方で同一バグを踏んだ唯一の「片側だけ修正」
    /// 履歴を持つ箇所。VM 全体は構造が違いすぎて統合しない (ページング/キャッシュ/enrich が別物)
    /// が、この一点だけは共通化して再発を構造的に防ぐ。
    @discardableResult
    mutating func appendDeduplicated(_ newItems: [Element]) -> Int {
        let existing = Set(map { $0.id })
        let fresh = newItems.filter { !existing.contains($0.id) }
        append(contentsOf: fresh)
        return newItems.count - fresh.count
    }
}
