import Foundation
import Combine

class AuthViewModel: ObservableObject {
    @Published var memberID: String = ""
    @Published var passHash: String = ""
    @Published var igneous: String = ""
    @Published var isLoggedIn: Bool = false
    @Published var errorMessage: String?
    @Published var showingLogin: Bool = false

    init() {
        isLoggedIn = CookieManager.isLoggedIn()
        // 保存済みの値をフォームに事前入力（Keychain → UserDefaultsバックアップの順）
        if let creds = CookieManager.loadCredentials() {
            memberID = creds.memberID
            passHash = creds.passHash
            igneous = creds.igneous ?? ""
        } else {
            memberID = UserDefaults.standard.string(forKey: "lastMemberID") ?? ""
            passHash = UserDefaults.standard.string(forKey: "lastPassHash") ?? ""
            igneous = UserDefaults.standard.string(forKey: "lastIgneous") ?? ""
        }
    }

    func login() {
        let trimmedMemberID = memberID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassHash = passHash.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedMemberID.isEmpty, !trimmedPassHash.isEmpty else {
            errorMessage = "IDとパスハッシュを入力してください"
            return
        }

        // passHashは32文字の16進数であるべき
        let validHash: String
        if trimmedPassHash.count == 64 {
            // 2回ペーストされた可能性 → 前半32文字を使用
            let half = String(trimmedPassHash.prefix(32))
            if half == String(trimmedPassHash.suffix(32)) {
                validHash = half
                LogManager.shared.log("Auth", "passHash was duplicated (64chars), auto-corrected to 32chars")
            } else {
                validHash = trimmedPassHash
            }
        } else {
            validHash = trimmedPassHash
        }

        let creds = CookieManager.Credentials(
            memberID: trimmedMemberID,
            passHash: validHash,
            igneous: igneous.isEmpty ? nil : igneous.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        CookieManager.saveCredentials(creds)
        isLoggedIn = true
        errorMessage = nil
        showingLogin = false
    }

    func logout() {
        // ログアウト前にバックアップ（次回ログイン時の自動入力用）
        if let creds = CookieManager.loadCredentials() {
            UserDefaults.standard.set(creds.memberID, forKey: "lastMemberID")
            UserDefaults.standard.set(creds.passHash, forKey: "lastPassHash")
            UserDefaults.standard.set(creds.igneous ?? "", forKey: "lastIgneous")
        }
        CookieManager.clearCredentials()
        isLoggedIn = false
        // フォームにはバックアップ値を残す
    }
}
