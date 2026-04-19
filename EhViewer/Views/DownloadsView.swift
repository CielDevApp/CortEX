import SwiftUI
import UniformTypeIdentifiers

struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @State private var exportShareItem: ShareableURL?
    @State private var showImportPicker = false
    @State private var importMessage: String?
    @State private var highlightedGid: Int?
    @State private var readerMeta: DownloadedGallery?
    @State private var liveReaderMeta: DownloadedGallery?
    @State private var tabBarHidden = false

    private var activeList: [(gid: Int, progress: DownloadManager.DownloadProgress)] {
        manager.activeDownloads.sorted(by: { $0.key < $1.key }).map { (gid: $0.key, progress: $0.value) }
    }

    private var completedList: [DownloadedGallery] {
        manager.downloads.values
            .filter { $0.isComplete }
            .sorted(by: { $0.downloadDate > $1.downloadDate })
    }

    private var incompleteList: [DownloadedGallery] {
        manager.downloads.values
            .filter { !$0.isComplete && manager.activeDownloads[$0.gid] == nil }
            .sorted(by: { $0.downloadDate > $1.downloadDate })
    }

    var body: some View {
        NavigationStack {
            List {
                // ダウンロード中
                if !activeList.isEmpty {
                    Section("ダウンロード中") {
                        ForEach(activeList, id: \.gid) { item in
                            downloadingRow(gid: item.gid, progress: item.progress)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let meta = manager.downloads[item.gid] {
                                        liveReaderMeta = meta
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        manager.cancelDownload(gid: item.gid)
                                    } label: {
                                        Label("ダウンロード中止", systemImage: "stop.circle")
                                    }
                                    Button(role: .destructive) {
                                        manager.cancelDownload(gid: item.gid)
                                        manager.deleteDownload(gid: item.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }

                // ダウンロード済み
                if !completedList.isEmpty {
                    Section("保存済み (\(completedList.count))") {
                        ForEach(completedList) { meta in
                            completedRow(meta: meta)
                                .contextMenu {
                                    Button {
                                        if let url = GalleryExporter.exportAsZip(gid: meta.gid) {
                                            exportShareItem = ShareableURL(url: url)
                                        }
                                    } label: {
                                        Label("エクスポート", systemImage: "square.and.arrow.up")
                                    }
                                    Button(role: .destructive) {
                                        manager.deleteDownload(gid: meta.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        manager.deleteDownload(gid: meta.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }

                // 未完了
                if !incompleteList.isEmpty {
                    Section {
                        ForEach(incompleteList) { meta in
                            incompleteRow(meta: meta)
                                .contextMenu {
                                    Button {
                                        manager.markAsCompleteIgnoringMissing(gid: meta.gid)
                                    } label: {
                                        Label("強制完了（欠落ページを無視）", systemImage: "checkmark.circle")
                                    }
                                    Button(role: .destructive) {
                                        manager.deleteDownload(gid: meta.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        manager.deleteDownload(gid: meta.gid)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("未完了")
                            Spacer()
                            Button {
                                manager.resumeAllIncomplete()
                            } label: {
                                Label("すべて再開", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                        }
                    }
                }

                if manager.downloads.isEmpty && manager.activeDownloads.isEmpty {
                    ContentUnavailableView {
                        Label("保存済みギャラリーがありません", systemImage: "arrow.down.circle")
                    } description: {
                        Text("ギャラリー詳細画面からダウンロードできます")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("保存済み")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(tabBarHidden ? .hidden : .visible, for: .tabBar)
            .animation(.smooth(duration: 0.25), value: tabBarHidden)
            #endif
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { oldVal, newVal in
                let delta = newVal - oldVal
                if abs(delta) > 100 { return }
                if delta > 8 { tabBarHidden = true }
                else if delta < -5 { tabBarHidden = false }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showImportPicker = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImportPicker,
                allowedContentTypes: [.zip, .archive, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if GalleryExporter.importFromZip(url: url) != nil {
                        importMessage = "インポート完了"
                    } else {
                        importMessage = "インポート失敗"
                    }
                }
            }
            .sheet(item: $exportShareItem) { item in
                ActivityView(activityItems: [item.url])
            }
            #if os(iOS)
            .fullScreenCover(item: $readerMeta) { meta in
                LocalReaderView(meta: meta)
            }
            .fullScreenCover(item: $liveReaderMeta) { meta in
                LocalReaderView(meta: meta, isLiveDownload: true)
            }
            #endif
            .alert("インポート", isPresented: .constant(importMessage != nil)) {
                Button("OK") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
            .onChange(of: manager.lastImportedGid) { _, gid in
                guard let gid else { return }
                withAnimation(.easeInOut(duration: 0.4)) { highlightedGid = gid }
                // 3秒後にハイライト解除
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeOut(duration: 0.6)) { highlightedGid = nil }
                    manager.lastImportedGid = nil
                }
            }
            .onAppear {
                // タブ遷移後にハイライト開始
                if let gid = manager.lastImportedGid {
                    withAnimation(.easeInOut(duration: 0.4)) { highlightedGid = gid }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation(.easeOut(duration: 0.6)) { highlightedGid = nil }
                        manager.lastImportedGid = nil
                    }
                }
            }
        }
    }

    // MARK: - ダウンロード中の行

    @ViewBuilder
    private func downloadingRow(gid: Int, progress: DownloadManager.DownloadProgress) -> some View {
        let title = manager.downloads[gid]?.title ?? "ダウンロード中..."
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                coverThumbnail(gid: gid)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline)
                            .lineLimit(2)
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("\(progress.current) / \(progress.total) ページ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            let remainingPages = max(progress.total - progress.current, 0)
                            if remainingPages > 0 {
                                Text("残り\(remainingPages)枚")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                        }
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            let live = manager.liveDownloadedBytes(gid: gid)
                            let estimated = manager.estimatedTotalBytes(gid: gid, totalPages: progress.total, currentPages: progress.current)
                            let bps = BackgroundDownloadManager.shared.sampleBytesPerSecond(for: gid)
                            HStack(spacing: 6) {
                                if let est = estimated, est > live {
                                    let remaining = est - live
                                    Text("残り ~\(formatByteSize(remaining))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.primary)
                                    if bps > 0 {
                                        let etaSec = Int(Double(remaining) / Double(bps))
                                        Text(formatETA(etaSec))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.green)
                                    }
                                }
                                if bps > 0 {
                                    Text(formatSpeed(bps))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
                Spacer()
                Button {
                    manager.cancelDownload(gid: gid)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            ProgressView(value: progress.fraction)
                .tint(.blue)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 完了済みの行

    @ViewBuilder
    private func completedRow(meta: DownloadedGallery) -> some View {
        let isHighlighted = highlightedGid == meta.gid
        Button {
            readerMeta = meta
        } label: {
            HStack(spacing: 10) {
                coverThumbnail(gid: meta.gid)
                    .overlay(alignment: .bottomTrailing) {
                        if meta.isAnimatedGallery {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.black.opacity(0.65))
                                .clipShape(Circle())
                                .padding(2)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(meta.title)
                            .font(.subheadline)
                            .lineLimit(2)
                        if isHighlighted {
                            Text("NEW")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 4) {
                        Text("\(meta.pageCount) ページ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if meta.isNhentai {
                            Text("NH")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text(meta.downloadDate, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            isHighlighted ? Color.green.opacity(0.12) : nil
        )
    }

    // MARK: - 未完了の行

    @ViewBuilder
    private func incompleteRow(meta: DownloadedGallery) -> some View {
        HStack(spacing: 10) {
            coverThumbnail(gid: meta.gid)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(meta.downloadedPages.count) / \(meta.pageCount) ページ")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button {
                let gallery = Gallery(
                    gid: meta.gid, token: meta.token,
                    title: meta.title, category: nil, coverURL: nil,
                    rating: 0, pageCount: meta.pageCount,
                    postedDate: "", uploader: nil, tags: []
                )
                manager.startDownload(gallery: gallery, host: .exhentai)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 速度フォーマット

    private func formatSpeed(_ bytesPerSec: Int64) -> String {
        let b = Double(bytesPerSec)
        if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0f KB/s", b / 1_000) }
        return "\(bytesPerSec) B/s"
    }

    private func formatByteSize(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1_073_741_824 { return String(format: "%.2f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1_024 { return String(format: "%.0f KB", b / 1_024) }
        return "\(bytes) B"
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "約\(h)h\(m)m"
        }
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return "約\(m)分\(s)秒"
        }
        return "約\(seconds)秒"
    }

    // MARK: - カバーサムネイル

    @ViewBuilder
    private func coverThumbnail(gid: Int) -> some View {
        if let cover = manager.loadCoverImage(gid: gid) {
            Image(platformImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 50, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 50, height: 70)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - ヘルパー

struct ShareableURL: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit)
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
