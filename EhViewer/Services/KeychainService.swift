import Foundation
import Security

enum KeychainService: Sendable {
    nonisolated(unsafe) private static let service = "com.kanayayuutou.EhViewer"

    /// Catalyst (ad-hoc 署名) では Keychain が -34018 で書けず、UserDefaults も
    /// cfprefsd の domain/sync 問題で信頼できない。Documents 直下の非隠し
    /// サブディレクトリに平文保存 (個人利用向け、暗号化なし)。
    private static var fallbackDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer/creds", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func fallbackFile(_ key: String) -> URL {
        fallbackDir.appendingPathComponent("\(key).dat")
    }

    private static func baseQuery(key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    nonisolated static func save(key: String, value: String) {
        #if targetEnvironment(macCatalyst)
        try? value.write(to: fallbackFile(key), atomically: true, encoding: .utf8)
        LogManager.shared.log("Keychain", "catalyst: saved to file key=\(key)")
        return
        #else
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = baseQuery(key: key)
        // accessibility = AfterFirstUnlockThisDeviceOnly:
        // 初回アンロック後はデバイスロック中でも access 可。BG DL (ロック画面中
        // でも Keychain 読む経路) が kSecAttrAccessibleWhenUnlocked デフォルトで
        // nil 返しになる問題を回避。ThisDeviceOnly で iCloud Keychain 同期も除外。
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(newItem as CFDictionary, nil)
        } else if status != errSecSuccess {
            SecItemDelete(query as CFDictionary)
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(newItem as CFDictionary, nil)
        }
        #endif
    }

    /// 起動時 migration: 旧 kSecAttrAccessibleWhenUnlocked で保存された既存アイテムを
    /// 新 kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly に書き直す。
    /// BG DL (ロック中) で Keychain nil 返しになる問題の根本解消。
    /// 失敗時 (load nil) はそのアイテムだけスキップ = 該当 cookie が無いだけなので
    /// 通常ログインフローで上書きされる (再ログインで自然解決)。
    /// 完了フラグは UserDefaults に残して二度目実行を防ぐ。
    nonisolated static func migrateAccessibility() {
        #if !targetEnvironment(macCatalyst)
        let migratedKey = "keychain.accessibility.migrated.v1"
        if UserDefaults.standard.bool(forKey: migratedKey) { return }
        var migratedCount = 0
        for key in ["ipb_member_id", "ipb_pass_hash", "igneous"] {
            guard let value = load(key: key) else { continue }
            delete(key: key)
            save(key: key, value: value)
            migratedCount += 1
        }
        UserDefaults.standard.set(true, forKey: migratedKey)
        LogManager.shared.log("Keychain", "accessibility migration complete: \(migratedCount) items")
        #endif
    }

    nonisolated static func load(key: String) -> String? {
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

    nonisolated static func delete(key: String) {
        #if targetEnvironment(macCatalyst)
        try? FileManager.default.removeItem(at: fallbackFile(key))
        #else
        let query: [String: Any] = baseQuery(key: key)
        SecItemDelete(query as CFDictionary)
        #endif
    }

    nonisolated static func deleteAll() {
        for key in ["ipb_member_id", "ipb_pass_hash", "igneous"] {
            delete(key: key)
        }
        #if !targetEnvironment(macCatalyst)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}
