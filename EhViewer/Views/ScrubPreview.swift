import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#endif

// MARK: - スクラブプレビュー — 統合指示書 v2 機能A (2026-07-20)
//
// 保存済み作品のグリッドセルに指を置くと 120ms でプレビュー発動、総ページ数に応じた
// 間引きでページが「ぱっぱっ」と切り替わる。動画サイトのホバープレビューのタッチ移植。
// 「セルがプレビューする」のではなく「指がプレビューカーソル」。
// 絶対条件: 保存済み限定・ネットワークゼロ (disk 読みのみ)・同時1作品 (排他=メモリ上限)・
// スクロール阻害ゼロ。decode は LibraryThumbDecoder 共通パイプラインのみ。

enum ScrubPreviewConfig {
    static let maxSamples = 10          // 周回あたり最大コマ数
    // 2026-07-20 実機FB (田中): 切り替わりが速い → 0.45/0.7/0.8 から減速
    static let dwellNormal: TimeInterval = 0.6    // 通常コマ表示時間
    static let dwellFewPages: TimeInterval = 0.9  // 5p以下作品
    static let dwellCover: TimeInterval = 1.0     // カバー(フレーム0)
    static let activateDelay: TimeInterval = 0.12
    static let prefetchDebounce: TimeInterval = 0.2
    static let minPagesToActivate = 2   // 1p作品は発動対象外
    /// 発動前にこの距離 (pt) 動いたらスクロール/タップとして素通し
    static let moveTolerance: CGFloat = 8
    /// プレビューコマの decode 上限 (px)
    static let maxPixel: CGFloat = 360
}

#if canImport(UIKit)

/// per-cell の表示状態。セルはこれを観察するだけで供給経路を知らない (PageImageHolder 作法)。
final class ScrubPreviewHolder: ObservableObject {
    @Published var frame: UIImage?      // nil = カバー表示 (既存ビューのまま)
    @Published var pageLabel: String?   // "p.12 / 1193"、カバー中は nil
    /// 監査A2: 発動中セルの沈み込み (1.0 = 通常, 0.96 = 掴んでいる)。端点だけ物理を効かせる。
    @Published var pressScale: CGFloat = 1.0
}

@MainActor
final class ScrubPreviewController: ObservableObject {
    static let shared = ScrubPreviewController()

    private struct CellInfo { var pageCount: Int; var frame: CGRect }
    private var cells: [Int: CellInfo] = [:]
    private var holders: [Int: ScrubPreviewHolder] = [:]

    private(set) var activeGID: Int?
    private var frames: [Int: UIImage] = [:]   // 再生列 index → コマ。activeGID の分だけ (≤10)
    private var sequence: [Int] = []           // 再生列のページ番号 (1-based)。カバーは列外
    private var playTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var activateTask: Task<Void, Never>?
    private var touchStart: CGPoint?
    private var swallowTapUntil: Date = .distantPast
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// 監査A2/A3: 端点の物理。掴んだ瞬間だけ沈める (critically damped、bounce なし)。
    /// 指離し/セル跨ぎの復帰は spring で 1.0 へ。旧セルの復帰は即時ではなく短い spring で
    /// 「離した」実感を残す (A3: 旧復帰と新沈み込みの非対称は復帰側を軽くする形で実現)。
    private let pressDownScale: CGFloat = 0.96
    private func animatePress(_ gid: Int, to target: CGFloat, snappy: Bool) {
        let h = holder(for: gid)
        withAnimation(snappy ? .spring(response: 0.22, dampingFraction: 0.7)
                             : .spring(response: 0.32, dampingFraction: 1.0)) {
            h.pressScale = target
        }
    }

    // MARK: セル登録 (グリッドセルの onGeometryChange / onDisappear から)

    func updateCell(gid: Int, pageCount: Int, frame: CGRect) {
        cells[gid] = CellInfo(pageCount: pageCount, frame: frame)
    }

    func cellGone(_ gid: Int) {
        cells[gid] = nil
        holders[gid] = nil
        if activeGID == gid { reset() }    // スクロールアウトも reset (A-3 終了)
    }

    func holder(for gid: Int) -> ScrubPreviewHolder {
        if let h = holders[gid] { return h }
        let h = ScrubPreviewHolder()
        holders[gid] = h
        return h
    }

    /// プレビュー発動後に指を離してもタップ扱いにしない (A-3)。セル Button 冒頭で確認する。
    func consumeSwallowTap() -> Bool { Date() < swallowTapUntil }

