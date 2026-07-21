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
    /// 打電先 "IP:port"。空なら打電しない。ハードコード禁止のためここも provider。
    var destinationProvider: (() -> String)?
    /// 蔵書件数 (弾①)。
    var libraryCountProvider: (() -> Int)?
    /// ビルド識別 (弾①、git short hash 等)。
    var buildVersionProvider: (() -> String)?

    private var gateOpen: Bool { gateProvider?() ?? false }
    private var destination: String { destinationProvider?() ?? "" }

    /// デバッグモード ON 初期化から呼ぶ。ゲート閉 or 送信先空なら stop 相当で何もしない。
    func start() {
        guard gateOpen, !destination.isEmpty else { stop(); return }
        guard !running else { return }
        udp.open(destination: destination)
        running = true
        sendPost()   // 弾① 起動時1回
    }

    func stop() {
        udp.close()
        running = false
    }

    // 弾① POST CORTEX <bundleID> <buildVersion> <蔵書件数> <deviceName>
    // bundleID はバイナリ自身が読む値 (Bundle.main) — Code の宣言でなく取り違えようがない。
    private func sendPost() {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let build = buildVersionProvider?() ?? "unknown"
        let count = libraryCountProvider?() ?? -1
        let device = deviceName()
        udp.send("POST \(ShikigamiConfig.appTag) \(bundleID) \(build) \(count) \(device)")
    }

    private func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name.replacingOccurrences(of: " ", with: "_")
        #else
        return "mac"
        #endif
    }
}
