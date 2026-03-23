import Foundation
import Security
import Combine

/// 4桁PINコードのKeychain管理+認証
final class PINManager: ObservableObject {
    static let shared = PINManager()

    @Published var isLocked = false
    @Published var failedAttempts = 0
    @Published var lockoutEndTime: Date?

    private let keychainKey = "ehviewer_pin_code"
    private let maxAttempts = 3
    private let lockoutDuration: TimeInterval = 30

    var hasPIN: Bool {
        loadPIN() != nil
    }

    var isLockedOut: Bool {
        guard let end = lockoutEndTime else { return false }
        return Date() < end
    }

    var lockoutRemaining: Int {
        guard let end = lockoutEndTime else { return 0 }
        return max(0, Int(ceil(end.timeIntervalSinceNow)))
    }

    // MARK: - PIN設定

    func setPIN(_ pin: String) -> Bool {
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { return false }
        return savePIN(pin)
    }

    func removePIN() {
        deletePIN()
        failedAttempts = 0
        lockoutEndTime = nil
    }

    // MARK: - PIN認証

    func verify(_ pin: String) -> Bool {
        guard !isLockedOut else { return false }
        guard let stored = loadPIN() else { return false }

        if pin == stored {
            failedAttempts = 0
            lockoutEndTime = nil
            return true
        } else {
            failedAttempts += 1
            if failedAttempts >= maxAttempts {
                lockoutEndTime = Date().addingTimeInterval(lockoutDuration)
                failedAttempts = 0
            }
            return false
        }
    }

    func verifyCurrentPIN(_ pin: String) -> Bool {
        loadPIN() == pin
    }

    // MARK: - Keychain

    private func savePIN(_ pin: String) -> Bool {
        deletePIN()
        let data = Data(pin.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainKey,
            kSecAttrAccount as String: "pin",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func loadPIN() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainKey,
            kSecAttrAccount as String: "pin",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deletePIN() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainKey,
            kSecAttrAccount as String: "pin",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
