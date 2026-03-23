import Foundation
import Combine

/// エクストリームモード（BAN対策ディレイを全て無効化）
/// アプリ再起動時は必ずOFF（メモリ上のフラグのみ、UserDefaultsに保存しない）
final class ExtremeMode: ObservableObject {
    static let shared = ExtremeMode()

    @Published var isEnabled = false {
        didSet {
            if isEnabled {
                // ECOと排他
                EcoMode.shared.isEnabled = false
            }
        }
    }

    private init() {}

    /// ディレイをスキップすべきか
    var shouldSkipDelay: Bool { isEnabled }

    /// BAN対策ディレイ（エクストリーム時は0）
    func delay(nanoseconds: UInt64) async {
        guard !isEnabled else { return }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
