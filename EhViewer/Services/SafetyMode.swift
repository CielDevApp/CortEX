import Foundation
import Combine

/// セーフティモード（BAN 予防のための保守的設定 + URL 解決 cooldown）
/// 旧 ExtremeMode の意味を反転したもの:
///   - safetyMode ON (default):  全ディレイ有効、並列数保守 (旧・非 Extreme)
///   - safetyMode OFF:           ディレイスキップ、並列数拡大 (旧 Extreme、BAN リスクあり)
///
/// UserDefaults に永続化される (旧 ExtremeMode はメモリ専用だった)。
/// デフォルト true = 新規ユーザーはセーフ側から開始。
final class SafetyMode: ObservableObject {
    static let shared = SafetyMode()

    private static let storageKey = "safetyMode"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.storageKey)
            // ECO と排他: ECO ON 時は safetyMode を強制 true (矛盾回避)
            if !isEnabled && EcoMode.shared.isEnabled {
                // safetyMode OFF と ECO 併用は警告なく禁止
                isEnabled = true
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.storageKey) == nil {
            // 未設定: セーフ側をデフォルトに
            self.isEnabled = true
            defaults.set(true, forKey: Self.storageKey)
        } else {
            self.isEnabled = defaults.bool(forKey: Self.storageKey)
        }
    }

    /// ディレイを適用するか (safety ON = 適用、OFF = skip)
    var shouldApplyDelay: Bool { isEnabled }

    /// BAN 対策ディレイ (safety OFF 時は 0)
    /// 旧 ExtremeMode.delay と同じ API、意味反転のみ
    func delay(nanoseconds: UInt64) async {
        guard isEnabled else { return }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
