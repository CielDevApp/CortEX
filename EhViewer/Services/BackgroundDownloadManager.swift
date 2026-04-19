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

    var nhSession: URLSession {
        if let s = _nhSession { return s }
        let config = URLSessionConfiguration.background(withIdentifier: Self.nhSessionId)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = true
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _nhSession = s
        return s
    }

    var ehSession: URLSession {
        if let s = _ehSession { return s }
        let config = URLSessionConfiguration.background(withIdentifier: Self.ehSessionId)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = true
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

    /// アプリ復帰時にシステムから受け取るcompletionHandler
    var systemCompletionHandlers: [String: () -> Void] = [:]

    private override init() {
        super.init()
        // 起動時に前回の残骸 task をクリーンアップ
        Task.detached(priority: .utility) { [weak self] in
            await self?.cleanupStaleTasks()
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
        task.resume()
    }

    /// gidのストリームを強制終了（watchdogからfor-awaitを抜けさせる用）
    func finishStream(for gid: Int) {
        stateQueue.sync {
            gidStreams[gid]?.finish()
            gidStreams.removeValue(forKey: gid)
        }
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
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let taskId = downloadTask.taskIdentifier

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
                        success = true
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
        continuation?.yield(PageCompletion(pageIndex: pageIndex, success: success, retriable: retriable))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskId = task.taskIdentifier

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
