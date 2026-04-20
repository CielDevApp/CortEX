import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// バックグラウンドでもダウンロードが継続する URLSessionDownloadTask 管理
/// 一括enqueue方式: 全タスクを事前投入 → iOSが suspended中も処理 → delegate で完了通知
final class BackgroundDownloadManager: NSObject {
    static let shared = BackgroundDownloadManager()

    static let nhSessionId = "com.kanayayuutou.CortEX.nhdl"
    static let ehSessionId = "com.kanayayuutou.CortEX.ehdl"

    private var _nhSession: URLSession?
    private var _ehSession: URLSession?

    /// foreground session（URLSessionConfiguration.default）で 4 並列 DL を実現。
    /// iOS の background session は 1/host の hard limit があり、動画WebPがシリアル化するため
    /// foreground に切替。アプリが background に落ちた時は iOS が suspend→DL 一時停止、
    /// foreground 復帰時に自動再開。アプリ完全終了後は起動時 auto-resume で続行。
    var nhSession: URLSession {
        if let s = _nhSession { return s }
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 4  // 4並列
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _nhSession = s
        return s
    }

    var ehSession: URLSession {
        if let s = _ehSession { return s }
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 4
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _ehSession = s
        return s
    }

    /// タスク登録情報
    private struct TaskEntry {
        let gid: Int
        let pageIndex: Int
        let finalPath: URL
    }

    /// gid別の完了イベント
    struct PageCompletion {
        let pageIndex: Int
        let success: Bool
        let retriable: Bool  // HTTPエラー等で再試行可能か
    }

    /// taskIdentifier → TaskEntry
    private var registry: [Int: TaskEntry] = [:]
    /// 単発DL（非batch）用: taskIdentifier → continuation
    private var singleTaskContinuations: [Int: (URL, CheckedContinuation<Bool, Never>)] = [:]
    /// gid → AsyncStream（batch DL用）
    private var gidStreams: [Int: AsyncStream<PageCompletion>.Continuation] = [:]
    private let stateQueue = DispatchQueue(label: "bgdl.state", qos: .userInitiated)

    /// 速度計測用: gid → 前回サンプル以降の受信バイト累積
    /// 専用NSLockで保護: stateQueueと分離→delegate queue/main の競合を切断
    private var bytesAccumulator: [Int: Int64] = [:]
    private var bytesSampleTime: [Int: CFAbsoluteTime] = [:]
    /// リアルタイム表示用: gid → セッション開始以降の受信累計（非リセット）
    private var cumulativeBytesReceived: [Int: Int64] = [:]
    private let bytesLock = NSLock()

    /// アプリ復帰時にシステムから受け取るcompletionHandler
    var systemCompletionHandlers: [String: () -> Void] = [:]

    /// 速度ベース stall 検出 (個別 task 単位)
    /// 既存の stream watchdog (DownloadManager 側、20秒 completion 無しで強制終了) は
    /// 「そもそも completion が来ない」ケース用。SpeedTracker は「通信はしてるが遅すぎる」
    /// ケースを別軸で検知する。責務分離でダブルキルを回避
    private let speedTracker = SpeedTracker()
    private var speedCheckTimer: DispatchSourceTimer?

