import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import ImageIO

// MARK: - ライブラリカード (App Store 風) — 統合指示書 v2 機能B (2026-07-20)
//
// リスト表示の保存済み作品行を App Store 検索結果カードの文法で置換する。
// ガワ (アイコン行 + 大画像エリア + アクションボタン) は App Store から借り、
// 大画像エリアは実用に差し替え (序盤ページのタイル陳列)。
// 絶対条件: 保存済み限定・ネットワークゼロ (disk 読みのみ)。

/// 調整用定数 (実機の感触で田中が調整できるよう集約 — 指示書「開発規律」)
enum LibraryCardConfig {
    /// タイル列数。タイル件数は列数で割り切れる値にすること。
    static let tileColumns = 3
    /// タイル表示件数 (序盤ページ p1 から連番、ネタバレ回避で間引きしない)
    static let tileCount = 12
    /// タイル1枚の高さ (pt)
    static let tileHeight: CGFloat = 108
    /// タイルの decode 上限 (px)。セル実サイズ相当に downsample。
    static let tileMaxPixel: CGFloat = 240
    /// ジャケットの角丸
    static let coverCorner: CGFloat = 12
}

/// 共通サムネ decode パイプライン (指示書 共通条件3)。
/// CGImageSource downsample decode。フルサイズ decode 禁止 (17MB 級 WebP 対策)。
/// 動画 WebP は同 API が先頭フレーム静止画を返すため分岐不要。
/// 機能A (スクラブプレビュー) / 機能B (カードタイル) の両方がここを通ること。
nonisolated enum LibraryThumbDecoder {
    static func decode(url: URL, maxPixel: CGFloat) -> PlatformImage? {
        // 弾④ 計装: 稼働枚数 (弾② decodeCount) + 所要時間統計。ディスク decode なので常に miss。
        ShikigamiDecodeTracker.shared.begin()
        let _t0 = CFAbsoluteTimeGetCurrent()
        defer {
            ShikigamiDecodeTracker.shared.record(durationMs: (CFAbsoluteTimeGetCurrent() - _t0) * 1000, cacheHit: false)
            ShikigamiDecodeTracker.shared.end()
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: .zero)
        #endif
    }
}

/// App Store 風カード本体。上段アプリ行 + ページタイル + 続きを見る。
/// ナビゲーションは全て closure で親 (DownloadsView) に委譲 — カードは供給経路を知らない。
struct LibraryCardView<Cover: View>: View {
    let meta: DownloadedGallery
    /// 外部参照 (NAS) 作品の EXT バッジ表示
    var showExtBadge: Bool = false
    /// 小ジャケットタップ → ページ詳細 (2026-07-20 田中要望: リスト表示でページ詳細の導線が薄い)。
    /// nil なら従来通りタップ不可 (外部参照の旧 .cortex 等、詳細に行けない作品)。
    var onCover: (() -> Void)? = nil
    /// 監査B3: タイル → リーダーの zoom 遷移 namespace。nil なら zoom なし (既定遷移)。
    var zoomNamespace: Namespace.ID? = nil
    /// 上段ジャケット (既存 AsyncCoverThumbnail を親から注入して cover 経路を一本化)
    @ViewBuilder let cover: () -> Cover
    /// 「読む」ボタン (p1 から / 既存の続きから再開挙動は親側実装を踏襲)
    let onRead: () -> Void
    /// タイルタップ → リーダーで該当ページを直接開く (0-indexed)
    let onTapPage: (Int) -> Void
    /// 「続きを見る」→ ページ詳細 (既存の全ページ一覧) へ
    let onMore: () -> Void

    private var tileCount: Int { min(meta.pageCount, LibraryCardConfig.tileCount) }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(12)

            if tileCount > 0 {
                CardTileGrid(meta: meta, tileCount: tileCount, onTapPage: onTapPage,
                             zoomNamespace: zoomNamespace)
                    .padding(.horizontal, 12)
            }

