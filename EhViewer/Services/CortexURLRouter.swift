import Foundation

/// `cortex://` URL scheme で外部 (CLI 等) からアプリの動作を制御するための router。
/// AppleScript/UI 自動化が SwiftUI で動かないので、bash から `open "cortex://..."` で
/// debug action を発火する仕組み (田中指示 2026-04-25「CUI から自由に操作できる仕組み」)。
///
/// 既存の機能は触らず additive のみ (非破壊)。新 scheme `cortex://` を Info.plist で登録、
/// ContentView の onOpenURL で scheme 判定して dispatch。
///
/// ## 使い方
/// - `cortex://debug/marker?text=hello` → ログに `[Marker] hello` 追記
/// - `cortex://debug/dump-state` → 現在のアプリ状態 (paths, sizes 等) を log に dump
/// - `cortex://action/cache-clear` → ImageCache + animated_cache を削除
/// - `cortex://action/log-rotate` → ehviewer.log を rotate (旧 → .old)
enum CortexURLRouter {
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "cortex" else { return false }
        let host = url.host ?? ""
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let key = path.isEmpty ? host : "\(host)/\(path)"
        let params = parseQuery(url)

        LogManager.shared.log("CortexURL", "received key=\(key) params=\(params)")

        switch key {
        case "debug/marker":
            let text = params["text"] ?? ""
            LogManager.shared.log("Marker", text)
            return true
        case "debug/dump-state":
            dumpState()
            return true
        case "action/cache-clear":
            clearCache()
            return true
        case "action/log-rotate":
            rotateLog()
            return true
        default:
            LogManager.shared.log("CortexURL", "unknown action: \(key)")
            return false
        }
    }

    private static func parseQuery(_ url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return [:] }
        var dict: [String: String] = [:]
        for item in items { dict[item.name] = item.value ?? "" }
        return dict
    }

    private static func dumpState() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cacheDir = docs.appendingPathComponent("EhViewer/cache")
        let animCacheDir = docs.appendingPathComponent("animated_cache")
        let downloadsDir = docs.appendingPathComponent("EhViewer/downloads")

        var lines: [String] = ["--- STATE DUMP ---"]
        lines.append("docs=\(docs.path)")
        lines.append("cache=\(dirSize(cacheDir))B exists=\(fm.fileExists(atPath: cacheDir.path))")
        lines.append("animCache=\(dirSize(animCacheDir))B exists=\(fm.fileExists(atPath: animCacheDir.path))")
        lines.append("downloads=\(dirSize(downloadsDir))B exists=\(fm.fileExists(atPath: downloadsDir.path))")
        for line in lines {
            LogManager.shared.log("State", line)
        }
    }

    private static func dirSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in it {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func clearCache() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: docs.appendingPathComponent("EhViewer/cache"))
        try? fm.removeItem(at: docs.appendingPathComponent("animated_cache"))
        LogManager.shared.log("CortexURL", "cache cleared (EhViewer/cache + animated_cache)")
    }

    private static func rotateLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cur = docs.appendingPathComponent("ehviewer.log")
        let old = docs.appendingPathComponent("ehviewer.log.old")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: cur, to: old)
        LogManager.shared.log("CortexURL", "log rotated (.log → .log.old)")
    }
}