    // MARK: タッチ追跡 (ScrubTouchOverlay から window 座標で届く)

    func touchBegan(at p: CGPoint) {
        touchStart = p
        activateTask?.cancel()
        guard gid(at: p) != nil else { return }
        activateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ScrubPreviewConfig.activateDelay * 1e9))
            guard !Task.isCancelled, let self else { return }
            if let g = self.gid(at: p) {
                self.activate(g, prefetchDelay: max(0, ScrubPreviewConfig.prefetchDebounce - ScrubPreviewConfig.activateDelay))
            }
        }
    }

    func touchMoved(to p: CGPoint) {
        if activeGID == nil {
            // 発動前: 8pt 動いたら通常のスクロール/タップとして素通し
            if let s = touchStart, hypot(p.x - s.x, p.y - s.y) > ScrubPreviewConfig.moveTolerance {
                activateTask?.cancel()
            }
            return
        }
        // 発動後: 指がプレビューカーソル。指下セルが変われば旧 reset → 新 activate (即時)
        let g = gid(at: p)
        if g != activeGID {
            if let g {
                activate(g, prefetchDelay: ScrubPreviewConfig.prefetchDebounce)
            } else {
                reset()
            }
        }
    }

    func touchEnded() {
        activateTask?.cancel()
        if activeGID != nil {
            swallowTapUntil = Date().addingTimeInterval(0.35)
        }
        reset()
    }

    private func gid(at p: CGPoint) -> Int? {
        cells.first(where: { $0.value.frame.contains(p) })?.key
    }

    // MARK: 発動 / 再生 / 停止

    private func activate(_ gid: Int, prefetchDelay: TimeInterval) {
        reset()
        guard let cell = cells[gid], cell.pageCount >= ScrubPreviewConfig.minPagesToActivate else { return }
        activeGID = gid
        haptic.impactOccurred()
        // A2: 掴んだ瞬間に沈む (haptic と同フレーム = apple-design §13 harmony)
        animatePress(gid, to: pressDownScale, snappy: true)

        let total = cell.pageCount
        let samples = min(total, ScrubPreviewConfig.maxSamples)
        let step = max(1, total / samples)
        sequence = (0..<samples).map { min(1 + $0 * step, total) }
        let dwell = total <= 5 ? ScrubPreviewConfig.dwellFewPages : ScrubPreviewConfig.dwellNormal

        // 先読み: 滞留デバウンス後に逐次 decode (A-5)。高速通過セルで disk IO を出さない。
        // URL 解決は main (DownloadManager)、decode は detached (main を塞がない)。
        let urls = sequence.map { DownloadManager.shared.imageFilePath(gid: gid, page: $0 - 1) }
        prefetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(prefetchDelay * 1e9))
            guard !Task.isCancelled else { return }
            for (i, url) in urls.enumerated() {
                guard let self, !Task.isCancelled, self.activeGID == gid else { return }
                let img = await Task.detached(priority: .userInitiated) {
                    LibraryThumbDecoder.decode(url: url, maxPixel: ScrubPreviewConfig.maxPixel)
                }.value
                if self.activeGID == gid, let img { self.frames[i] = img }
            }
        }

        // 再生: カバー → サンプル列 → カバー → … 無限周回。未ロードコマはスキップ (A-4)。
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeGID == gid else { return }
                self.show(frameIndex: nil, gid: gid, total: total)
                try? await Task.sleep(nanoseconds: UInt64(ScrubPreviewConfig.dwellCover * 1e9))
                var shownAny = false
                for i in 0..<self.sequence.count {
                    if Task.isCancelled || self.activeGID != gid { return }
                    guard self.frames[i] != nil else { continue }   // スピナー・黒画面を出さない
                    shownAny = true
                    self.show(frameIndex: i, gid: gid, total: total)
                    try? await Task.sleep(nanoseconds: UInt64(dwell * 1e9))
                }
                if !shownAny {
                    try? await Task.sleep(nanoseconds: 150_000_000)  // 全コマ未着時の空回り防止
                }
            }
        }
    }

    private func show(frameIndex: Int?, gid: Int, total: Int) {
        let h = holder(for: gid)
        if let i = frameIndex, let img = frames[i] {
            h.frame = img
            h.pageLabel = "p.\(sequence[i]) / \(total)"
        } else {
            h.frame = nil
            h.pageLabel = nil
        }
    }

    func reset() {
        playTask?.cancel(); playTask = nil
        prefetchTask?.cancel(); prefetchTask = nil
        if let g = activeGID, let h = holders[g] {
            h.frame = nil
            h.pageLabel = nil
            animatePress(g, to: 1.0, snappy: false)   // A2/A3: カバーへ spring 復帰
        }
        frames.removeAll()       // 即解放 — 排他制約がそのままメモリ上限 (A-5)
        sequence.removeAll()
        activeGID = nil
        touchStart = nil
    }
}

