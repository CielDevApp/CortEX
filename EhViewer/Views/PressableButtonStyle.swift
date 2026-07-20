import SwiftUI

// MARK: - 押下フィードバック統一スタイル (UI/UX 近代化監査 B1, 2026-07-21)
//
// apple-design §1「Response — kill latency」: フィードバックは指を離した時ではなく
// 押した瞬間 (pointer-down) に出す。SwiftUI ButtonStyle の isPressed は touch-down で
// 立つので、これに scale を結線するだけで App Store 本家と同じ「押すと沈む」になる。
// Reduce Motion 時は動き (scale) を畳み、opacity の減光だけ残す (apple-design §14:
// reduced motion ≠ no feedback)。

struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 沈み込み量。小さい要素ほど深く (0.96)、大きいカードは浅く (0.98) が目安。
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? scale : 1.0))
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    /// 標準の押下沈み込み (scale 0.97)
    static var pressable: PressableStyle { PressableStyle() }
    /// 沈み込み量指定版
    static func pressable(scale: CGFloat) -> PressableStyle { PressableStyle(scale: scale) }
}
