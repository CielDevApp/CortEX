import Foundation
import SwiftUI
import Combine

/// アニメ WebP の「▶ タップ再生」を複数セル間で協調管理するシングルトン。
///
/// 要件:
/// - 全 platform 統一: ページ開いた直後は再生しない (ポスター + ▶ 表示)。
///   ▶ タップで再生、もう一度タップで停止。
/// - 最大同時再生数 = 3 (田中指定)。4 つ目を再生したら LRU で最古の 1 つを停止。
/// - セルが LazyVStack で unmount されても playing state は保持 (reader+index でキー)。
/// - ギャラリー (reader) 切替時は別 reader の playing state も残る (他の reader に戻ると再生継続)。
///   ただし reader close 時にリセットしたい場合は resetForReader(_:) を呼ぶ。
@MainActor
final class AnimatedPlaybackCoordinator: ObservableObject {
    struct PageKey: Hashable {
        let readerID: String   // 例: "gallery-3898101", "local-3898101", "nh-3898101"
        let index: Int
    }

    static let shared = AnimatedPlaybackCoordinator()
    private init() {}

    /// 再生中のキー。配列の先頭ほど新しい (LRU 排出は末尾から)。
    /// @Published で全セルが contains 判定を購読、変化で body 再評価 → displayLink 即座 stop 可能。
    @Published private(set) var playing: [PageKey] = []

    /// 負債返済ユニット1 (2026-07-23, 15PM OOM 事件由来): 帳簿と実体の乖離を構造的に禁止する。
    /// 従来の停止は「@Published 変化 → セル body 再評価 → unmount」頼みで、画面外セルは
    /// 再評価されず displayLink がゾンビ化した (closeReader 後 6 分生存 ×2 → jetsam)。
    /// 再生実体 (AnimatedSourceImageView) は再生開始時に停止クロージャを登録し、
    /// Coordinator は帳簿から外す瞬間に**必ず直接停止を執行**する。
    /// SwiftUI 購読 / willMove / deinit / tick ゾンビガードはバックストップに格下げ。
    private var stoppers: [PageKey: () -> Void] = [:]

    /// 再生実体が停止手段を登録する (weak capture 前提。startLink 時に呼ぶ)。
    func attachStopper(_ key: PageKey, _ stop: @escaping () -> Void) {
        stoppers[key] = stop
    }

    /// 再生実体の破棄時に登録を外す (deinit / stopLink 時)。
    func detachStopper(_ key: PageKey) {
        stoppers[key] = nil
    }

    /// 帳簿から外したキーの実体停止を執行する。
    private func enforceStop(_ key: PageKey, reason: String) {
        guard let stop = stoppers[key] else { return }
        stoppers[key] = nil
        stop()
        LogManager.shared.log("Anim", "enforced-stop \(key.readerID)#\(key.index) (\(reason))")
    }

    /// 最大同時再生数。UserDefaults `animMaxConcurrentPlay` で可変、default=1。
    /// 1 件再生中に別ページ▶タップで旧再生が自動停止 = シンプルな切替動作。
    /// Mac Catalyst で 3 件同時は libwebp decode + 230MB×3 で負荷過多のため default を 1 に。
    var maxConcurrent: Int {
        let v = UserDefaults.standard.integer(forKey: UDKey.animMaxConcurrentPlay)
        return v > 0 ? v : 1
    }

    func isPlaying(_ key: PageKey) -> Bool {
        playing.contains(key)
    }

    /// ▶ / ■ タップハンドラ: 現在再生中ならば停止、止まっていれば再生開始。
    /// 上限超過時は末尾 (最古) を自動停止 (LRU eviction)。
    func toggle(_ key: PageKey) {
        if let idx = playing.firstIndex(of: key) {
            playing.remove(at: idx)
            enforceStop(key, reason: "toggle")
            LogManager.shared.log("Anim", "playback toggle STOP \(key.readerID)#\(key.index) playing=\(playing.count)/\(maxConcurrent)")
        } else {
            playing.insert(key, at: 0)
            if playing.count > maxConcurrent {
                let evicted = playing.removeLast()
                enforceStop(evicted, reason: "LRU")
                LogManager.shared.log("Anim", "playback LRU EVICT \(evicted.readerID)#\(evicted.index) (new=\(key.readerID)#\(key.index))")
            } else {
                LogManager.shared.log("Anim", "playback toggle START \(key.readerID)#\(key.index) playing=\(playing.count)/\(maxConcurrent)")
            }
        }
    }

    /// reader close 時に呼ぶと、その reader 配下の再生を全停止。
    func resetForReader(_ readerID: String) {
        let removed = playing.filter { $0.readerID == readerID }
        guard !removed.isEmpty else { return }
        playing.removeAll { $0.readerID == readerID }
        for key in removed { enforceStop(key, reason: "readerClose") }
        LogManager.shared.log("Anim", "playback reset reader=\(readerID) stopped=\(removed.count)")
    }

    /// reader close 時の memory 解放統合 API。
    /// resetForReader + LRU 強参照 cache clear + 全 alive source の frameCache drop を一括実行。
    /// 多 source 開いた後 reader 閉じて戻っても memory がパンパンにならないよう、閉じたら全解放。
    /// 次に ▶ タップ時は rawData から再度 decode するが、preload モードならユーザー側で進捗が見える。
    func closeReader(_ readerID: String) {
        resetForReader(readerID)
        #if canImport(UIKit)
        AnimatedImageSourceCache.shared.clear()
        AnimatedImageSourceRegistry.shared.dropAllCaches()
        #endif
        LogManager.shared.log("Mem", "closeReader \(readerID) → cache cleared (LRU + frameCache)")
    }

    /// 全停止 (app background 等)。
    func stopAll() {
        guard !playing.isEmpty else { return }
        LogManager.shared.log("Anim", "playback stopAll count=\(playing.count)")
        let removed = playing
        playing.removeAll()
        for key in removed { enforceStop(key, reason: "stopAll") }
    }
}