    private override init() {
        super.init()
        // 起動時に前回の残骸 task をクリーンアップ
        Task.detached(priority: .utility) { [weak self] in
            await self?.cleanupStaleTasks()
        }
        // 5秒ごとに SpeedTracker を評価 (低速 task を早期 kill → 2ndpass で mirror 切替)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.evaluateSpeedStalls()
        }
        timer.resume()
        speedCheckTimer = timer
    }

    private func evaluateSpeedStalls() {
        let killed = speedTracker.evaluateAndCancel()
        for (taskId, reason) in killed {
            LogManager.shared.log("bgdl", "speed-kill taskId=\(taskId) \(reason)")
        }
    }

    /// 前回の session に残ってるタスクをキャンセル（registry に対応なしの実行中 task）
    private func cleanupStaleTasks() async {
        for session in [nhSession, ehSession] {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.getAllTasks { tasks in
                    let ids = tasks.map { $0.taskIdentifier }
                    for task in tasks { task.cancel() }
                    LogManager.shared.log("bgdl", "cleanup stale tasks: \(ids.count) in \(session.configuration.identifier ?? "?")")
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Single-task API (互換性用)

    /// 単発DL: URL1つをfinalPathに保存（従来互換API）
    func downloadToFile(url: URL, session: URLSession, finalPath: URL, headers: [String: String] = [:]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var request = URLRequest(url: url)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let task = session.downloadTask(with: request)
            stateQueue.sync {
                singleTaskContinuations[task.taskIdentifier] = (finalPath, continuation)
            }
            speedTracker.start(taskId: task.taskIdentifier, task: task)
            task.resume()
        }
    }

    // MARK: - Batch API

    /// gid用の完了ストリームを作成（既存なら再利用）
    func makeStream(for gid: Int) -> AsyncStream<PageCompletion> {
        AsyncStream { continuation in
            stateQueue.sync {
                gidStreams[gid] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.stateQueue.sync {
                    self?.gidStreams.removeValue(forKey: gid)
                }
            }
        }
    }

    /// 1ページをenqueue（batch DL）
    func enqueue(url: URL, gid: Int, pageIndex: Int, finalPath: URL, session: URLSession, headers: [String: String] = [:]) {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.downloadTask(with: request)
        stateQueue.sync {
            registry[task.taskIdentifier] = TaskEntry(gid: gid, pageIndex: pageIndex, finalPath: finalPath)
        }
        speedTracker.start(taskId: task.taskIdentifier, task: task)
        task.resume()
    }

    /// gidのストリームを強制終了（watchdogからfor-awaitを抜けさせる用）
    /// finish() が onTermination を同期発火→stateQueue 再入で deadlock trap するため、
    /// gidStreams から先に取り出して、finish() は lock 外で呼ぶ
    func finishStream(for gid: Int) {
        let continuation: AsyncStream<PageCompletion>.Continuation? = stateQueue.sync {
            let c = gidStreams.removeValue(forKey: gid)
            return c
        }
        continuation?.finish()
    }

    /// gidの全タスクをキャンセル
    func cancelAllTasks(for gid: Int, session: URLSession) {
        session.getAllTasks { tasks in
            self.stateQueue.sync {
                for task in tasks {
                    if let entry = self.registry[task.taskIdentifier], entry.gid == gid {
                        task.cancel()
                        self.registry.removeValue(forKey: task.taskIdentifier)
                    }
                }
            }
        }
    }

    // MARK: - Validation

    /// 保存したファイルが画像として有効かチェック（マジックバイト）
    static func isValidImageFile(at path: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16) else { return false }
        guard head.count >= 4 else { return false }
        let b = [UInt8](head)
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true }  // JPEG
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true }  // PNG
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return true }  // GIF
        if b.count >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
           b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return true }  // WebP
        return false
    }

    /// E-Hentai が帯域制限 (Hath 枠超過) で返す 509 警告 GIF を判定
    /// マジックバイトは有効な GIF なので isValidImageFile は通過する → 追加判定が必要
    /// 判定条件: URL path が 509 画像 or (GIF + サイズ 5KB 未満)
    /// 該当したら retriable として扱い、ファイルを破棄してリトライキューへ
    static func looksLike509Warning(url: URL?, filePath: URL) -> Bool {
        // URL path チェック (定番パス)
        let p = url?.path.lowercased() ?? ""
        if p.hasSuffix("/509.gif") || p.hasSuffix("/509s.gif") {
            return true
        }
        // ファイルサイズチェック (509 警告 gif は典型 ~1KB)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath.path),
              let size = attrs[.size] as? Int64, size < 5 * 1024 else {
            return false
        }
        // GIF マジックバイト確認 (小さい JPEG/WebP を誤判定しないため)
        guard let handle = try? FileHandle(forReadingFrom: filePath) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count >= 4 else { return false }
        let b = [UInt8](head)
        return b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38
    }

    // MARK: - System handler

    /// 起動時: AppDelegateから呼び出される
    func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping () -> Void) {
        systemCompletionHandlers[identifier] = completionHandler
        if identifier == Self.nhSessionId {
            _ = nhSession
        } else if identifier == Self.ehSessionId {
            _ = ehSession
        }
    }
}

