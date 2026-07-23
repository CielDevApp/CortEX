import Foundation

// MARK: - 動画 WebP モード解決の共通リゾルバ (負債返済ユニット2, 2026-07-23)
//
// 従来は LocalReaderView / GalleryReaderView / NhentaiReaderView に判定ラダーが 3 重実装
// されており、「片方だけ直して直ったと誤報する」事故の温床だった (2026-07-21 ダイアログ
// 無限ループ事件で実際に発生)。判定の意思決定はここに 1 本化し、リーダー側は
// 「確定方向を反映する / ダイアログを出す」の 2 分岐だけを持つ。
//
// 呼び出し側固有の要素は入力に寄せる:
// - localMeta: ローカルリーダーは downloads に無くても meta を持つ (fallback)
// - heuristicHit: DL 前オンライン読みのタイトル/タグ判定 (計算は呼び出し側、nil = ローカル)
//
// 統一に伴う意図的な挙動変更 (1点):
// override の参照を hasAnimatedWebp == true の時に限定 (旧 Local の意味論に統一)。
// 旧 Online/NH は override を先に見ていたため、静止画ギャラリーに古い override が
// 残っていると設定を無視して開く隅ケースがあった。静止画は常に設定どおりになる。

@MainActor
enum ReaderModeResolver {

    enum Resolution {
        /// 方向確定 (0=縦 / 1=横)
        case direction(Int)
        /// 動画入り + 横設定 + override 無し → モード選択ダイアログを出す
        case askUser
    }

    struct Outcome {
        let resolution: Resolution
        /// 実走査で動画入りと確定したか (ローカルの性能警告表示用)
        let hasAnimatedConfirmed: Bool
    }

    struct Input {
        let gid: Int
        /// 設定値 (0=縦 1=横)
        let userDirection: Int
        /// タイル起動等の強制方向 (静止画のみ適用、動画入りは通常解決へ)。現状は常に nil
        var forcedDirection: Int? = nil
        /// ローカルリーダーの meta (downloads に無くてもこれで判定できる)
        var localMeta: DownloadedGallery? = nil
        /// DL 前オンライン読みのフォールバック判定 (タイトル/タグ)。nil = ローカル (不使用)
        var heuristicHit: Bool? = nil
        /// ログ識別子 ("Local" / "Online" / "NH")
        let logPrefix: String
    }

    static func resolve(_ input: Input) async -> Outcome {
        let dm = DownloadManager.shared
        let p = input.logPrefix

        // 0) 強制方向 (タイル起動)。動画入りは再生経路が壊れるため通常解決へ委ねる
        if let forced = input.forcedDirection {
            await dm.ensureAnimatedWebpScanned(gid: input.gid)
            let scanned = dm.downloads[input.gid] ?? input.localMeta
            if !(scanned?.hasAnimatedWebp ?? false) {
                LogManager.shared.log("Anim", "\(p) resolve: forced dir=\(forced) (static)")
                return Outcome(resolution: .direction(forced), hasAnimatedConfirmed: false)
            }
            LogManager.shared.log("Anim", "\(p) resolve: forced but animated → 通常解決へ")
        }

        // 1) 縦設定 → 即確定 (縦は動画 WebP を再生できるのでダイアログ不要)
        guard input.userDirection == 1 else {
            LogManager.shared.log("Anim", "\(p) resolve: vertical setting, skip dialog")
            return Outcome(resolution: .direction(input.userDirection), hasAnimatedConfirmed: false)
        }

        // 2) meta があれば実走査結果を優先 (確実)。既存ギャラリー migration も兼ねる
        if dm.downloads[input.gid] != nil || input.localMeta != nil {
            await dm.ensureAnimatedWebpScanned(gid: input.gid)
            if let m = dm.downloads[input.gid] ?? input.localMeta {
                let isLocal = input.localMeta != nil
                // ローカルは scan 済み前提で nil を「動画なし」扱い (旧挙動維持)。
                // オンラインの nil は「未走査」なので heuristic へフォールバック。
                let hasAnim: Bool? = m.hasAnimatedWebp ?? (isLocal ? false : nil)
                LogManager.shared.log("Anim", "\(p) resolve meta gid=\(input.gid) hasAnim=\(hasAnim.map(String.init) ?? "nil") override=\(m.readerModeOverride?.rawValue ?? "nil")")
                if hasAnim == false {
                    return Outcome(resolution: .direction(1), hasAnimatedConfirmed: false)
                }
                if hasAnim == true {
                    if let ov = m.readerModeOverride {
                        return Outcome(resolution: .direction(ov == .horizontal ? 1 : 0), hasAnimatedConfirmed: true)
                    }
                    LogManager.shared.log("Anim", "\(p) resolve: SHOW DIALOG (meta) gid=\(input.gid)")
                    return Outcome(resolution: .askUser, hasAnimatedConfirmed: true)
                }
                // hasAnim == nil (オンライン・未走査) → heuristic へ
            }
        }

        // 3) DL 前のオンライン読み: タイトル/タグ heuristic (override 保存先が無いので毎回ダイアログ)
        if input.heuristicHit == true {
            LogManager.shared.log("Anim", "\(p) resolve: SHOW DIALOG (heuristic) gid=\(input.gid)")
            return Outcome(resolution: .askUser, hasAnimatedConfirmed: false)
        }
        return Outcome(resolution: .direction(1), hasAnimatedConfirmed: false)
    }
}
