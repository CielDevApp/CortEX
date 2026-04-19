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
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.count = limit
    }

    func wait() async {
        lock.lock()
        if count > 0 {
            count -= 1
            lock.unlock()
            return
        }
        // 保留: continuation を waiters に積んで suspend
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            // resume は lock 外で（resume 中の再入を回避）
            waiter.resume()
        } else {
            if count < limit {
                count += 1
            }
            lock.unlock()
        }
    }
}
