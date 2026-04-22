import Foundation
import Security

extension Notification.Name {
    /// nhentai のログイン状態 (cookie 保存 / 削除) が変化した
    static let nhentaiLoginStateChanged = Notification.Name("Cortex.nhentaiLoginStateChanged")
}

/// nhentai用Cookie管理（E-Hentaiとは完全分離）
enum NhentaiCookieManager: Sendable {
    private static let service = "com.kanayayuutou.CortEX.nhentai"

    // MARK: - Keychain操作

    /// Mac Catalyst は sandbox OFF + file-based keychain で動作。
    /// kSecUseDataProtectionKeychain は付けない (entitlement 必須化で -34018 になるため)。
    private static func baseQuery(key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// Catalyst 用フォールバックファイル保存先 (Documents/EhViewer/nh_creds/)
    private static var fallbackDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer/nh_creds", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func fallbackFile(_ key: String) -> URL {
        fallbackDir.appendingPathComponent("\(key).dat")
    }

    private static func save(key: String, value: String) {
        #if targetEnvironment(macCatalyst)
        try? value.write(to: fallbackFile(key), atomically: true, encoding: .utf8)
        #else
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = baseQuery(key: key)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            status = SecItemAdd(newItem as CFDictionary, nil)
        } else if status != errSecSuccess {
            SecItemDelete(query as CFDictionary)
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
        #endif
    }

    private static func load(key: String) -> String? {
        #if targetEnvironment(macCatalyst)
        return try? String(contentsOf: fallbackFile(key), encoding: .utf8)
        #else
        var query: [String: Any] = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }

    private static func delete(key: String) {
        #if targetEnvironment(macCatalyst)
        try? FileManager.default.removeItem(at: fallbackFile(key))
        #else
        let query: [String: Any] = baseQuery(key: key)
        SecItemDelete(query as CFDictionary)
        #endif
    }

    // MARK: - Cookie管理

    static func saveCookies(_ cookieString: String) {
        save(key: "nh_cookies", value: cookieString)
        // バックアップ
        UserDefaults.standard.set(cookieString, forKey: "lastNhCookies")
        LogManager.shared.log("nhAuth", "cookies saved (\(cookieString.count) chars)")
        NotificationCenter.default.post(name: .nhentaiLoginStateChanged, object: nil)
    }

    static func loadCookies() -> String? {
        load(key: "nh_cookies")
    }

    static func isLoggedIn() -> Bool {
        guard let cookies = loadCookies() else { return false }
        return cookies.contains("sessionid") || cookies.contains("csrftoken") || cookies.contains("access_token")
    }

    static func clearCookies() {
        defer { NotificationCenter.default.post(name: .nhentaiLoginStateChanged, object: nil) }
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

    // MARK: - v2 API Token

    static func saveToken(_ token: String) {
        save(key: "nh_api_token", value: token)
        LogManager.shared.log("nhAuth", "API token saved (\(token.prefix(20))...)")
    }

    static func loadToken() -> String? {
        load(key: "nh_api_token")
    }

    static func hasToken() -> Bool {
        loadToken() != nil
    }
}
