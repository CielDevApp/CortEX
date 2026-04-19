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
    /// アニメ再生する（現在表示ページ/currentIndex == index）
    var isActiveAnimation: Bool = false
    /// MP4 変換用の gid（アニメ画像検知時のみ利用）
    var mp4Gid: Int = 0
    #if canImport(UIKit)
    var onTapAnimated: ((AnimatedImageSource) -> Void)? = nil
    #endif

    var body: some View {
        if isHorizontalMode {
            horizontalBody
        } else {
            verticalBody
        }
    }

    // MARK: - 横モード（holder.image直接参照、verticalBodyと同じ方式）

    private static var screenSize: CGSize {
        #if os(iOS)
        UIScreen.main.bounds.size
        #else
        CGSize(width: 1200, height: 800)
        #endif
    }

    private var horizontalBody: some View {
        ZStack {
            #if canImport(UIKit)
            if let animSrc = holder.animatedSource {
                AnimatedVideoView(sourceData: animSrc.rawData, gid: mp4Gid, page: index, autoStart: false)
                    .aspectRatio(animSrc.pixelSize, contentMode: .fit)
                    .frame(width: Self.screenSize.width, height: Self.screenSize.height)
            } else if let image = holder.image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.screenSize.width, height: Self.screenSize.height)
            } else if holder.isFailed {
                failedView
            } else {
                loadingView
            }
            #else
            if let image = holder.image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.screenSize.width, height: Self.screenSize.height)
            } else if holder.isFailed {
                failedView
            } else {
                loadingView
            }
            #endif

            if isPlaceholder && qualityMode >= 2 && holder.image != nil {
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
            if let img = holder.image, verticalSizeClass == .regular {
                onTap(img)
            }
        }
    }

    // MARK: - 縦モード（従来通り）

    private var verticalBody: some View {
        Group {
            #if canImport(UIKit)
            if let animSrc = holder.animatedSource {
                AnimatedVideoView(sourceData: animSrc.rawData, gid: mp4Gid, page: index, autoStart: false)
                    .aspectRatio(animSrc.pixelSize, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if verticalSizeClass == .regular {
                            if let cb = onTapAnimated { cb(animSrc) }
                            else if let img = holder.image { onTap(img) }
                        }
                    }
            } else if let image = holder.image {
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
            #else
            if let image = holder.image {
                ZStack(alignment: .top) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
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
            #endif
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
