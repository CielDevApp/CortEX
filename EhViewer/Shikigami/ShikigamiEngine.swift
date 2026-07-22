import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 打電エンジン (singleton)
//
// 封じ込め設計 (指示書§1): ランタイムゲート方式。
//   - gateProvider (= CORTEX PROTOCOL のデバッグモード) が false → 完全休眠。
//     タイマーも走らない、UDP ソケットも開かない、CPU ゼロ。
//   - destinationProvider が空 → 打電しない (弾が飛ばない)。
// コンパイルフラグ (#if) は使わない — Code のビルド構成ミスに不感症にするため。
//
// Package 化を見越し (指示書§6)、EhViewer 固有の型 (UDKey/BuildInfo/DownloadManager) を
// 直接参照せず provider closure で注入する。engine 自身は汎用 (Foundation/UIKit のみ)。

final class ShikigamiEngine {
    static let shared = ShikigamiEngine()
    private let udp = ShikigamiUDP()
    private(set) var running = false

    // --- 注入ポイント (EhViewer 側が設定) ---
    /// デバッグモード (CORTEX PROTOCOL) が有効か。false なら完全休眠。
    var gateProvider: (() -> Bool)?
    /// 打電先 "IP:port"。空なら打電しない。ハードコード禁止のため provider。
    var destinationProvider: (() -> String)?
    /// 蔵書件数 (弾①③)。
    var libraryCountProvider: (() -> Int)?
    /// ビルド識別 (弾①、git short hash 等)。
    var buildVersionProvider: (() -> String)?
    /// 画質/トグル状態の1行スナップショット (弾②③、例 "q2ai1")。EhViewer 側が UserDefaults から注入。
    var settingsProvider: (() -> String)?
    /// 現在画面名 (弾②③)。各主要 View が onAppear で set、onDisappear で clearScreen。
    var currentScreen = "unknown"
    /// リーダー等が閉じた時、自分がセットした画面名を渡すと unknown へ戻す (固着防止)。
    func clearScreen(_ name: String) { if currentScreen == name { currentScreen = "unknown" } }

    private var gateOpen: Bool { gateProvider?() ?? false }
    private var destination: String { destinationProvider?() ?? "" }

    // Phase 2 タイマー/購読/ピーク
    private var memTimer: DispatchSourceTimer?
    private var decodeTimer: DispatchSourceTimer?
    private var memWarnObserver: NSObjectProtocol?
    private var peakUsedMB = 0

    /// デバッグモード ON 初期化から呼ぶ。ゲート閉 or 送信先空なら stop 相当で何もしない。
    func start() {
        guard gateOpen, !destination.isEmpty else { stop(); return }
        guard !running else { return }
        udp.open(destination: destination)
        running = true
        peakUsedMB = usedMB()
        sendPost()              // 弾①
        startMemoryPolling()    // 弾②
        startDecodeReporting()  // 弾④
        observeMemoryWarning()  // 弾③
    }

    func stop() {
        memTimer?.cancel(); memTimer = nil
        decodeTimer?.cancel(); decodeTimer = nil
        if let o = memWarnObserver {
            NotificationCenter.default.removeObserver(o)
            memWarnObserver = nil
        }
        udp.close()
        running = false
    }

    // 弾① POST CORTEX <bundleID> <buildVersion> <蔵書件数> <deviceName>
    // bundleID はバイナリ自身が読む値 (Bundle.main) — 取り違えようがない。
    /// 任意 KEIHO 打電 (2026-07-22: ZOMBIE displayLink 等、アプリ内で検知した異常を
    /// 言上帳へ自動還流するための汎用口。gate 閉/打電先未設定なら無音)。
    func keihoCustom(_ body: String) {
        guard running else { return }
        udp.send("KEIHO \(ShikigamiConfig.appTag) \(body)")
    }

    private func sendPost() {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let build = buildVersionProvider?() ?? "unknown"
        let count = libraryCountProvider?() ?? -1
        udp.send("POST \(ShikigamiConfig.appTag) \(bundleID) \(build) \(count) \(deviceName())")
    }

    private func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name.replacingOccurrences(of: " ", with: "_")
        #else
        return "mac"
        #endif
    }

    // MARK: - 弾② メモリ打電 (5秒毎)
    // MEM CORTEX <availableMB> <usedMB> <currentScreen> <decodeCount> <settings>
    private func startMemoryPolling() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + ShikigamiConfig.memoryPollInterval,
                   repeating: ShikigamiConfig.memoryPollInterval)
        t.setEventHandler { [weak self] in self?.sendMem() }
        t.resume()
        memTimer = t
    }
    private func sendMem() {
        let used = usedMB()
        peakUsedMB = max(peakUsedMB, used)
        let decoding = ShikigamiDecodeTracker.shared.activeCount
        udp.send("MEM \(ShikigamiConfig.appTag) \(availableMB()) \(used) \(currentScreen) \(decoding) \(settingsProvider?() ?? "-")")
    }

    // MARK: - 弾③ MemoryWarning (即時)
    // KEIHO CORTEX MEMWARN <availableMB> <currentScreen> <libraryCount> <decodeCount> <settings>
    private func observeMemoryWarning() {
        #if canImport(UIKit)
        memWarnObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.handleMemoryWarning() }
        #endif
    }
    private func handleMemoryWarning() {
        guard running else { return }
        let lib = libraryCountProvider?() ?? -1
        let decoding = ShikigamiDecodeTracker.shared.activeCount
        udp.send("KEIHO \(ShikigamiConfig.appTag) MEMWARN \(availableMB()) \(currentScreen) \(lib) \(decoding) \(settingsProvider?() ?? "-")")
    }

    // MARK: - 弾④ decode 統計 (60秒毎)
    // REPORT CORTEX DECODE <total> <avgMs> <cacheHitRate> <peakMB>
    private func startDecodeReporting() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + ShikigamiConfig.decodeReportInterval,
                   repeating: ShikigamiConfig.decodeReportInterval)
        t.setEventHandler { [weak self] in self?.sendDecodeReport() }
        t.resume()
        decodeTimer = t
    }
    private func sendDecodeReport() {
        let s = ShikigamiDecodeTracker.shared.drain()
        let peak = peakUsedMB
        peakUsedMB = usedMB()
        udp.send("REPORT \(ShikigamiConfig.appTag) DECODE \(s.total) "
                 + String(format: "%.1f", s.avgMs) + " "
                 + String(format: "%.2f", s.hitRate) + " \(peak)")
    }

    // MARK: - メモリ計測 (汎用)
    private func availableMB() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory() / (1024 * 1024))
        #else
        return -1
        #endif
    }
    private func usedMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / (1024 * 1024)) : -1
    }
}
