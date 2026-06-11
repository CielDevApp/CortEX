import Foundation

// MARK: - ダウンロード作品のモデル (C: DownloadManager.swift から退去、2026-06-11)
// 挙動変更なし。Service ファイルに同居していた純データ型を Models/ へ。

/// リーダー表示方向。静止画ギャラリーは全体設定 readerDirection に従うが、
/// 動画 WebP 含みで横開き不可のギャラリーのみ per-gallery の override を保持する。
enum GalleryReaderMode: String, Codable, Sendable {
    case horizontal
    case vertical
}

struct DownloadedGallery: Codable, Identifiable, Sendable {
    var gid: Int
    var token: String
    var title: String
    var coverFileName: String?
    var pageCount: Int
    var downloadDate: Date
    var isComplete: Bool
    var downloadedPages: [Int]
    var source: String?  // "ehentai" or "nhentai"（nilは旧データ=ehentai）
    /// 明示的にキャンセルされたか（trueなら起動時autoResumeをスキップ）
    var isCancelled: Bool? = nil
    /// 自動保存 (autoSaveOnRead) だけで作られた meta = ユーザーの DL 意思なし。
    /// true なら起動時 auto-resume の対象外。突然終了するとキャンセルマークが付かない
    /// まま未完了 meta が残り、次回起動で読んだだけの作品がフル DL される幽霊 DL バグの
    /// 根治 (田中報告 2026-06-10)。明示的な DL 開始で解除される。
    var autoSaveOnly: Bool? = nil
    /// VP8X ANIM flag 走査結果。nil = 未走査（初回 Reader 起動時に migration で埋める）
    var hasAnimatedWebp: Bool? = nil
    /// ダイアログで選択された per-gallery モード上書き。nil = 未選択
    var readerModeOverride: GalleryReaderMode? = nil
    /// E-Hentai タグ (DL 開始時の Gallery.tags をスナップ)。nil = 旧 DL データで未保存。
    /// "other:animated" 等を含めば動画作品として確定判定 (実バイト scan 不要 = 二重判定排除)。
    var tags: [String]? = nil
    /// 田中要望 2026-04-26: 外部参照 .cortex の original E-Hentai/nhentai gid を保持。
    /// scanCortexZip で gid が Int.max - hash(zipPath) に namespace 分離されるため、
    /// 元 server 詳細 fetch (GalleryDetailView) には original gid が必要。
    /// nil = 旧 .cortex (export 時 metadata 未保存) or non-external、source server 詳細表示不可。
    var originalGid: Int? = nil

    var id: Int { gid }
    nonisolated var directoryName: String { "\(gid)" }
    var isNhentai: Bool { source == "nhentai" || token.hasPrefix("nh") }
    /// 動画作品判定: 優先順 (1) 実 scan 結果 → (2) タグ → (3) タイトル絵文字 heuristic。
    /// scan 完了済なら絵文字/タグ無関係に確定判定。タグがあれば即マーク表示で
    /// onAppear scan 起動も不要 (田中指示 2026-04-25 二重判定排除)。
    var isAnimatedGallery: Bool {
        if hasAnimatedWebp == true { return true }
        if hasAnimatedWebp == false { return false }
        // 未 scan (nil): タグ判定 → タイトル heuristic
        if hasAnimatedTag { return true }
        let t = title
        return t.contains("Animated") || t.contains("GIF") || t.contains("gif") || t.contains("🎥")
    }
    /// タグに "animated" を含むか (E-Hentai の "other:animated" 等を拾う)。case insensitive。
    var hasAnimatedTag: Bool {
        guard let tags else { return false }
        return tags.contains { $0.lowercased().contains("animated") }
    }
    /// nhentai用: 実際のnhentai IDを返す（gidは-nhIdで保存）
    var nhentaiId: Int? {
        guard isNhentai else { return nil }
        if gid < 0 { return -gid }
        return gid // 旧データ（正数gid）
    }
}

