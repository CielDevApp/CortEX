import Foundation
import LocalAuthentication
import Combine

class BiometricAuth: ObservableObject {
    static let shared = BiometricAuth()

    @Published var isUnlocked = false
    @Published var authFailed = false
    @Published var showPINInput = false
    @Published var faceIDFailCount = 0

    private let maxFaceIDAttempts = 1

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "biometricLockEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "biometricLockEnabled") }
    }

    var isLockActive: Bool {
        isEnabled || PINManager.shared.hasPIN
    }

    /// Face ID認証を試行
    func authenticate() {
        guard isLockActive else {
            isUnlocked = true
            return
        }

        // 2回失敗済み + PIN設定済み → 自動でPIN画面
        if faceIDFailCount >= maxFaceIDAttempts && PINManager.shared.hasPIN {
            showPINInput = true
            return
        }

        if isEnabled {
            let context = LAContext()
            context.localizedFallbackTitle = "PINで解除"

            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                if PINManager.shared.hasPIN {
                    showPINInput = true
                }
                authFailed = true
                return
            }

            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "アプリのロックを解除") { success, _ in
                DispatchQueue.main.async {
                    if success {
                        self.isUnlocked = true
                        self.authFailed = false
                        self.showPINInput = false
                        self.faceIDFailCount = 0
                    } else {
                        self.faceIDFailCount += 1
                        self.authFailed = true
                        // 2回失敗 → 自動でPIN切替
                        if self.faceIDFailCount >= self.maxFaceIDAttempts && PINManager.shared.hasPIN {
                            self.showPINInput = true
                        }
                    }
                }
            }
        } else {
            showPINInput = true
        }
    }

    /// Face IDリトライ（PIN画面から戻る時）
    func retryFaceID() {
        faceIDFailCount = 0
        showPINInput = false
        authFailed = false
        authenticate()
    }

    func pinVerified() {
        isUnlocked = true
        authFailed = false
        showPINInput = false
        faceIDFailCount = 0
    }

    func lock() {
        guard isLockActive else { return }
        isUnlocked = false
        authFailed = false
        showPINInput = false
        faceIDFailCount = 0
    }
}
