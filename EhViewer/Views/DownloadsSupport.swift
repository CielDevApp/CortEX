import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - DownloadsView 補助型 (A3-b で DownloadsView.swift から退去、挙動変更なし)

struct ShareableURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// エクスポート進捗（SwiftUI @State 要件で Equatable 必須）
struct ExportProgress: Equatable {
    let done: Int
    let total: Int
}

/// エクスポートの段階的フェーズ。
/// 100% 到達 → `preparingSheet` で「共有シートを準備中…」を数秒表示、
/// iOS ActivityViewController の準備遅延で「失敗したかと思った」錯覚を防ぐ。
enum ExportPhase: Equatable {
    case processing(ExportProgress)
    case preparingSheet
}

#if canImport(UIKit)
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    /// activity 完了（成功 / キャンセル両方）で発火。tmp ファイル削除用。
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - 保存済みギャラリーの長押しプレビュー

/// 保存済み作品の全ページサムネグリッド。既存 GalleryPreviewOverlay / NhentaiPreviewOverlay と
/// 同じ UI 骨格だが、サムネ源がディスク画像（ネット取得 URL 不要）な点が違う。
struct LocalPreviewOverlay: View {
    let meta: DownloadedGallery
    let onDismiss: () -> Void
    /// タップされたページ index (0-indexed) を親に返す
    let onTapPage: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 6)]

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack {
                    Text(meta.title)
                        .font(.caption.bold())
                        .lineLimit(2)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()

                Divider()

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(0..<meta.pageCount, id: \.self) { index in
                            LocalThumbCell(gid: meta.gid, index: index) {
                                onTapPage(index)
                            }
                        }
                    }
                    .padding()
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
            .frame(maxWidth: 600, maxHeight: 600)
            .padding()
        }
    }
}

/// 保存済みギャラリーの 1 ページサムネセル。
/// ディスクから CGImageSourceCreateThumbnailAtIndex で 240px 縮小し、
/// アニメ WebP なら紫枠 + ▶アイコンで識別可能にする。
struct LocalThumbCell: View {
    let gid: Int
    let index: Int
    let onTap: () -> Void

    /// セル高さ（縦長固定）。adaptive(80-120px) の列幅に対して 140 高で portrait 比率になる。
    /// 縦長/横長どちらの元画像も .aspectRatio(.fill) + .clipped() で中心クロップし統一。
    static let cellHeight: CGFloat = 140

    @State private var thumbImage: PlatformImage?
    @State private var isAnimated: Bool = false

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let img = thumbImage {
                        Image(platformImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: Self.cellHeight, maxHeight: Self.cellHeight)
                            .clipped()
                    } else {
                        Color.gray.opacity(0.2)
                            .frame(height: Self.cellHeight)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                    if isAnimated {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.cellHeight, maxHeight: Self.cellHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if isAnimated {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.purple, lineWidth: 2)
                    }
                }

                Text("\(index + 1)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .buttonStyle(.plain)
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        guard thumbImage == nil else { return }
        let url = DownloadManager.shared.imageFilePath(gid: gid, page: index)
        Task.detached(priority: .userInitiated) {
            let animated = WebPFileDetector.isAnimatedWebP(url: url)
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 240
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                await MainActor.run { self.isAnimated = animated }
                return
            }
            #if canImport(UIKit)
            let img = UIImage(cgImage: cg)
            #else
            let img = NSImage(cgImage: cg, size: .zero)
            #endif
            await MainActor.run {
                self.thumbImage = img
                self.isAnimated = animated
            }
        }
    }
}

/// ライブラリ → 作品詳細 sheet 用の NavigationStack ラッパー。
/// FavoritesView と同じく navPathBox + Gallery/NhGallery destination 一式を備え、
/// タグ検索結果からの作品タップで詳細を push できるようにする。
struct DetailSheetNavStack<Content: View>: View {
    var dismiss: () -> Void
    @ViewBuilder var content: () -> Content
    @StateObject private var navPathBox = NavigationPathBox()

    var body: some View {
        NavigationStack(path: $navPathBox.path) {
            content()
                .navigationDestination(for: Gallery.self) { gallery in
                    GalleryDetailView(gallery: gallery, host: .exhentai)
                }
                .navigationDestination(for: NhentaiClient.NhGallery.self) { nh in
                    NhentaiDetailView(gallery: nh)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる", action: dismiss)
                    }
                }
        }
        .environment(\.navPathBox, navPathBox)
    }
}
