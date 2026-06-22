import Foundation

/// 購読リスト + device token を M2 (nas / ReCap機) のポーラーに自動同期する (Phase 3.5)。
/// M2 の sync サーバー (~/cortex-poller/sync-server.py) が受けて subscriptions.json /
/// devices.json を更新 → 30分おきポーラーが常に最新の購読を見る。Tailscale 経由。
/// ⚠️ 個人版専用 (personal-notify ブランチ)。配布版 main には存在しない。
enum SubscriptionSync {
    /// M2 (nas) の Tailscale IP + sync サーバーポート。
    static let endpoint = "http://100.82.192.113:8765/sync"
    /// 共有シークレット (Tailscale 内の sync エンドポイント保護用。個人branch内のみ)。
    static let syncSecret = "cx-sync-9f3a7b2e8d1c6045"

    /// AppDelegate が APNs token 取得時にセットする。
    static var deviceToken: String?

    /// 現在の購読リスト(+token) を M2 に送る。購読変更時 / token取得時に呼ぶ。fire-and-forget。
    @MainActor
    static func push() {
        guard let url = URL(string: endpoint) else { return }
        let subs: [[String: String]] = SubscriptionStore.shared.items.map {
            ["id": $0.id.uuidString, "label": $0.displayLabel, "query": $0.searchQuery]
        }
        var body: [String: Any] = ["subscriptions": subs]
        if let t = deviceToken { body["token"] = t }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(syncSecret, forHTTPHeaderField: "X-Auth")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err = err {
                LogManager.shared.log("Sync", "M2同期失敗: \(err.localizedDescription)")
            } else if let h = resp as? HTTPURLResponse {
                LogManager.shared.log("Sync", "M2同期 status=\(h.statusCode) (\(subs.count)件)")
            }
        }.resume()
    }
}
