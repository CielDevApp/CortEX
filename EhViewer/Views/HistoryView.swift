import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = HistoryManager.shared
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                if history.isEmpty {
                    ContentUnavailableView {
                        Label("閲覧履歴がありません", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("ギャラリーを読むと履歴に記録されます")
                    }
                }

                ForEach(history.mergedItems) { item in
                    switch item {
                    case .eh(let entry):
                        NavigationLink(value: history.toGallery(entry)) {
                            ehHistoryRow(entry: entry)
                        }
                    case .nh(let entry):
                        NavigationLink(value: entry.gallery) {
                            nhHistoryRow(entry: entry)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("履歴")
            .toolbar {
                if !history.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .alert("全履歴を削除", isPresented: $showClearConfirm) {
                Button("削除", role: .destructive) {
                    history.clearAll()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("閲覧履歴をすべて削除します。この操作は取り消せません。")
            }
            .navigationDestination(for: Gallery.self) { gallery in
                GalleryDetailView(gallery: gallery, host: .exhentai)
            }
            .navigationDestination(for: NhentaiClient.NhGallery.self) { nh in
                NhentaiDetailView(gallery: nh)
            }
            .navigationDestination(for: CategoryFilter.self) { filter in
                TagSearchResultView(searchQuery: filter.query, host: .exhentai, title: filter.displayTitle)
            }
            .navigationDestination(for: TagSearch.self) { search in
                TagSearchResultView(searchQuery: search.query, host: .exhentai, title: search.displayTitle)
            }
            .navigationDestination(for: UploaderSearch.self) { search in
                TagSearchResultView(searchQuery: search.query, host: .exhentai, title: search.displayTitle)
            }
        }
    }

    @ViewBuilder
    private func ehHistoryRow(entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            CachedImageView(url: entry.coverURL, host: .exhentai)
                .frame(width: 80, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(3)

                Spacer()

                if let catName = entry.category, let cat = GalleryCategory(rawValue: catName) {
                    Text(cat.rawValue)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: cat.color))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack {
                    if entry.lastReadPage > 0 {
                        Label("\(entry.lastReadPage + 1)/\(entry.pageCount)P", systemImage: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if entry.pageCount > 0 {
                        Label("\(entry.pageCount)P", systemImage: "doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text(entry.viewedDate, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                + Text(" 前")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func nhHistoryRow(entry: NhHistoryEntry) -> some View {
        HStack(spacing: 12) {
            if let cover = entry.gallery.images?.cover {
                AsyncImage(url: NhentaiClient.coverURL(mediaId: entry.gallery.media_id, ext: cover.ext)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.15)
                }
                .frame(width: 80, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 80, height: 110)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.gallery.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(3)

                Spacer()

                // nhentaiバッジ
                Text("nhentai")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                HStack {
                    if entry.lastReadPage > 0 {
                        Label("\(entry.lastReadPage + 1)/\(entry.gallery.num_pages)P", systemImage: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if entry.gallery.num_pages > 0 {
                        Label("\(entry.gallery.num_pages)P", systemImage: "doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text(entry.viewedDate, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                + Text(" 前")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
