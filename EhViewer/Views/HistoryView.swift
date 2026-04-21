import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = HistoryManager.shared
    @State private var showClearConfirm = false
    @State private var navPath = NavigationPath()
    @State private var previewEhGallery: Gallery?
    @State private var previewNhGallery: NhentaiClient.NhGallery?
    @State private var previewEhReader: GalleryPreviewReaderRequest?
    @State private var previewNhReader: NhentaiPreviewReaderRequest?

    var body: some View {
        NavigationStack(path: $navPath) {
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
                        let g = history.toGallery(entry)
                        ehHistoryRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { navPath.append(g) }
                            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 15) {
                                #if canImport(UIKit)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                #endif
                                previewEhGallery = g
                            }
                    case .nh(let entry):
                        nhHistoryRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { navPath.append(entry.gallery) }
                            .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 15) {
                                #if canImport(UIKit)
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                #endif
                                previewNhGallery = entry.gallery
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
            .overlay {
                if let g = previewEhGallery {
                    GalleryPreviewOverlay(
                        gallery: g,
                        host: .exhentai,
                        onDismiss: { previewEhGallery = nil },
                        onTapPage: { thumbnails, page in
                            previewEhReader = GalleryPreviewReaderRequest(gallery: g, page: page, thumbnails: thumbnails)
                        }
                    )
                }
                if let nh = previewNhGallery {
                    NhentaiPreviewOverlay(
                        gallery: nh,
                        onDismiss: { previewNhGallery = nil },
                        onTapPage: { loadedGallery, page in
                            previewNhReader = NhentaiPreviewReaderRequest(gallery: loadedGallery, page: page)
                        }
                    )
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $previewEhReader) { req in
                GalleryReaderView(gallery: req.gallery, host: .exhentai, initialPage: req.page, thumbnails: req.thumbnails)
                    .onAppear {
                        HistoryManager.shared.record(gallery: req.gallery, page: req.page)
                        previewEhGallery = nil
                    }
            }
            .fullScreenCover(item: $previewNhReader) { req in
                NhentaiReaderView(gallery: req.gallery, initialPage: req.page)
                    .onAppear {
                        HistoryManager.shared.recordNhentai(gallery: req.gallery, page: req.page)
                        previewNhGallery = nil
                    }
            }
            #endif
        }
    }

    @ViewBuilder
    private func ehHistoryRow(entry: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            CachedImageView(url: entry.coverURL, host: .exhentai, gid: entry.gid)
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
            // NhentaiCardViewと同じcache優先 + v2 path対応
            NhentaiCoverView(gallery: entry.gallery)
                .frame(width: 80, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6))

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
