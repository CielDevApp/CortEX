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
    /// アニメビュー長押し時に親ビューのツールバー表示を切替える
    var onToggleControls: (() -> Void)? = nil
    /// true = GalleryReader 経由、アニメ WebP は全て ▶ ボタン手動再生扱い
    /// false = LocalReader / NhentaiReader 経由、既存の自動再生挙動維持
    var manualPlayForAnimated: Bool = false
    /// 動画ページ専用 HDR 補正 (AVPlayer で videoComposition 経由)。静止画は既存 hdrEnhancement とは別系統。
    var isAnimationHDREnabled: Bool = false
    /// 動画ページ長押しメニュー: UI 非表示
    var onHideUI: (() -> Void)? = nil
    /// 動画ページ長押しメニュー: HDR トグル
    var onToggleAnimationHDR: (() -> Void)? = nil

    /// このページが動画 WebP かどうか (long-press context menu 表示判定用)
    private var isAnimatedPage: Bool {
        holder.animatedFileURL != nil || holder.animatedWebPData != nil
    }

    var body: some View {
        if isHorizontalMode {
            horizontalBody
        } else {
            verticalBody
        }
    }

    /// 動画ページ専用 context menu。静止画ページには適用しない（spec 禁則）。
    @ViewBuilder
    private func animatedContextMenuItems() -> some View {
        Button {
            onHideUI?()
        } label: {
            Label("UI 非表示", systemImage: "eye.slash")
        }
        Button {
            onToggleAnimationHDR?()
        } label: {
            Label(isAnimationHDREnabled ? "HDR 無効化" : "HDR 有効化",
                  systemImage: isAnimationHDREnabled ? "sparkles.slash" : "sparkles")
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
            if let animURL = holder.animatedFileURL {
                if manualPlayForAnimated {
                    GalleryAnimatedWebPView(
                        source: .url(animURL),
                        staticImage: holder.image,
                        gid: mp4Gid,
                        page: index,
                        onToggleControls: onToggleControls,
                        isHDREnabled: isAnimationHDREnabled
                    )
                    .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                    .contextMenu { animatedContextMenuItems() }
                } else {
                    AnimatedVideoView(sourceURL: animURL, gid: mp4Gid, page: index, onToggleControls: onToggleControls, isHDREnabled: isAnimationHDREnabled)
                        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                        .contextMenu { animatedContextMenuItems() }
                }
            } else if let animData = holder.animatedWebPData {
                GalleryAnimatedWebPView(
                    source: .data(animData),
                    staticImage: holder.image,
                    gid: mp4Gid,
                    page: index,
                    onToggleControls: onToggleControls,
                    isHDREnabled: isAnimationHDREnabled
                )
                .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                .contextMenu { animatedContextMenuItems() }
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
            if let animURL = holder.animatedFileURL {
                if manualPlayForAnimated {
                    GalleryAnimatedWebPView(
                        source: .url(animURL),
                        staticImage: holder.image,
                        gid: mp4Gid,
                        page: index,
                        onToggleControls: onToggleControls,
                        isHDREnabled: isAnimationHDREnabled
                    )
                    .frame(maxWidth: .infinity)
                    .contextMenu { animatedContextMenuItems() }
                } else {
                    AnimatedVideoView(sourceURL: animURL, gid: mp4Gid, page: index, onToggleControls: onToggleControls, isHDREnabled: isAnimationHDREnabled)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if verticalSizeClass == .regular, let img = holder.image { onTap(img) }
                        }
                        .contextMenu { animatedContextMenuItems() }
                }
            } else if let animData = holder.animatedWebPData {
                GalleryAnimatedWebPView(
                    source: .data(animData),
                    staticImage: holder.image,
                    gid: mp4Gid,
                    page: index,
                    onToggleControls: onToggleControls,
                    isHDREnabled: isAnimationHDREnabled
                )
                .frame(maxWidth: .infinity)
                .contextMenu { animatedContextMenuItems() }
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
