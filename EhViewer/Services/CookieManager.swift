import Foundation

enum CookieManager: Sendable {
    struct Credentials: Sendable {
        let memberID: String
        let passHash: String
        let igneous: String?
    }

    static func saveCredentials(_ creds: Credentials) {
        LogManager.shared.log("Auth", "saving: id=\(creds.memberID.count)chars hash=\(creds.passHash.count)chars igneous=\(creds.igneous?.count ?? 0)chars")
        KeychainService.save(key: "ipb_member_id", value: creds.memberID)
        KeychainService.save(key: "ipb_pass_hash", value: creds.passHash)
        if let igneous = creds.igneous, !igneous.isEmpty {
            KeychainService.save(key: "igneous", value: igneous)
        }
        // 保存後に検証
        if let loaded = KeychainService.load(key: "ipb_pass_hash") {
            LogManager.shared.log("Auth", "verify: hash=\(loaded.count)chars value=\(loaded.prefix(32))...")
        }
    }

    static func loadCredentials() -> Credentials? {
        guard let memberID = KeychainService.load(key: "ipb_member_id"),
              let passHash = KeychainService.load(key: "ipb_pass_hash") else {
            return nil
        }
        let igneous = KeychainService.load(key: "igneous")
        return Credentials(memberID: memberID, passHash: passHash, igneous: igneous)
    }

    static func clearCredentials() {
        KeychainService.deleteAll()
    }

    static func isLoggedIn() -> Bool {
        loadCredentials() != nil
    }
}
