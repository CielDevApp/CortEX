import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 端末性能の判定 (2026-07-21 SE2 実測より)
//
// 田中の SE2 (A13/3GB) 性能テストで確定した事実:
//   - 大量DL (1848p) / 究極画質+AI超解像 / ローカル最大画質は耐える (used ≤ 372MB)
//   - **WebP 動画再生だけは実時間再生が不可 (CPU律速)**。メモリは余裕 (used 214-317MB) なのに
//     再生が始まらない・ガクガクし、打電タイマーまで遅延配送された = デコードが追いつかない。
//   - Cort:EX は最新機種でも WebP 動画の同時再生を許していない (それほど重い処理)。
//     A13 は1本ですら荷が重い。
//
// 判定方式: **機種名リストではなく識別子の世代番号で閾値比較**する。
// リスト方式だと「リストに無い未来の端末」を取りこぼして誤警告する。閾値方式なら
// 未知 = より新しい世代 → 自動的に対象外になり、未来のデバイスに警告が出ない (田中指示)。

nonisolated enum DeviceCapability {

    /// "iPhone12,8" 等のハードウェア識別子。
    static var machineIdentifier: String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingCString: $0) ?? "" }
        }
    }

    /// WebP 動画 (アニメーション) の実時間再生に性能が足りない端末か。
    ///
    /// iPhone の世代番号 (`iPhoneN,M` の N) で判定:
    ///   - iPhone16,x = A17 Pro 世代 (iPhone 15 Pro/Pro Max)。**ここまでを「A17以下」として警告対象**
    ///   - iPhone17,x = A18 世代以降 → 対象外
    ///   - 未知/解析不能 (= 将来の新機種、Simulator 等) → **対象外** (安全側 = 警告しない)
    /// iPad / Mac Catalyst は対象外 (M チップ機・大容量 RAM が主で、識別子体系も別のため
    /// 誤判定リスクの方が高い。必要なら田中判断で追加する)。
    static var isAnimatedWebPUnderpowered: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        let id = machineIdentifier
        guard id.hasPrefix("iPhone") else { return false }
        let body = id.dropFirst("iPhone".count)
        guard let comma = body.firstIndex(of: ","),
              let generation = Int(body[body.startIndex..<comma]) else { return false }
        return generation <= 16
        #endif
    }
}

#if canImport(UIKit)
import SwiftUI

/// WebP 動画の性能警告アラート (A17 以下端末のみ表示)。
/// 呼び出し側の modifier チェーンを短く保つため独立 modifier にする
/// (LocalReaderView に直書きすると型チェックが時間内に終わらない)。
struct WebPPerfWarningModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert("この端末では動画の再生が重くなります", isPresented: $isPresented) {
            Button("今後表示しない") {
                UserDefaults.standard.set(true, forKey: UDKey.webpPerfWarningSuppressed)
            }
            Button("OK", role: .cancel) { }
        } message: {
            // 2026-07-23 SE2 実証 (田中): カクつきの正体は毎フレーム補正 (AI超解像/ノイズ除去/
            // 人物セグメンテーション) の処理落ち。補正を切れば旧端末でも滑らかに再生できる。
            Text("動画 (アニメーション WebP) のコマ落ちは画質補正の処理負荷が原因です。設定で「無補正モード」を ON にすると、この端末でも滑らかに再生できます。静止画の閲覧・ダウンロードは通常どおり利用できます。")
        }
    }
}

extension View {
    func webpPerfWarning(isPresented: Binding<Bool>) -> some View {
        modifier(WebPPerfWarningModifier(isPresented: isPresented))
    }
}
#endif
