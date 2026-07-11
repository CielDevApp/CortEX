import SwiftUI

/// カテゴリ + language:japanese フィルタ用
struct CategoryFilter: Hashable {
    let category: GalleryCategory
    var query: String { "language:japanese" }
    var displayTitle: String { "\(category.rawValue) (日本語)" }
}

/// 投稿者の作品一覧検索用
struct UploaderSearch: Hashable {
    let uploader: String
    var query: String { "uploader:\(uploader)" }
    var displayTitle: String { uploader }
}

// MARK: - UI 刷新 共有コンポーネント (2026-07-03, ui-modern-redesign 案A)
// EhPanda (角丸15プレーン / カテゴリ色ベタ塗りラベル / 黄色星列) と被らない署名:
// continuous 角丸 + tinted capsule バッジ + 連続塗り率星バー + カバー上マテリアル P バッジ

enum CardDesign {
    static let cardCorner: CGFloat = 12
    static let coverCorner: CGFloat = 8

    static var cardBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var listBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemGroupedBackground)
        #else
        return Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    /// リスト行のカード化 (角丸 continuous + subtle shadow)
    @ViewBuilder
    static func cardChrome<V: View>(_ content: V) -> some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .fill(cardBackground)
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            )
    }
}

/// カテゴリ / NH バッジ: 色ベタ塗りから tinted capsule (背景 16% + 同色文字) へ
struct TintedBadge: View {
    let text: String
    let color: Color
    var font: Font = .caption2.weight(.semibold)

    var body: some View {
        Text(text)
            .font(font)
            // iOS 26 は幅が詰まると "Western" 等を中折りして 2 行化し、カード高さが
            // バラける (2026-07-11 田中報告、17e/iOS 26.5 で再発)。1 行固定 + 縮小で吸収。
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
    }
}

/// 連続塗り率の5星バー (半分星の段付き表現から脱却)
struct StarRatingBar: View {
    let rating: Double
    var size: CGFloat = 10

    private func stars(_ color: Color, filled: Bool) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { _ in
                Image(systemName: filled ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(color)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            stars(Color.secondary.opacity(0.35), filled: false)
            stars(.yellow, filled: true)
                .mask(
                    GeometryReader { geo in
                        Rectangle()
                            .frame(width: geo.size.width * min(max(rating, 0), 5) / 5)
                    }
                )
        }
    }
}

/// ローディング中ダミーの shimmer (キラキラ) 表現 (Phase 3, 田中要望 2026-07-03)。
/// ぐるぐる/進捗バーではなく、ベース色の上を斜めのハイライトが周期的に流れる
/// スケルトン UI。transform (offset) アニメーションのみなので GPU 合成で軽い。
/// shimmer 掃引オーバーレイ (高級版, 2026-07-03 v2)。
/// - 幅広 (幅の1.6倍) + 多段ストップのソフトな光 (硬い縁を作らない)
/// - 18° 傾けた帯 (単純な水平移動を避ける)
/// - smoothstep 加減速 + サイクル後半 45% は休止 (常時ギラつかせない)
/// - TimelineView 駆動: identity 再生成で死なず、全 shimmer が同位相で揃う
struct ShimmerSweep: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    // 田中調整 2026-07-03: 1.6s 周期・休止 30% (旧 2.4s/45% は発動が遅く、
                    // 高速回線だとプレースホルダが消えるまでに光が拝めなかった)
                    let cycle = CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
                    let raw = min(cycle / 0.7, 1.0)
                    let eased = raw * raw * (3 - 2 * raw)   // smoothstep
                    let w = geo.size.width
                    let h = geo.size.height
                    let band = w * 1.6
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.08), location: 0.30),
                            .init(color: .white.opacity(0.45), location: 0.50),
                            .init(color: .white.opacity(0.08), location: 0.70),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: band, height: h * 2.6)
                    .rotationEffect(.degrees(18))
                    .offset(
                        x: -band + (w + band * 2) * eased,
                        y: -h * 0.8
                    )
                    .allowsHitTesting(false)
                }
            }
            .clipped()
        }
    }
}

extension View {
    func shimmerSweep() -> some View { modifier(ShimmerSweep()) }
}

/// 単純ブロック用 shimmer (詳細画面のサムネ等)
struct ShimmerPlaceholder: View {
    var cornerRadius: CGFloat = CardDesign.cardCorner

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.gray.opacity(0.16))
            .shimmerSweep()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// グリッドのダミー用スケルトンカード: 実カードと同じ構造 (カバー + タイトル2行 +
/// バッジのモック) を同じカード chrome に載せ、shimmer を全体に掃引。
/// 読み込み完了時にそのまま実カードへ「化ける」見え方になる。
struct SkeletonCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.gray.opacity(0.16))
                .aspectRatio(2.0 / 3.0, contentMode: .fit)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.22))
                    .frame(height: 9)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.22))
                    .frame(height: 9)
                    .padding(.trailing, 44)
                Capsule()
                    .fill(Color.gray.opacity(0.22))
                    .frame(width: 52, height: 12)
            }
            .padding(8)
        }
        .background(CardDesign.cardBackground)
        .shimmerSweep()
        .clipShape(RoundedRectangle(cornerRadius: CardDesign.cardCorner, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

/// 詳細画面のセクションカード (GroupBox を Phase 1 のカード言語に統一、Phase 2)
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
                .font(.subheadline)
                .fontWeight(.semibold)
            configuration.content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CardDesign.cardCorner, style: .continuous)
                .fill(CardDesign.cardBackground)
                .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        )
    }
}

/// カバー右下のページ数バッジ (マテリアル capsule)
struct CoverPagesBadge: View {
    let pages: Int
    var fontSize: CGFloat = 9

    var body: some View {
        Text("\(pages)P")
            .font(.system(size: fontSize, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(4)
    }
}

struct GalleryCardView: View {
    let gallery: Gallery
    @ObservedObject private var readHistory = ReadHistoryStore.shared
    @AppStorage(UDKey.grayOutReadGalleries) private var grayOutReadGalleries = true

    /// 既読グレー表示 (トグル OFF 中は抑制のみ、記録は残る)。判定は O(1)。
    private var isReadDimmed: Bool {
        grayOutReadGalleries && readHistory.isRead(site: .eh, gid: gallery.gid)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CachedImageView(url: gallery.coverURL, host: .exhentai, gid: gallery.gid)
                .frame(width: 80, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: CardDesign.coverCorner, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: CardDesign.coverCorner, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                )
                .overlay(alignment: .bottomTrailing) {
                    if gallery.pageCount > 0 {
                        CoverPagesBadge(pages: gallery.pageCount)
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(gallery.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundStyle(isReadDimmed ? Color.secondary : Color.primary)

                HStack(spacing: 6) {
                    if let category = gallery.category {
                        TintedBadge(text: category.rawValue, color: Color(hex: category.color))
                    }

                    if let uploader = gallery.uploader, !uploader.isEmpty {
                        NavigationLink(value: UploaderSearch(uploader: uploader)) {
                            Text(uploader)
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    if gallery.rating > 0 {
                        StarRatingBar(rating: gallery.rating)
                        Text(String(format: "%.1f", gallery.rating))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !gallery.postedDate.isEmpty {
                        Text(gallery.postedDate)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 110)
        }
        .padding(.vertical, 4)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
