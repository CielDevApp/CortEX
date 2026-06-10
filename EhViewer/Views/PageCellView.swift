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

    /// 縦モード未ロードセル (loading/failed) の高さ推定用 aspect (height/width)。
    /// nil = 旧来の minHeight 300 を維持 (E-H 縦リーダー以外は挙動不変)。
    /// なぜ必要か: 未ロードセル 300pt → ロード後 ~550pt の高さ激変で LazyVStack の
    /// 推定レイアウトが崩れ、数百ページ目への scrollTo が先頭側へ吹き飛ぶため、
    /// 未ロード時点から実ページの想定高さを与えてレイアウトを安定させる。
    var estimatedAspect: CGFloat? = nil

    /// 静画と共通の HDR 設定 (設定画面の hdrEnhancement トグル)。
    /// 動画 AVPlayer 側はこの値を videoComposition に反映 (CIFilter 注入)。
    @AppStorage("hdrEnhancement") private var hdrEnhancement = false
    /// アニメ再生方式: "webp" (CADisplayLink 逐次) / "mp4" (旧来変換経路)
    @AppStorage("animPlaybackMode") private var animPlaybackMode = "webp"

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
            if let animURL = holder.animatedFileURL {
                if animPlaybackMode == "mp4" {
                    if manualPlayForAnimated {
                        GalleryAnimatedWebPView(
                            source: .url(animURL),
                            staticImage: holder.image,
                            gid: mp4Gid,
                            page: index,
                            onToggleControls: onToggleControls,
                            autoPlayIfActive: isActiveAnimation,
                            isHDREnabled: hdrEnhancement
                        )
                        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                    } else {
                        AnimatedVideoView(sourceURL: animURL, gid: mp4Gid, page: index, onToggleControls: onToggleControls, isHDREnabled: hdrEnhancement)
                            .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                    }
                } else {
                    BoomerangWebPView(sourceURL: animURL, readerID: "cell-\(mp4Gid)", pageIndex: index, staticPlaceholder: holder.image)
                        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                }
            } else if let animData = holder.animatedWebPData {
                if animPlaybackMode == "mp4" {
                    GalleryAnimatedWebPView(
                        source: .data(animData),
                        staticImage: holder.image,
                        gid: mp4Gid,
                        page: index,
                        onToggleControls: onToggleControls,
                        autoPlayIfActive: isActiveAnimation,
                        isHDREnabled: hdrEnhancement
                    )
                    .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                } else {
                    BoomerangWebPView(sourceData: animData, readerID: "cell-\(mp4Gid)", pageIndex: index, staticPlaceholder: holder.image)
                        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                }
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

            // DL進捗バー (田中要望 2026-06-09)。holder.loadProgress だけでゲート → サムネ表示
            // (placeholder) / loadingView どちらの分岐でも出る。isPlaceholder 定数 (親から渡される
            // viewModel.isPlaceholder) に依存していたのがバー非表示の真因だった (実機ログで確認:
            // loadProgress は届いていたが isPlaceholder=false で弾かれていた)。
            if holder.loadProgress > 0 && holder.loadProgress < 1 {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.6).tint(.white)
                        ProgressView(value: holder.loadProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 130)
                            .tint(.white)
                        Text("\(Int(holder.loadProgress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.6)).clipShape(Capsule())
                    .padding(.bottom, 14)
                }
            } else if holder.isPlaceholder && qualityMode >= 2 && holder.image != nil {
                // 2026-06-10: 親渡しの isPlaceholder 定数は rawImages (非 @Published) 更新で
                // 再評価されず、標準画質到着後もぐるぐるだけ残留した。進捗バーと同じく
                // holder の @Published フラグ (setLoaded がフル画像で false に落とす) を見る。
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
                if animPlaybackMode == "mp4" {
                    if manualPlayForAnimated {
                        GalleryAnimatedWebPView(
                            source: .url(animURL),
                            staticImage: holder.image,
                            gid: mp4Gid,
                            page: index,
                            onToggleControls: onToggleControls,
                            autoPlayIfActive: isActiveAnimation,
                            isHDREnabled: hdrEnhancement
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        AnimatedVideoView(sourceURL: animURL, gid: mp4Gid, page: index, onToggleControls: onToggleControls, isHDREnabled: hdrEnhancement)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if verticalSizeClass == .regular, let img = holder.image { onTap(img) }
                            }
                    }
                } else {
                    BoomerangWebPView(sourceURL: animURL, readerID: "cell-\(mp4Gid)", pageIndex: index, staticPlaceholder: holder.image)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if verticalSizeClass == .regular, let img = holder.image { onTap(img) }
                        }
                }
            } else if let animData = holder.animatedWebPData {
                if animPlaybackMode == "mp4" {
                    GalleryAnimatedWebPView(
                        source: .data(animData),
                        staticImage: holder.image,
                        gid: mp4Gid,
                        page: index,
                        onToggleControls: onToggleControls,
                        autoPlayIfActive: isActiveAnimation,
                        isHDREnabled: hdrEnhancement
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    BoomerangWebPView(sourceData: animData, readerID: "cell-\(mp4Gid)", pageIndex: index, staticPlaceholder: holder.image)
                        .frame(maxWidth: .infinity)
                }
            } else if let image = holder.image {
                ZStack(alignment: .top) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)

                    // DL進捗バー (田中要望 2026-06-09): holder.loadProgress だけでゲート。
                    // 旧実装は isPlaceholder 定数依存 + horizontalBody 側にしか入れておらず、
                    // 縦モードで描画される verticalBody に無かったのが非表示の真因 (実機ログで確認)。
                    if holder.loadProgress > 0 && holder.loadProgress < 1 {
                        VStack {
                            Spacer()
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.6).tint(.white)
                                ProgressView(value: holder.loadProgress)
                                    .progressViewStyle(.linear).frame(width: 130).tint(.white)
                                Text("\(Int(holder.loadProgress * 100))%")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.black.opacity(0.6)).clipShape(Capsule())
                            .padding(.bottom, 14)
                        }
                    } else if holder.isPlaceholder && qualityMode >= 2 {
                        // 2026-06-10: 同上、定数 isPlaceholder はぐるぐる残留の真因
                        // (rawImages 非 @Published で親が再評価されない)。holder 側を見る。
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

    /// 未ロードセルの高さ。iOS 縦モードのみ「画面幅 × 直近ページ縦横比」で実ページに
    /// 近い高さに安定化 (ジャンプ吹き飛び/スクロール中のレイアウトストーム対策)。
    /// Mac Catalyst は従来の 300 を維持 (憲法: iPhone 性能調整は Catalyst へ波及させない)。
    private var placeholderMinHeight: CGFloat {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if !isHorizontalMode, let aspect = estimatedAspect {
            return UIScreen.main.bounds.width * aspect
        }
        #endif
        return 300
    }

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
        .frame(minHeight: placeholderMinHeight)
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("ページ \(index + 1)").font(.caption).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: isHorizontalMode ? .infinity : nil, alignment: .center)
        .frame(minHeight: placeholderMinHeight)
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
