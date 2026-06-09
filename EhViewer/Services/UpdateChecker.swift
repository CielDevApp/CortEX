import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// アプリの現在リリース版。GitHub の release tag と一致させる。
/// release-ios.sh が IPA ビルド時にこの値を当該タグへ自動同期する (手動更新不要)。
enum AppVersion {
    static let releaseTag = "v02a-f21"
    static var displayName: String {
        "Cort:EX " + releaseTag.replacingOccurrences(of: "v02a-f", with: "ver.02a f")
    }
    /// 比較用の数値。"v02a-f11.1" → 11.1 / "v02a-f15" → 15
    static var number: Double { parse(releaseTag) }
    static func parse(_ tag: String) -> Double {
        guard let r = tag.range(of: "f", options: .backwards) else { return 0 }
        let s = tag[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(s) ?? 0
    }
}

struct UpdateInfo {
    let tag: String
    let url: URL
    var isNewer: Bool { AppVersion.parse(tag) > AppVersion.number }
}

/// GitHub Releases の最新版を確認する。プッシュ通知や常駐は使わない軽量ポーリング。
enum UpdateChecker {
    private static let disabledKey = "updateCheckDisabled"
    private static let skippedKey = "updateSkippedTag"

    static var isDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: disabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: disabledKey) }
    }
    static func skip(_ tag: String) { UserDefaults.standard.set(tag, forKey: skippedKey) }
    static func isSkipped(_ tag: String) -> Bool {
        UserDefaults.standard.string(forKey: skippedKey) == tag
    }

    /// GitHub Releases の最新を取得 (失敗時 nil)。public repo なので認証不要。
    static func fetchLatest() async -> UpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/CielDevApp/CortEX/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        let html = (json["html_url"] as? String).flatMap { URL(string: $0) }
            ?? URL(string: "https://github.com/CielDevApp/CortEX/releases/latest")!
        return UpdateInfo(tag: tag, url: html)
    }

    @MainActor static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

/// 起動時の自動アップデート確認ダイアログ。ContentView に .modifier で適用。
struct UpdateCheckModifier: ViewModifier {
    @State private var info: UpdateInfo?
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .task {
                guard !UpdateChecker.isDisabled else { return }
                if let i = await UpdateChecker.fetchLatest(), i.isNewer, !UpdateChecker.isSkipped(i.tag) {
                    info = i
                    show = true
                }
            }
            .alert("新しいバージョンがあります", isPresented: $show, presenting: info) { i in
                Button("リリースを開く") { UpdateChecker.open(i.url) }
                Button("このバージョンをスキップ") { UpdateChecker.skip(i.tag) }
                Button("二度と確認しない", role: .destructive) { UpdateChecker.isDisabled = true }
                Button("後で", role: .cancel) {}
            } message: { i in
                Text("\(i.tag) が公開されています。\n現在: \(AppVersion.releaseTag)")
            }
    }
}
