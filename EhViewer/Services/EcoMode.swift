import Foundation
import Combine

/// ECOモード（低消費電力モード）
/// NPU/GPU/フィルタを全て無効化し、最小限の機能で動作
final class EcoMode: ObservableObject {
    static let shared = EcoMode()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "ecoMode")
            if isEnabled {
                // エクストリームと排他
                ExtremeMode.shared.isEnabled = false
            }
        }
    }

    @Published var linkToLowPower: Bool {
        didSet { UserDefaults.standard.set(linkToLowPower, forKey: "ecoLinkLowPower") }
    }

    private var lowPowerObserver: NSObjectProtocol?

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "ecoMode")
        self.linkToLowPower = UserDefaults.standard.bool(forKey: "ecoLinkLowPower")
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
