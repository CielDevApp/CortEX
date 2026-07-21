import Foundation
#if canImport(UIKit)
import UIKit

// MARK: - タッチ着弾診断 (2026-07-22)
//
// iPad ライブラリで「タップの当たり判定がごく一部にしか無い」(田中報告 2026-07-21 深夜)。
// [Tap] ハンドラログに出ないタップが多数 = SwiftUI の Button まで届いていない。
// どの UIView が死んだタップを吸っているかを特定するため、window に観察専用
// recognizer を載せ、全タッチの着弾点 + hitTest 先クラス名 + 移動距離を記録する。
//
// cortex://debug/tap-diag で attach (観察のみ、タッチは一切奪わない)。

final class TapDiagRecognizer: UIGestureRecognizer {
    private var beganPoint: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        let w = view?.window ?? (view as? UIWindow)
        guard let w else { return }
        let p = t.location(in: w)
        beganPoint = p
        let hit = w.hitTest(p, with: nil)
        let cls = hit.map { String(describing: type(of: $0)) } ?? "nil"
        let sz = hit.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "-"
        LogManager.shared.log("TapDiag", "began (\(Int(p.x)),\(Int(p.y))) hit=\(cls) size=\(sz)")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first, let w = view?.window ?? (view as? UIWindow) else { return }
        let p = t.location(in: w)
        let d = hypot(p.x - beganPoint.x, p.y - beganPoint.y)
        LogManager.shared.log("TapDiag", "ended (\(Int(p.x)),\(Int(p.y))) moved=\(Int(d))pt")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        LogManager.shared.log("TapDiag", "cancelled")
    }
}

@MainActor
enum TapDiagnostic {
    private static var attached = false

    /// key window に観察 recognizer を載せる。二重 attach は無視。
    /// 起動直後は key window 未生成のことがある (2026-07-22 実測) → 0.5秒間隔で最大10回リトライ。
    static func attach(retry: Int = 10) {
        guard !attached else {
            LogManager.shared.log("TapDiag", "already attached")
            return
        }
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard let window else {
            if retry > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { attach(retry: retry - 1) }
            } else {
                LogManager.shared.log("TapDiag", "attach failed: no key window (retry exhausted)")
            }
            return
        }
        let rec = TapDiagRecognizer()
        rec.cancelsTouchesInView = false
        rec.delaysTouchesBegan = false
        rec.delaysTouchesEnded = false
        window.addGestureRecognizer(rec)
        attached = true
        LogManager.shared.log("TapDiag", "attached to key window \(Int(window.bounds.width))x\(Int(window.bounds.height))")
    }
}
#endif
