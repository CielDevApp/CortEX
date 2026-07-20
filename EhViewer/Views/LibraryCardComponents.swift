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
                CardTileGrid(meta: meta, tileCount: tileCount, onTapPage: onTapPage)
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
            }

            Spacer(minLength: 8)

            Button(action: onRead) {
                Text("読む")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
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

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: LibraryCardConfig.tileColumns)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<tileCount, id: \.self) { index in
                CardTile(gid: meta.gid, index: index) {
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
    let onTap: () -> Void

    @State private var image: PlatformImage?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image {
                        Image(platformImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.15)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: LibraryCardConfig.tileHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

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
        .onAppear { startLoad() }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            image = nil
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
            }
        }
    }
}
