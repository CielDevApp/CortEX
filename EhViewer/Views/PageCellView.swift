import SwiftUI

/// リーダーの1ページセル（PageImageHolderを個別に監視してre-render最小化）
struct PageCellView: View {
    @ObservedObject var holder: PageImageHolder
    let index: Int
    let isPlaceholder: Bool
    let qualityMode: Int
    let verticalSizeClass: UserInterfaceSizeClass?
    let onTap: (PlatformImage) -> Void
    let onRetry: () -> Void

    var isHorizontalMode: Bool = false

    /// 横モード用: 表示中の画像を保持（差し替え時のリサイズ防止）
    @State private var displayImage: PlatformImage?
    @State private var displaySize: CGSize = .zero

    var body: some View {
        if isHorizontalMode {
            horizontalBody
        } else {
            verticalBody
        }
    }

    // MARK: - 横モード（画像差し替え制御あり）

    private static var screenSize: CGSize {
        #if os(iOS)
        UIScreen.main.bounds.size
        #else
        CGSize(width: 1200, height: 800)
        #endif
    }

    private var horizontalBody: some View {
        ZStack {
            if let img = displayImage {
                Image(platformImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                    .drawingGroup()
                    .transition(.identity)
            } else if holder.isFailed {
                failedView
            } else {
                loadingView
            }

            if isPlaceholder && qualityMode >= 2 && displayImage != nil {
                VStack {
                    Spacer()
                    ProgressView().scaleEffect(0.6).tint(.white)
                        .padding(6).background(.black.opacity(0.4)).clipShape(Circle())
                        .padding(.bottom, 8)
                }
            }

            if holder.isTranslating {
                translatingBadge
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let img = displayImage, verticalSizeClass == .regular {
                onTap(img)
            }
        }
        .onChange(of: holder.image) { _, newImage in
            guard let newImage else { return }
            if displayImage == nil {
                // 初回: 即セット（サムネ画質）
                displayImage = newImage
                return
            }
            // 2回目以降: プレースホルダー（サムネ画質）から実画像に差し替える場合のみ更新
            // 同サイズ画像同士での差し替えはスキップ（リサイズ防止）
            if isPlaceholder || holder.isPlaceholder {
                displayImage = newImage
            } else if newImage.pixelWidth != displayImage?.pixelWidth || newImage.pixelHeight != displayImage?.pixelHeight {
                displayImage = newImage
            }
        }
        .onAppear {
            if displayImage == nil, let img = holder.image {
                displayImage = img
            }
        }
    }

    // MARK: - 縦モード（従来通り）

    private var verticalBody: some View {
        Group {
            if let image = holder.image {
                ZStack(alignment: .top) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)

                    if isPlaceholder && qualityMode >= 2 {
                        VStack {
                            Spacer()
                            ProgressView().scaleEffect(0.6).tint(.white)
                                .padding(6).background(.black.opacity(0.4)).clipShape(Circle())
                                .padding(.bottom, 8)
                        }
                    }

                    if holder.isTranslating {
                        translatingBadge
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if verticalSizeClass == .regular { onTap(image) }
                }
            } else if holder.isFailed {
                failedView
            } else {
                loadingView
            }
        }
    }

    // MARK: - 共通サブビュー

    private var failedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title)
            Text("ページ \(index + 1) の読み込みに失敗").font(.subheadline)
            if let reason = holder.failReason {
                Text(reason).font(.caption2).foregroundStyle(.gray)
            }
            Button {
                onRetry()
            } label: {
                Label("再試行", systemImage: "arrow.clockwise")
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent).tint(.blue)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: isHorizontalMode ? .infinity : nil, alignment: .center)
        .frame(minHeight: 300)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("ページ \(index + 1)").font(.caption).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: isHorizontalMode ? .infinity : nil, alignment: .center)
        .frame(minHeight: 300)
    }

    private var translatingBadge: some View {
        HStack(spacing: 4) {
            ProgressView().scaleEffect(0.5).tint(.white)
            Text("Translating...").font(.caption2).foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.5)).clipShape(Capsule())
        .padding(.top, 8)
    }
}
