import Foundation

/// Swift Concurrency対応のセマフォ（並列数制限）
///
/// NSLock ベース（actor 不使用）: defer からの signal() 二重 resume クラッシュを回避。
/// actor では `defer { urlResolveSem.signal() }` のように await 無し呼び出しが
/// 暗黙の detached Task 化され、複数 signal が並行実行→waiters 配列競合→
/// 同じ continuation を二度 resume → CheckedContinuation assertion trap。
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    // nonisolated(unsafe): lock 保護下でのみアクセス (default MainActor isolation の対象外にする)
    nonisolated(unsafe) private var count: Int
    /// id 付き waiters: キャンセル時に該当 continuation だけ取り除いて resume するため
    nonisolated(unsafe) private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    nonisolated(unsafe) private var nextWaiterID: UInt64 = 0

    nonisolated init(limit: Int) {
        self.limit = limit
        self.count = limit
    }

    /// 待機キャンセル対応 (2026-06-10):
    /// 旧実装は withCheckedContinuation のみで、待機中 Task が cancel されても
    /// signal() が来るまで永久 suspend していた。withTaskCancellationHandler で
    /// キャンセル時に自分の continuation を waiters から外して即 resume する。
    /// 注意: キャンセル resume はスロットを取得しないまま返るため、呼び出し側の
    /// defer signal() で 1 回ぶん余分に解放され得るが、count は limit でキャップ
    /// されるので恒久的なスロット増殖は起きない (一時的な +1 並列のみ)。
    nonisolated func wait() async {
        lock.lock()
        if count > 0 {
            count -= 1
            lock.unlock()
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        lock.unlock()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                // suspend 準備中に cancel 済み (onCancel が先に走り waiters に居なかった) →
                // 登録せず即 resume して抜ける
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                // suspend 準備中に slot が空いたケース
                if count > 0 {
                    count -= 1
                    lock.unlock()
                    continuation.resume()
                    return
                }
                // 保留: continuation を waiters に積んで suspend
                waiters.append((id, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: idx)
                lock.unlock()
                // resume は lock 外で（resume 中の再入を回避）
                waiter.continuation.resume()
            } else {
                lock.unlock()
            }
        }
    }

    nonisolated func signal() {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            // resume は lock 外で（resume 中の再入を回避）
            waiter.continuation.resume()
        } else {
            if count < limit {
                count += 1
            }
            lock.unlock()
        }
    }
}
