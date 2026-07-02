import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Phase G-A iPad-only パイロット (2026-04-26): EH/EXH ギャラリー一覧の iPad グリッド表示。
/// Mac / iPhone は既存 List のまま (シェイクスピア定理: 動いてるものは触らない)。
/// 今夜のスコープ:
/// - iPad のみ、横 6 列 / 縦 4 列、toggle なし (hardcode)
/// - GalleryScrollList のみ。nhentai は後日。

#if canImport(UIKit)
enum GalleryGridColumns {
    /// iPad: 4 列固定 (横向きでも縦向きでも 4)。田中確定 2026-04-27 (当初 regular=6/compact=4 から変更)。
    /// spacing 10: カード化 (Phase 1.5) の影が呼吸できる間隔。
    static func iPadColumns(horizontalSizeClass: UserInterfaceSizeClass?) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    }

    /// iPhone: 固定 3 列 (Amazon Prime Video iOS と同じ感覚)。田中確定 2026-04-27。
    static func iPhoneColumns() -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    }

    /// Mac Catalyst: ウィンドウ幅に応じて自動で列数調整 (最小 180pt)。
    /// .adaptive で SwiftUI がリサイズ追従、ユーザーの好みのウィンドウサイズで列数が変化。
    static func macColumns() -> [GridItem] {
        [GridItem(.adaptive(minimum: 180), spacing: 8)]
    }
}
#endif

/// E-Hentai / ExHentai のグリッド表示用セル (縦並び: カバー + タイトル + バッジ)。
/// 既存 GalleryCardView (横並び List 用) には触らない。
struct GalleryGridCellView: View {
    let gallery: Gallery
    @ObservedObject private var readHistory = ReadHistoryStore.shared
    @AppStorage(UDKey.grayOutReadGalleries) private var grayOutReadGalleries = true

    /// 既読グレー表示 (トグル OFF 中は抑制のみ、記録は残る)。判定は O(1)。
    private var isReadDimmed: Bool {
        grayOutReadGalleries && readHistory.isRead(site: .eh, gid: gallery.gid)
    }

    var body: some View {
        // UI 刷新 Phase 1.5 (2026-07-03): カバー主役のカード型。カバーがカード上面いっぱいに
        // 広がり、下の情報ストリップと一体で 1 枚のカードになる (App Store 風)。
        VStack(alignment: .leading, spacing: 0) {
            // セル幅に対し常に 2:3 比の枠を確保し、内部の画像は fill + clip で統一サイズに揃える。
            // 直接 .aspectRatio(.fill) を CachedImageView に付けるだけだとバラつく。
            Color.gray.opacity(0.15)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .overlay {
                    CachedImageView(url: gallery.coverURL, host: .exhentai, gid: gallery.gid)
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if gallery.pageCount > 0 {
                        CoverPagesBadge(pages: gallery.pageCount, fontSize: 8)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(gallery.title)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .foregroundStyle(isReadDimmed ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    if let category = gallery.category {
                        TintedBadge(
                            text: category.rawValue == "Doujinshi" ? "Doujin" : category.rawValue,
                            color: Color(hex: category.color),
                            font: .system(size: 8, weight: .semibold)
                        )
                    }
                    // レーティング (連続塗り率バー)。未評価(0)は非表示。
                    if gallery.rating > 0 {
                        StarRatingBar(rating: gallery.rating, size: 7)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
        }
        .background(CardDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CardDesign.cardCorner, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .contentShape(Rectangle())
    }
}

/// nhentai のグリッド表示用セル。NhentaiCardView と同じカバーロード戦略 (loadCover) を流用。
struct NhentaiGridCellView: View {
    let gallery: NhentaiClient.NhGallery
    @State private var coverImage: PlatformImage?
    @ObservedObject private var readHistory = ReadHistoryStore.shared
    @AppStorage(UDKey.grayOutReadGalleries) private var grayOutReadGalleries = true

    /// 既読グレー表示 (トグル OFF 中は抑制のみ、記録は残る)。判定は O(1)。
    private var isReadDimmed: Bool {
        grayOutReadGalleries && readHistory.isRead(site: .nh, gid: gallery.id)
    }

    var body: some View {
        // UI 刷新 Phase 1.5 (2026-07-03): カバー主役のカード型 (E-H 側と同型)
        VStack(alignment: .leading, spacing: 0) {
            Color.gray.opacity(0.15)
                .aspectRatio(2.0/3.0, contentMode: .fit)
                .overlay {
                    if let img = coverImage {
                        Image(platformImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if gallery.num_pages > 0 {
                        CoverPagesBadge(pages: gallery.num_pages, fontSize: 8)
                    }
                }
                .onAppear { loadCoverIfNeeded() }

            VStack(alignment: .leading, spacing: 4) {
                Text(gallery.displayTitle)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .foregroundStyle(isReadDimmed ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    TintedBadge(text: "NH", color: .orange, font: .system(size: 8, weight: .semibold))
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
        }
        .background(CardDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: CardDesign.cardCorner, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .contentShape(Rectangle())
    }

    private func loadCoverIfNeeded() {
        guard coverImage == nil else { return }
        let url: URL
        if let thumbPath = gallery.thumbnailPath {
            url = URL(string: "https://t.nhentai.net/\(thumbPath)")!
        } else if let cover = gallery.images?.cover {
            url = NhentaiClient.coverURL(mediaId: gallery.media_id, ext: cover.ext, path: cover.path)
        } else {
            return
        }

        if let cached = ImageCache.shared.image(for: url) {
            coverImage = cached
            return
        }

        Task {
            for attempt in 1...2 {
                let coverExt = gallery.images?.cover?.ext ?? "jpg"
                let coverPath = gallery.thumbnailPath ?? gallery.images?.cover?.path
                let galleryId = gallery.id
                let mediaId = gallery.media_id
                let capturedURL = url

                let decoded: PlatformImage? = await Task.detached(priority: .userInitiated) {
                    guard let data = try? await NhentaiClient.fetchCoverImage(
                        galleryId: galleryId, mediaId: mediaId,
                        ext: coverExt, path: coverPath
                    ) else { return nil }
                    return PlatformImage(data: data)
                }.value

                if let img = decoded {
                    ImageCache.shared.setThumb(img, for: capturedURL)
                    await MainActor.run { coverImage = img }
                    return
                }

                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 2_000_000_000...4_000_000_000))
                }
            }
        }
    }
}