extension BackgroundDownloadManager: URLSessionDownloadDelegate {
    /// 進捗通知（foreground時のみ呼ばれる）: 速度計測用にバイトを累積
    /// registry 参照だけ stateQueue、増分は専用 NSLock でdelegate queue競合回避
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let taskId = downloadTask.taskIdentifier
        // SpeedTracker 更新 (task 単位の受信総量追跡)
        speedTracker.update(taskId: taskId, totalBytes: totalBytesWritten)
        let gidOpt: Int? = stateQueue.sync { registry[taskId]?.gid }
        guard let gid = gidOpt else { return }
        bytesLock.lock()
        bytesAccumulator[gid, default: 0] += bytesWritten
        cumulativeBytesReceived[gid, default: 0] += bytesWritten
        bytesLock.unlock()
    }

    /// リアルタイム表示用: DL開始以降に受信した累計バイト
    func totalBytesReceivedThisSession(for gid: Int) -> Int64 {
        bytesLock.lock()
        defer { bytesLock.unlock() }
        return cumulativeBytesReceived[gid, default: 0]
    }

    /// ギャラリー DL 開始時に呼ぶ: 累計バイトをリセット
    func resetCumulativeBytes(for gid: Int) {
        bytesLock.lock()
        cumulativeBytesReceived[gid] = 0
        bytesSampleTime[gid] = nil
        bytesLock.unlock()
    }

    /// gid の前回サンプル以降の受信バイト/秒を返し、累積をリセット
    /// 専用 NSLock のみで stateQueue を触らない→main thread が delegate queue と競合しない
    func sampleBytesPerSecond(for gid: Int) -> Int64 {
        bytesLock.lock()
        defer { bytesLock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        let bytes = bytesAccumulator[gid, default: 0]
        let last = bytesSampleTime[gid] ?? now
        let elapsed = max(now - last, 0.001)
        bytesAccumulator[gid] = 0
        bytesSampleTime[gid] = now
        return Int64(Double(bytes) / elapsed)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let taskId = downloadTask.taskIdentifier
        speedTracker.finish(taskId: taskId)

        // Single task path（互換）
        let single: (URL, CheckedContinuation<Bool, Never>)? = stateQueue.sync {
            let e = singleTaskContinuations.removeValue(forKey: taskId)
            return e
        }
        if let single {
            handleSingleTaskFinished(taskId: taskId, task: downloadTask, location: location, finalPath: single.0, continuation: single.1)
            return
        }

        // Batch task path
        let entry: TaskEntry? = stateQueue.sync {
            let e = registry.removeValue(forKey: taskId)
            return e
        }
        guard let entry else {
            LogManager.shared.log("bgdl", "finished taskId=\(taskId) but no registry entry")
            return
        }
        handleBatchTaskFinished(taskId: taskId, task: downloadTask, location: location, entry: entry)
    }

    private func handleSingleTaskFinished(taskId: Int, task: URLSessionDownloadTask, location: URL, finalPath: URL, continuation: CheckedContinuation<Bool, Never>) {
        if let httpResp = task.response as? HTTPURLResponse,
           !(200...299).contains(httpResp.statusCode) {
            LogManager.shared.log("bgdl", "http \(httpResp.statusCode) single \(finalPath.lastPathComponent)")
            continuation.resume(returning: false)
            return
        }
        do {
            if FileManager.default.fileExists(atPath: finalPath.path) {
                try FileManager.default.removeItem(at: finalPath)
            }
            let parent = finalPath.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try FileManager.default.moveItem(at: location, to: finalPath)
            continuation.resume(returning: true)
        } catch {
            LogManager.shared.log("bgdl", "move failed: \(error.localizedDescription) single")
            continuation.resume(returning: false)
        }
    }

    private func handleBatchTaskFinished(taskId: Int, task: URLSessionDownloadTask, location: URL, entry: TaskEntry) {
        var success = false
        var retriable = false

        if let httpResp = task.response as? HTTPURLResponse {
            // Cloudflare challenge 検出 (status code に関係なく優先判定)
            // CF は challenge page を 200/403/503 等 多様な status で返す可能性があり、
            // cf-mitigated: challenge ヘッダが付いたら「一時的な gate」として retriable 扱い。
            // 数秒後に解消されることが多いので即 retry で通過する想定。
            if let cfMitigated = httpResp.value(forHTTPHeaderField: "cf-mitigated"),
               cfMitigated.lowercased() == "challenge" {
                LogManager.shared.log("bgdl", "cloudflare challenge detected gid=\(entry.gid) page=\(entry.pageIndex) status=\(httpResp.statusCode)")
                retriable = true
                // challenge page の中身は画像じゃないので破棄
                try? FileManager.default.removeItem(at: location)
                emitCompletion(gid: entry.gid, pageIndex: entry.pageIndex, success: false, retriable: retriable)
                return
            }

            if !(200...299).contains(httpResp.statusCode) {
                LogManager.shared.log("bgdl", "http \(httpResp.statusCode) gid=\(entry.gid) page=\(entry.pageIndex)")
                retriable = httpResp.statusCode == 503 || httpResp.statusCode == 429
            } else {
                do {
                    if FileManager.default.fileExists(atPath: entry.finalPath.path) {
                        try FileManager.default.removeItem(at: entry.finalPath)
                    }
                    let parent = entry.finalPath.deletingLastPathComponent()
                    if !FileManager.default.fileExists(atPath: parent.path) {
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    }
                    try FileManager.default.moveItem(at: location, to: entry.finalPath)
                    if Self.isValidImageFile(at: entry.finalPath) {
                        // 509 警告 GIF 検出 (Hath 帯域制限時の E-H ガード画像)
                        // マジックバイトは valid GIF なので追加判定、該当なら retriable
                        if Self.looksLike509Warning(url: task.originalRequest?.url, filePath: entry.finalPath) {
                            let urlTail = task.originalRequest?.url?.absoluteString.suffix(80) ?? ""
                            LogManager.shared.log("bgdl", "509 warning gif detected gid=\(entry.gid) page=\(entry.pageIndex) url=...\(urlTail)")
                            try? FileManager.default.removeItem(at: entry.finalPath)
                            retriable = true
                        } else {
                            success = true
                        }
                    } else {
                        try? FileManager.default.removeItem(at: entry.finalPath)
                        LogManager.shared.log("bgdl", "invalid image gid=\(entry.gid) page=\(entry.pageIndex)")
                        retriable = true
                    }
                } catch {
                    LogManager.shared.log("bgdl", "move failed gid=\(entry.gid) page=\(entry.pageIndex): \(error.localizedDescription)")
                }
            }
        } else {
            // レスポンスなし = ネットワークエラー系
            retriable = true
        }

        emitCompletion(gid: entry.gid, pageIndex: entry.pageIndex, success: success, retriable: retriable)
    }

    private func emitCompletion(gid: Int, pageIndex: Int, success: Bool, retriable: Bool) {
        let continuation: AsyncStream<PageCompletion>.Continuation? = stateQueue.sync {
            return gidStreams[gid]
        }
        if continuation == nil {
            LogManager.shared.log("bgdl", "DROPPED completion: no stream for gid=\(gid) page=\(pageIndex) success=\(success)")
        }
        continuation?.yield(PageCompletion(pageIndex: pageIndex, success: success, retriable: retriable))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskId = task.taskIdentifier
        speedTracker.finish(taskId: taskId)

        // Single task path
        let single: (URL, CheckedContinuation<Bool, Never>)? = stateQueue.sync {
            return singleTaskContinuations.removeValue(forKey: taskId)
        }
        if let single {
            LogManager.shared.log("bgdl", "single task error taskId=\(taskId): \(error.localizedDescription)")
            single.1.resume(returning: false)
            return
        }

        // Batch task path
        let entry: TaskEntry? = stateQueue.sync {
            return registry.removeValue(forKey: taskId)
        }
        if let entry {
            LogManager.shared.log("bgdl", "batch error gid=\(entry.gid) page=\(entry.pageIndex): \(error.localizedDescription)")
            emitCompletion(gid: entry.gid, pageIndex: entry.pageIndex, success: false, retriable: true)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? ""
        let handler = systemCompletionHandlers.removeValue(forKey: identifier)
        DispatchQueue.main.async {
            handler?()
        }
        LogManager.shared.log("bgdl", "session events done: \(identifier)")
    }
}

/// 各 DL task の受信バイト量と進捗時刻を追跡し、低速/停止を検出して早期 cancel する
/// 既存の stream stall watchdog (DownloadManager 側、completion 到達を監視) とはスコープ独立:
/// SpeedTracker は 1 task 内の実速度を見る、stream watchdog は task 群全体の progress 間隔を見る。
/// Kill 発動時は URLSessionTask.cancel() → didCompleteWithError 経由で retriable=true 通知
/// → 既存 2ndpass 回送フローに乗る (ダブルキル無し)
final class SpeedTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var trackers: [Int: Tracker] = [:]

    private struct Tracker {
        weak var task: URLSessionTask?
        var lastBytes: Int64
        var lastProgressAt: CFAbsoluteTime
        var startedAt: CFAbsoluteTime
        /// 直近 30 秒以内のサンプル (時刻, 累計バイト)
        var samples: [(time: CFAbsoluteTime, bytes: Int64)]
    }

    /// 追跡開始 (enqueue / downloadToFile 時)
    func start(taskId: Int, task: URLSessionTask) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        trackers[taskId] = Tracker(
            task: task,
            lastBytes: 0,
            lastProgressAt: now,
            startedAt: now,
            samples: [(now, 0)]
        )
    }

    /// 進捗通知 (didWriteData から呼ぶ)
    func update(taskId: Int, totalBytes: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        guard var t = trackers[taskId] else { return }
        if totalBytes > t.lastBytes {
            t.lastBytes = totalBytes
            t.lastProgressAt = now
        }
        t.samples.append((now, totalBytes))
        // 直近 30 秒より古いサンプルは破棄 (メモリ保全)
        let cutoff = now - 30
        t.samples.removeAll { $0.time < cutoff }
        trackers[taskId] = t
    }

    /// 追跡終了 (完了/エラー/cancel 後)
    func finish(taskId: Int) {
        lock.lock(); defer { lock.unlock() }
        trackers.removeValue(forKey: taskId)
    }

    /// 全 task を評価、kill すべきなら task.cancel() 発動
    /// 返り値: (taskId, 理由) のリスト
    func evaluateAndCancel() -> [(taskId: Int, reason: String)] {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let snapshot = trackers
        lock.unlock()

        var killed: [(Int, String)] = []
        for (taskId, t) in snapshot {
            guard let reason = Self.killReason(tracker: t, now: now) else { continue }
            t.task?.cancel()
            killed.append((taskId, reason))
            // finish は didCompleteWithError で呼ばれるのでここでは解除しない
        }
        return killed
    }

    /// kill 条件判定 (静的ロジック、副作用なし)
    /// - 進捗停止 20秒超 = 純粋 stall
    /// - 直近 30秒以上のサンプル平均が 100 B/s 未満 = 低速すぎ
    private static func killReason(tracker t: Tracker, now: CFAbsoluteTime) -> String? {
        let noProgress = now - t.lastProgressAt
        if noProgress > 20 {
            return "no progress for \(Int(noProgress))s"
        }
        if let oldest = t.samples.first, let newest = t.samples.last {
            let timeDelta = newest.time - oldest.time
            let bytesDelta = newest.bytes - oldest.bytes
            if timeDelta >= 30 {
                let bytesPerSec = Double(bytesDelta) / timeDelta
                if bytesPerSec < 100 {
                    return "slow \(Int(bytesPerSec))B/s over \(Int(timeDelta))s"
                }
            }
        }
        return nil
    }
}