// MARK: - セル側の表示 (カバーの上にコマを重ねる)

/// グリッドセルに付ける沈み込み modifier。holder.pressScale を監視してセル全体を scale する。
/// A2: 発動中セルだけ沈む。Reduce Motion 時は沈まない (apple-design §14)。
struct ScrubPressEffect: ViewModifier {
    @ObservedObject private var holder: ScrubPreviewHolder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(gid: Int) { holder = ScrubPreviewController.shared.holder(for: gid) }

    func body(content: Content) -> some View {
        content.scaleEffect(reduceMotion ? 1.0 : holder.pressScale)
    }
}

extension View {
    func scrubPressEffect(gid: Int) -> some View { modifier(ScrubPressEffect(gid: gid)) }
}

struct ScrubFrameView: View {
    @ObservedObject private var holder: ScrubPreviewHolder

    init(gid: Int) {
        holder = ScrubPreviewController.shared.holder(for: gid)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let img = holder.frame {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                if let label = holder.pageLabel {
                    Text(label)
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 透明オーバーレイ + カスタム recognizer (A-3 スクロール共存)

/// state を一切遷移させない追跡専用 recognizer。認識も cancel もしないので
/// スクロール・タップ・長押しの既存挙動を構造的に阻害できない。
final class ScrubGestureRecognizer: UIGestureRecognizer {
    var onBegan: ((CGPoint) -> Void)?
    var onMoved: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?
    private var tracked: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // マルチタッチは「最後に触れた指が勝つ」(A-3)
        tracked = touches.first
        if let t = tracked { onBegan?(t.location(in: nil)) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = tracked, touches.contains(t) { onMoved?(t.location(in: nil)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = tracked, touches.contains(t) { tracked = nil; onEnded?() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = tracked, touches.contains(t) { tracked = nil; onEnded?() }
    }
}

/// グリッドに1枚張る透明オーバーレイ。hitTest は常に nil (何も奪わない)。
/// recognizer は window に付けて指座標だけを継続追跡する。
struct ScrubTouchOverlay: UIViewRepresentable {
    final class PassthroughView: UIView {
        let rec = ScrubGestureRecognizer()
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let w = window {
                w.addGestureRecognizer(rec)
            } else if let holder = rec.view {
                holder.removeGestureRecognizer(rec)
            }
        }
    }

    func makeUIView(context: Context) -> PassthroughView {
        let v = PassthroughView()
        v.backgroundColor = .clear
        let ctrl = ScrubPreviewController.shared
        // 不具合修正 2026-07-21 (田中報告): window に貼る追跡専用 recognizer が
        // タブバー等のタップを cancel/遅延していた (デフォルト cancelsTouchesInView=true /
        // delaysTouchesEnded=true)。TabView はタブを生存させるため recognizer が window に
        // 残り、「ライブラリを開いた後 他タブへ移動できない」を起こしていた。仕様 (A-3) が
        // 要求する「スクロール/タップを一切ブロックしない」を明示設定して無害化する。
        v.rec.cancelsTouchesInView = false
        v.rec.delaysTouchesBegan = false
        v.rec.delaysTouchesEnded = false
        v.rec.onBegan = { [weak v] p in
            // モーダル (リーダー/シート) 提示中はグリッドが裏に居ても発動させない
            guard let v, let w = v.window,
                  w.rootViewController?.presentedViewController == nil else { return }
            ctrl.touchBegan(at: p)
        }
        v.rec.onMoved = { p in ctrl.touchMoved(to: p) }
        v.rec.onEnded = { ctrl.touchEnded() }
        return v
    }

    func updateUIView(_ uiView: PassthroughView, context: Context) {}

    static func dismantleUIView(_ uiView: PassthroughView, coordinator: ()) {
        uiView.window?.removeGestureRecognizer(uiView.rec)
    }
}

#endif
