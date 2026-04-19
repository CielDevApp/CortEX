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

final class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published var logs: [LogEntry] = []
    private let maxEntries = 1000
    private var deviceInfoLogged = false

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "debugLogEnabled")
    }

    /// 実行端末情報を取得
    static var deviceSignature: String {
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

    func log(_ category: String, _ message: String) {
        // 初回ログ時に端末情報 + ビルドタグを先に出力
        if !deviceInfoLogged {
            deviceInfoLogged = true
            let sig = Self.deviceSignature
            print("[Device] \(sig)")
            print("[Build] \(BuildInfo.tag)")
            if isEnabled {
                let dev = LogEntry(timestamp: Date(), category: "Device", message: sig)
                let build = LogEntry(timestamp: Date(), category: "Build", message: BuildInfo.tag)
                DispatchQueue.main.async {
                    self.logs.append(dev)
                    self.logs.append(build)
                }
            }
        }
        // 常にprint（Xcodeコンソール用）
        print("[\(category)] \(message)")

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
    static func deviceModelName() -> String? {
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
