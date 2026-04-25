import Foundation
import Combine

/// CUI から reader を直接開くための request。`fullScreenCover(item:)` 経由で表示する。
struct CortexOpenReaderRequest: Identifiable, Equatable {
    let id = UUID()
    let gid: Int
    let token: String
    let page: Int
    /// "exhentai" / "ehentai"。HTML scheme は GalleryHost で扱う。
    let hostName: String
}

/// CUI から local reader を開くための request (DL 済みの作品向け)。
struct CortexOpenLocalReaderRequest: Identifiable, Equatable {
    let id = UUID()
    let gid: Int
    let page: Int
}

/// SwiftUI view が観察する CUI command bus。CortexURLRouter から `@Published` を書き換えると
/// ContentView の `.fullScreenCover(item:)` が反応して reader が開く。
final class CortexCommandBus: ObservableObject {
    static let shared = CortexCommandBus()
    @Published var openOnlineReader: CortexOpenReaderRequest?
    @Published var openLocalReader: CortexOpenLocalReaderRequest?
    private init() {}
}

/// `cortex://` URL scheme で外部 (CLI 等) からアプリの動作を制御するための router。
/// AppleScript/UI 自動化が SwiftUI で動かないので、bash から `open "cortex://..."` で
/// debug action を発火する仕組み (田中指示 2026-04-25「CUI から自由に操作できる仕組み」)。
///
/// 既存の機能は触らず additive のみ (非破壊)。新 scheme `cortex://` を Info.plist で登録、
/// ContentView の onOpenURL で scheme 判定して dispatch。
///
/// ## サポート action
/// - `cortex://debug/marker?text=hello` → ログに `[Marker] hello` 追記
/// - `cortex://debug/dump-state` → 現在のアプリ状態 (paths, sizes 等) を log に dump
/// - `cortex://action/cache-clear` → ImageCache + animated_cache を削除
/// - `cortex://action/log-rotate` → ehviewer.log を rotate (旧 → .old)
/// - `cortex://reader/online?gid=X&token=Y&page=Z[&host=exhentai|ehentai]` → online reader 開く
/// - `cortex://reader/local?gid=X&page=Y` → local reader 開く (DL 済み作品)
/// - `cortex://reader/close` → 開いている cortex 経由 reader を閉じる
/// - `cortex://search?q=...` → 検索 keyword 通知 (GalleryListView 等が NotificationCenter で受信)
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
        case "reader/online":
            return openOnlineReader(params: params)
        case "reader/local":
            return openLocalReader(params: params)
        case "reader/close":
            DispatchQueue.main.async {
                CortexCommandBus.shared.openOnlineReader = nil
                CortexCommandBus.shared.openLocalReader = nil
            }
            LogManager.shared.log("CortexURL", "reader closed")
            return true
        case "search":
            let q = params["q"] ?? ""
            NotificationCenter.default.post(name: .cortexSearch, object: q)
            LogManager.shared.log("CortexURL", "search posted q=\(q)")
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

    private static func openOnlineReader(params: [String: String]) -> Bool {
        guard let gidStr = params["gid"], let gid = Int(gidStr),
              let token = params["token"], !token.isEmpty else {
            LogManager.shared.log("CortexURL", "online reader: missing gid/token")
            return false
        }
        let page = Int(params["page"] ?? "0") ?? 0
        let hostName = params["host"] ?? "exhentai"
        let req = CortexOpenReaderRequest(gid: gid, token: token, page: page, hostName: hostName)
        DispatchQueue.main.async {
            CortexCommandBus.shared.openOnlineReader = req
        }
        LogManager.shared.log("CortexURL", "online reader request gid=\(gid) page=\(page) host=\(hostName)")
        return true
    }

    private static func openLocalReader(params: [String: String]) -> Bool {
        guard let gidStr = params["gid"], let gid = Int(gidStr) else {
            LogManager.shared.log("CortexURL", "local reader: missing gid")
            return false
        }
        let page = Int(params["page"] ?? "0") ?? 0
        let req = CortexOpenLocalReaderRequest(gid: gid, page: page)
        DispatchQueue.main.async {
            CortexCommandBus.shared.openLocalReader = req
        }
        LogManager.shared.log("CortexURL", "local reader request gid=\(gid) page=\(page)")
        return true
    }
}

extension Notification.Name {
    static let cortexSearch = Notification.Name("cortexSearch")
}
