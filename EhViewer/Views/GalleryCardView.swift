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

struct GalleryCardView: View {
    let gallery: Gallery
    @ObservedObject private var readHistory = ReadHistoryStore.shared
    @AppStorage(UDKey.grayOutReadGalleries) private var grayOutReadGalleries = true

    /// 既読グレー表示 (トグル OFF 中は抑制のみ、記録は残る)。判定は O(1)。
    private var isReadDimmed: Bool {
        grayOutReadGalleries && readHistory.isRead(site: .eh, gid: gallery.gid)
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedImageView(url: gallery.coverURL, host: .exhentai, gid: gallery.gid)
                .frame(width: 80, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(gallery.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(3)
                    .foregroundStyle(isReadDimmed ? Color.secondary : Color.primary)

                Spacer()

                HStack(spacing: 6) {
                    if let category = gallery.category {
                        Text(category.rawValue)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: category.color))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
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

                HStack(spacing: 8) {
                    if gallery.rating > 0 {
                        ratingStars(gallery.rating)
                    }
                    Spacer()
                    if gallery.pageCount > 0 {
                        Label("\(gallery.pageCount)P", systemImage: "doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !gallery.postedDate.isEmpty {
                    Text(gallery.postedDate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func ratingStars(_ rating: Double) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                let value = rating - Double(index)
                Image(systemName: value >= 1 ? "star.fill" : value >= 0.5 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
        }
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
