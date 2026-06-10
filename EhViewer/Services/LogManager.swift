import Foundation
import Combine
import MachO
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

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "debugLogEnabled")
    }

    /// フォーマット済み1行をファイル末尾に append
    private func appendToFile(_ line: String) {
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

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

/// main thread の停滞検出 (2026-06-10 スクロールヒッチ定量化用)。
/// v2 (CADisplayLink 版): 旧実装 (DispatchSourceTimer) は UIScrollView スクロール中に
/// main が暇でも GCD main キューの配送が遅れて 200ms 級の偽 stall を量産した
/// (Time Profiler 実測: スクロール 50 秒で main busy 0.25 秒なのに stall 90 件超)。
/// CADisplayLink は common modes で毎フレーム発火するため、コールバック間隔の開き =
/// 本当に描画フレームが落ちた証拠になる。
final class MainStallMonitor {
    static let shared = MainStallMonitor()
    #if canImport(UIKit)
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        // BlockSampler の凍結検知用 (CFAbsoluteTime 系で統一)
        MainBlockSampler.lastFrameTick = CFAbsoluteTimeGetCurrent()
        let now = l.timestamp
        defer { last = now }
        guard last > 0 else { return }
        let gap = now - last
        // 50ms 超から記録 (スクロールゴール第二基準「30秒で50ms超5回以内」の計測用、
        // 2026-06-10 閾値引き下げ)。バックグラウンド復帰の巨大値は無視。
        if gap > 0.05 && gap < 10 {
            LogManager.shared.log("MainStall", "\(Int(gap * 1000))ms")
        }
    }
    #else
    func start() {}
    #endif
}

// MARK: - Main thread block sampler (診断用 2026-06-10)

/// main thread が凍結 (>120ms) した瞬間に、背景スレッドから main を一時 suspend して
/// コールスタック (生アドレス + 画像名+オフセット) を採取する。CPU を使わない「待ち」
/// ブロック (ロック/セマフォ/同期IPC) は Time Profiler に写らないため、この方式でのみ
/// 特定できる。stall 1 回につき 1 サンプル、ログタグ [BlockSample]。
final class MainBlockSampler {
    static let shared = MainBlockSampler()
    /// CADisplayLink (MainStallMonitor) が毎フレーム更新する最終 tick 時刻
    static var lastFrameTick: CFAbsoluteTime = 0
    private var mainThreadPort: thread_act_t = 0
    private var started = false

    /// main thread から呼ぶこと (main の mach port を捕まえるため)
    func start() {
        guard !started, Thread.isMainThread else { return }
        started = true
        mainThreadPort = mach_thread_self()
        Self.lastFrameTick = CFAbsoluteTimeGetCurrent()
        let port = mainThreadPort
        Thread.detachNewThread {
            Thread.current.name = "MainBlockSampler"
            var lastSampleAt: CFAbsoluteTime = 0
            while true {
                usleep(30_000) // 30ms
                let now = CFAbsoluteTimeGetCurrent()
                let gap = now - Self.lastFrameTick
                // 55ms 凍結から採取 (第二基準 50ms 帯の犯人特定用に 120ms から引き下げ、
                // 2026-06-10)。ポーリング 30ms なので 50-80ms 帯も概ね捕まる。
                if gap > 0.055 && gap < 5 && now - lastSampleAt > 0.5 {
                    lastSampleAt = now
                    Self.sampleAndLog(port: port, gapMs: Int(gap * 1000))
                }
            }
        }
    }

    private static func sampleAndLog(port: thread_act_t, gapMs: Int) {
        guard thread_suspend(port) == KERN_SUCCESS else { return }
        var addrs: [UInt64] = []
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let kr = withUnsafeMutablePointer(to: &state) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let pacMask: UInt64 = 0x0000_007F_FFFF_FFFF
            addrs.append(state.__pc & pacMask)
            addrs.append(state.__lr & pacMask)
            // fp チェーンを安全に辿る (vm_read_overwrite で読めないアドレスは打ち切り)
            var fp = state.__fp & pacMask
            for _ in 0..<24 {
                guard fp > 0x1000 else { break }
                var buf = [UInt64](repeating: 0, count: 2)
                var outSize: vm_size_t = 0
                let r = buf.withUnsafeMutableBytes { raw -> kern_return_t in
                    vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16,
                                      vm_address_t(UInt(bitPattern: raw.baseAddress)), &outSize)
                }
                guard r == KERN_SUCCESS, outSize == 16 else { break }
                let nextFP = buf[0] & pacMask
                let lr = buf[1] & pacMask
                if lr > 0x100000000 { addrs.append(lr) }
                guard nextFP > fp else { break }
                fp = nextFP
            }
        }
        thread_resume(port)

        // アドレス → 画像名+オフセット (システムフレームはこれで関数の在処が分かる)
        var lines: [String] = []
        let imageCount = _dyld_image_count()
        for a in addrs {
            var best: (name: String, off: UInt64)? = nil
            for i in 0..<imageCount {
                guard let header = _dyld_get_image_header(i) else { continue }
                let base = UInt64(UInt(bitPattern: header))
                if a >= base, a - base < 0x8000_0000 {
                    if best == nil || (a - base) < best!.off {
                        let name = String(cString: _dyld_get_image_name(i))
                        best = ((name as NSString).lastPathComponent, a - base)
                    }
                }
            }
            if let b = best {
                lines.append("\(b.name)+0x\(String(b.off, radix: 16))")
            } else {
                lines.append("0x\(String(a, radix: 16))")
            }
        }
        let appBase = UInt64(UInt(bitPattern: _dyld_get_image_header(0)))
        LogManager.shared.log("BlockSample", "gap=\(gapMs)ms appBase=0x\(String(appBase, radix: 16)) stack: " + lines.joined(separator: " <- "))
    }
}
