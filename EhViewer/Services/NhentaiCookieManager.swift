import Foundation
import Security

/// nhentai用Cookie管理（E-Hentaiとは完全分離）
enum NhentaiCookieManager: Sendable {
    private static let service = "com.kanayayuutou.CortEX.nhentai"

    // MARK: - Keychain操作

    private static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    private static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Cookie管理

    static func saveCookies(_ cookieString: String) {
        save(key: "nh_cookies", value: cookieString)
        // バックアップ
        UserDefaults.standard.set(cookieString, forKey: "lastNhCookies")
        LogManager.shared.log("nhAuth", "cookies saved (\(cookieString.count) chars)")
    }

    static func loadCookies() -> String? {
        load(key: "nh_cookies")
    }

    static func isLoggedIn() -> Bool {
        guard let cookies = loadCookies() else { return false }
        return cookies.contains("sessionid") || cookies.contains("csrftoken")
    }

    static func clearCookies() {
        // ログアウト前にバックアップ
        if let current = loadCookies() {
            UserDefaults.standard.set(current, forKey: "lastNhCookies")
        }
        delete(key: "nh_cookies")
        LogManager.shared.log("nhAuth", "cookies cleared (backup saved)")
    }

    /// バックアップから復元
    static func restoreFromBackup() -> Bool {
        if let backup = UserDefaults.standard.string(forKey: "lastNhCookies"), !backup.isEmpty {
            saveCookies(backup)
            LogManager.shared.log("nhAuth", "restored from backup")
            return true
        }
        return false
    }

    /// Cookie文字列をHTTPヘッダ用に返す
    static func cookieHeader() -> String? {
        loadCookies()
    }

    /// Cloudflare cf_clearanceを持っているか
    static func hasCfClearance() -> Bool {
        loadCookies()?.contains("cf_clearance") ?? false
    }
}
