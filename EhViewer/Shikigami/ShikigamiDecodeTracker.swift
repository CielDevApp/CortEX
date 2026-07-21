import Foundation

// MARK: - decode 統計収集 (弾④) + 現在 decode 中カウント (弾②の decodeCount)
//
// LibraryThumbDecoder が begin()/end() で稼働枚数を、record() で完了統計を積む。
// Engine が 60秒毎に drain() して REPORT を打電しリセットする。
// 常に存在するが、Engine が stop 中でも「溜めるだけ」(打電しない) — メモリ負荷は無視できる。
// EhViewer 固有型を参照しない (Package 化)。

final class ShikigamiDecodeTracker {
    static let shared = ShikigamiDecodeTracker()
    private let lock = NSLock()

    private var active = 0          // 現在 decode 中 (弾② decodeCount)
    private var total = 0           // 集計期間の完了数
    private var totalMs = 0.0
    private var hits = 0
    private var misses = 0

    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return active }

    func begin() { lock.lock(); active += 1; lock.unlock() }
    func end()   { lock.lock(); active = max(0, active - 1); lock.unlock() }

    func record(durationMs: Double, cacheHit: Bool) {
        lock.lock()
        total += 1
        totalMs += durationMs
        if cacheHit { hits += 1 } else { misses += 1 }
        lock.unlock()
    }

    /// 集計を取り出してリセット (弾④ 60秒毎)。
    func drain() -> (total: Int, avgMs: Double, hitRate: Double) {
        lock.lock(); defer { lock.unlock() }
        let t = total
        let avg = t > 0 ? totalMs / Double(t) : 0
        let denom = hits + misses
        let hr = denom > 0 ? Double(hits) / Double(denom) : 0
        total = 0; totalMs = 0; hits = 0; misses = 0
        return (t, avg, hr)
    }
}
