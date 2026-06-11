import Foundation
import Combine
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: String
    let message: String

    var timeString: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// isolation 方針 (A2-c, 2026-06-11):
/// - 型としては @MainActor (UI が観察する @Published logs / CADisplayLink frame monitor)
/// - log() / appendToFile() は「あらゆるスレッドから呼ばれて呼び出し元スレッドで動く」
///   のが既存契約なので nonisolated。logs への反映は従来通り main へホップ。
/// - ファイル書込は fileQueue 直列で保護 (従来のまま)。
@MainActor
final class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published var logs: [LogEntry] = []
    private let maxEntries = 1000
    /// 初回ログ判定。nonisolated な log() から無保護アクセス (従来の暗黙時代と同じ。
    /// 最悪でも Device/Build 行の重複出力どまりなので許容)
    nonisolated(unsafe) private var deviceInfoLogged = false

    /// ファイル書き出し用キュー + パス
    private let fileQueue = DispatchQueue(label: "logmanager.file", qos: .utility)
    private lazy var logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("ehviewer.log")
        // 起動時に前回ログをクリア（太りすぎ防止）
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }()
    /// 外部から log パス取得（デバッグ用）
    static var currentLogPath: String { shared.logFileURL.path }

    nonisolated var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: UDKey.debugLogEnabled)
    }

    /// フォーマット済み1行をファイル末尾に append (どのスレッドからでも可、書込は fileQueue 直列)
    nonisolated private func appendToFile(_ line: String) {
        fileQueue.async { [weak self] in
            guard let self else { return }
            guard let data = (line + "\n").data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: self.logFileURL) else {
                return
            }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    /// DateFormatter は iOS 7+ でスレッドセーフ。nonisolated な log() から使うため (unsafe) 明示
    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 実行端末情報を取得
    nonisolated static var deviceSignature: String {
        #if canImport(UIKit)
        let device = UIDevice.current
        let modelName = UIDevice.deviceModelName() ?? device.model
        return "\(modelName) \(device.systemName) \(device.systemVersion)"
        #elseif canImport(AppKit)
        return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        return "Unknown"
        #endif
    }

    /// どのスレッドから呼んでも呼び出し元スレッドで実行される (既存契約の明示化)。
    /// @Published logs への反映だけ main へホップ。
    nonisolated func log(_ category: String, _ message: String) {
        // 初回ログ時に端末情報 + ビルドタグを先に出力
        if !deviceInfoLogged {
            deviceInfoLogged = true
            let sig = Self.deviceSignature
            print("[Device] \(sig)")
            print("[Build] \(BuildInfo.tag)")
            appendToFile("[Device] \(sig)")
            appendToFile("[Build] \(BuildInfo.tag)")
            if isEnabled {
                let dev = LogEntry(timestamp: Date(), category: "Device", message: sig)
                let build = LogEntry(timestamp: Date(), category: "Build", message: BuildInfo.tag)
                DispatchQueue.main.async {
                    self.logs.append(dev)
                    self.logs.append(build)
                }
            }
        }
        // per-line の print() は廃止 (2026-06-10): 実機の stdout は OS ログパイプ同期書込で
        // main をブロックし得るリスクの割に、実運用のログ確認は全てファイル経由 (devicectl pull)。
        // Xcode コンソールが必要な場合のみ一時的に復活させること。
        // print("[\(category)] \(message)")
        let timeStr = Self.timeFormatter.string(from: Date())
        appendToFile("[\(timeStr)] [\(category)] \(message)")

        guard isEnabled else { return }

        let entry = LogEntry(timestamp: Date(), category: category, message: message)
        DispatchQueue.main.async {
            self.logs.append(entry)
            if self.logs.count > self.maxEntries {
                self.logs.removeFirst(self.logs.count - self.maxEntries)
            }
        }
    }

    func clear() {
        logs.removeAll()
    }

    // MARK: - Frame Drop Monitor

    #if canImport(UIKit)
    private var frameLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameDropCount = 0
    private var goodFrameCount = 0

    func startFrameMonitor() {
        guard isEnabled, frameLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frameCallback))
        link.add(to: .main, forMode: .common)
        frameLink = link
        lastFrameTime = 0
        log("Perf", "frameMonitor: started")
    }

    func stopFrameMonitor() {
        frameLink?.invalidate()
        frameLink = nil
        if frameDropCount > 0 || goodFrameCount > 0 {
            log("Perf", "frameMonitor: stopped (drops=\(frameDropCount) good=\(goodFrameCount))")
        }
        frameDropCount = 0
        goodFrameCount = 0
    }

    @objc private func frameCallback(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            let fps = 1.0 / dt
            if dt > 0.025 { // 40fps未満 = ドロップ
                frameDropCount += 1
                log("Perf", "frameDrop: \(Int(fps))fps (\(Int(dt * 1000))ms) drops=\(frameDropCount)")
            } else {
                goodFrameCount += 1
            }
        }
        lastFrameTime = now
    }
    #endif

    func allText() -> String {
        let header = "[Device] \(Self.deviceSignature)"
        let body = logs.map { "[\($0.timeString)] [\($0.category)] \($0.message)" }.joined(separator: "\n")
        return "\(header)\n\(body)"
    }
}

#if canImport(UIKit)
extension UIDevice {
    /// sysctl から hw.machine (e.g. "iPhone14,5", "iPad14,1") を取得して、
    /// 可能なら可読モデル名に変換
    nonisolated static func deviceModelName() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0)
            }
        }
        return identifier
    }
}
#endif
