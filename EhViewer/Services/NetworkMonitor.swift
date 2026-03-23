import Foundation
import Network
import Combine

/// ネットワーク状態監視シングルトン
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var isConnected = true
    @Published var isWiFi = true
    @Published var isCellular = false
    @Published var showOfflineBanner = false
    @Published var showCellularPrompt = false

    /// モバイルデータでのDL自動許可
    var allowCellularDownload: Bool {
        get { UserDefaults.standard.bool(forKey: "allowCellularDownload") }
        set { UserDefaults.standard.set(newValue, forKey: "allowCellularDownload") }
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private var wasWiFi = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        let connected = path.status == .satisfied
        let wifi = path.usesInterfaceType(.wifi)
        let cellular = path.usesInterfaceType(.cellular)

        let wasConnected = isConnected

        LogManager.shared.log("Network", "pathUpdate: status=\(path.status) connected=\(connected) wifi=\(wifi) cellular=\(cellular) wasConnected=\(wasConnected)")

        isConnected = connected
        isWiFi = wifi
        isCellular = cellular
        showOfflineBanner = !connected

        // WiFi→セルラー切替検出
        if connected && !wifi && cellular && wasWiFi && !allowCellularDownload {
            showCellularPrompt = true
            LogManager.shared.log("Network", "WiFi -> Cellular, prompting user")
        }

        wasWiFi = wifi

        if !wasConnected && connected {
            LogManager.shared.log("Network", "connection restored (wifi=\(wifi) cellular=\(cellular))")
        } else if wasConnected && !connected {
            LogManager.shared.log("Network", "connection lost")
        }
    }

    /// ECO+セルラーでDLを停止すべきか
    var shouldPauseDownload: Bool {
        !isConnected || (EcoMode.shared.isEnabled && isCellular && !isWiFi)
    }

    deinit {
        monitor.cancel()
    }
}
