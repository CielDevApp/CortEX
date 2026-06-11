import Foundation
import Combine

/// ECOモード（低消費電力モード）
/// NPU/GPU/フィルタを全て無効化し、最小限の機能で動作
@MainActor
final class EcoMode: ObservableObject {
    static let shared = EcoMode()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: UDKey.ecoMode)
            if isEnabled {
                // セーフティと排他とは逆: ECO ON 時は safety ON 強制 (攻撃的設定と不整合回避)
                SafetyMode.shared.isEnabled = true
            }
        }
    }

    @Published var linkToLowPower: Bool {
        didSet { UserDefaults.standard.set(linkToLowPower, forKey: UDKey.ecoLinkLowPower) }
    }

    private var lowPowerObserver: NSObjectProtocol?

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: UDKey.ecoMode)
        self.linkToLowPower = UserDefaults.standard.bool(forKey: UDKey.ecoLinkLowPower)
        startLowPowerMonitoring()
    }

    private func startLowPowerMonitoring() {
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.linkToLowPower else { return }
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            if lowPower && !self.isEnabled {
                self.isEnabled = true
                LogManager.shared.log("ECO", "auto-enabled (iOS low power mode ON)")
            } else if !lowPower && self.isEnabled {
                self.isEnabled = false
                LogManager.shared.log("ECO", "auto-disabled (iOS low power mode OFF)")
            }
        }
    }

    deinit {
        if let observer = lowPowerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