            if meta.pageCount > tileCount {
                Divider()
                    .padding(.top, 10)
                Button(action: onMore) {
                    HStack {
                        Spacer()
                        Text("続きを見る")
                            .font(.subheadline)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.pressable)
                .foregroundStyle(.blue)
            } else {
                Spacer().frame(height: 12)
            }
        }
        .background(CardDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CardDesign.cardCorner, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    @ViewBuilder
    private func coverBlock() -> some View {
        cover()
            .clipShape(RoundedRectangle(cornerRadius: LibraryCardConfig.coverCorner, style: .continuous))
            // r010 (2026-07-22): 中の .fill 画像を hit 対象外にした分、ジャケット Button の
            // 当たり判定を可視枠で明示する (吸収体は殺し、正規のタップは枠通りに通す)
            .contentShape(RoundedRectangle(cornerRadius: LibraryCardConfig.coverCorner, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if meta.isAnimatedGallery {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(.black.opacity(0.65))
                        .clipShape(Circle())
                        .padding(2)
                }
            }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            if let onCover {
                Button(action: onCover) { coverBlock() }
                    .buttonStyle(.pressable)
                    // 診断 2026-07-22: ジャケット Button の実登録 frame (吸収体特定用)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
                        if UserDefaults.standard.bool(forKey: "tapDiagEnabled") {
                            LogManager.shared.log("TapDiag", "jacketFrame gid=\(meta.gid) (\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))")
                        }
                    }
            } else {
                coverBlock()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(meta.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text("\(meta.pageCount) ページ")
                    Text("・")
                    Text(meta.downloadDate, style: .date)
                    if meta.isNhentai {
                        TintedBadge(text: "NH", color: .orange, font: .system(size: 8, weight: .semibold))
                    }
                    if showExtBadge {
                        TintedBadge(text: "EXT", color: .purple, font: .system(size: 8, weight: .semibold))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // 田中報告 2026-07-21: 「読む」ボタンを 44pt 化した分メタ行が圧迫され
                // 「300 ペー/ジ」のように折り返した。1行固定 + 縮小で収める。
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 8)

            Button(action: onRead) {
                Text("読む")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
                    // 監査B5 (HIG: ヒット領域 ≥44×44pt)。カプセルの見た目は据え置き、
                    // タップ可能領域だけ 44pt へ拡張。
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
    }
}

/// タイル部。序盤ページを列割れなく陳列。可視時 decode / 画面外 cancel・解放 (指示書 B-4)。
struct CardTileGrid: View {
    let meta: DownloadedGallery
    let tileCount: Int
    let onTapPage: (Int) -> Void
    var zoomNamespace: Namespace.ID? = nil

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: LibraryCardConfig.tileColumns)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<tileCount, id: \.self) { index in
                CardTile(gid: meta.gid, index: index, zoomNamespace: zoomNamespace) {
                    onTapPage(index)
                }
            }
        }
    }
}

/// タイル1枚。共通パイプライン (LibraryThumbDecoder) で downsample decode、
/// onDisappear で Task cancel + 解放。
struct CardTile: View {
    let gid: Int
    let index: Int
    var zoomNamespace: Namespace.ID? = nil
    let onTap: () -> Void

    @State private var image: PlatformImage?
    @State private var loadTask: Task<Void, Never>?
    @State private var shown = false   // 監査B2: decode 完了後の fade-in 用
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                // 田中報告 2026-07-21: タイルがカード幅を突き破って画面端まで溢れ 3列グリッドが崩れた。
                // 原因は ZStack 直下の .fill 画像が ZStack 自身のサイズを押し広げていたこと。
                // プレースホルダで枠を確定させ、画像は overlay + clipped で枠内に閉じ込める。
                Color.gray.opacity(0.15)
                    .frame(maxWidth: .infinity)
                    .frame(height: LibraryCardConfig.tileHeight)
                    .overlay {
                        if let image {
                            Image(platformImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .opacity(shown ? 1 : 0)
                                // 2026-07-22 iPad「当たり判定がごく一部」事件の真因対策:
                                // .fill 画像は枠外に±100pt あふれ、.clipped() は描画しか切らない。
                                // あふれた不可視領域が後続行の Button の当たり判定として上の行を
                                // 覆い、上段タイル/ジャケット/読むボタンのタップを全部殺していた
                                // (simTap は発火・Button のみ死亡、最下段だけ生存、で機序確定)。
                                // 装飾画像はヒットテストから外し、当たり判定を可視枠に一致させる。
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .buttonStyle(.pressable)
        // 診断 2026-07-22: Button が発火しない領域でもジェスチャ系が触知できているかの分離判定。
        // simultaneousGesture は Button と競合しない (発火したら両方のログが出るのが正常)。
        .simultaneousGesture(TapGesture().onEnded {
            if UserDefaults.standard.bool(forKey: "tapDiagEnabled") {
                LogManager.shared.log("TapDiag", "simTap gid=\(gid) idx=\(index)")
            }
        })
        // B3: zoom 遷移の source。sourceID は DownloadsView 側の "gid-p<page>" と一致させる。
        .modifier(ZoomSourceModifier(namespace: zoomNamespace, id: "\(gid)-p\(index)"))
        // 診断 2026-07-22 (iPad 当たり判定極小): タイル Button の実登録 frame を記録し、
        // TapDiag の着弾座標と突き合わせる (ズレ=ジオメトリ desync / 一致=上に吸収体)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
            if UserDefaults.standard.bool(forKey: "tapDiagEnabled") {
                LogManager.shared.log("TapDiag", "tileFrame gid=\(gid) idx=\(index) (\(Int(rect.minX)),\(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))")
            }
        }
        .onAppear { startLoad() }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            image = nil
            shown = false   // 再表示時に再度 fade-in させる
        }
    }

    private func startLoad() {
        guard image == nil, loadTask == nil else { return }
        let url = DownloadManager.shared.imageFilePath(gid: gid, page: index)
        loadTask = Task.detached(priority: .userInitiated) {
            let decoded = LibraryThumbDecoder.decode(url: url, maxPixel: LibraryCardConfig.tileMaxPixel)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.image = decoded
                self.loadTask = nil
                // B2: decode 完了で fade-in (150ms ease-out)。ReduceMotion 時は即表示。
                if reduceMotion {
                    self.shown = true
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { self.shown = true }
                }
            }
        }
    }
}

/// zoom 遷移の source を条件付きで付ける (namespace が無ければ no-op)。
/// matchedTransitionSource は iOS 18+ (本 target は 18.0)。
struct ZoomSourceModifier: ViewModifier {
    let namespace: Namespace.ID?
    let id: String

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}
