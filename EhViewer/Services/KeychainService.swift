import Foundation
import Security

enum KeychainService: Sendable {
    nonisolated(unsafe) private static let service = "com.kanayayuutou.EhViewer"

    nonisolated static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // まず既存を更新
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            // 存在しなければ新規追加
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            LogManager.shared.log("Keychain", "add key=\(key) status=\(addStatus)")
        } else if status != errSecSuccess {
            LogManager.shared.log("Keychain", "update failed key=\(key) status=\(status), retrying delete+add")
            SecItemDelete(query as CFDictionary)
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            LogManager.shared.log("Keychain", "retry add key=\(key) status=\(addStatus)")
        } else {
            LogManager.shared.log("Keychain", "update ok key=\(key)")
        }
    }

    nonisolated static func load(key: String) -> String? {
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

    nonisolated static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    nonisolated static func deleteAll() {
        for key in ["ipb_member_id", "ipb_pass_hash", "igneous"] {
            delete(key: key)
        }
        // サービス全体のエントリも念のため削除
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
