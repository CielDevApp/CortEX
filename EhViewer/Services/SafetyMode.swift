import Foundation
import Combine

/// セーフティモード（BAN 予防のための保守的設定 + URL 解決 cooldown）
/// 旧 ExtremeMode の意味を反転したもの:
///   - safetyMode ON (default):  全ディレイ有効、並列数保守 (旧・非 Extreme)
///   - safetyMode OFF:           ディレイスキップ、並列数拡大 (旧 Extreme、BAN リスクあり)
///
/// UserDefaults に永続化される (旧 ExtremeMode はメモリ専用だった)。
/// デフォルト true = 新規ユーザーはセーフ側から開始。
@MainActor
final class SafetyMode: ObservableObject {
    static let shared = SafetyMode()

    nonisolated private static let storageKey = "safetyMode"

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

    /// nonisolated 文脈 (EhClient init 等) 向けの永続値スナップショット読み。
    /// isEnabled (@Published, @MainActor) と同じ UserDefaults キーを読む (未設定時 default true)。
    /// didSet が常に UserDefaults へ書くため値は isEnabled と一致する。
    nonisolated var isEnabledSnapshot: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: Self.storageKey) == nil
            ? true
            : defaults.bool(forKey: Self.storageKey)
    }

    /// ディレイを適用するか (safety ON = 適用、OFF = skip)
    var shouldApplyDelay: Bool { isEnabled }

    /// BAN 対策ディレイ (safety OFF 時は 0)
    /// 旧 ExtremeMode.delay と同じ API、意味反転のみ
    ///
    /// ⚠️ キャンセル吸収に注意 (2026-06-10):
    /// `try? await Task.sleep` は CancellationError をここで握り潰すため、
    /// Task.cancel() されても呼び出し元には何も伝わらず処理が続行する。
    /// throws に変えると全呼び出し元へ波及するためシグネチャは維持し、
    /// **呼び出し元がループ/await 後に `Task.isCancelled` を必ずチェックする**契約とする
    /// (リーダー閉鎖後に fetch ループが最大数百秒回り続けた真因)。
    /// BAN 対策本体 (ディレイ値・適用条件) は変更禁止。
    func delay(nanoseconds: UInt64) async {
        guard isEnabled else { return }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
