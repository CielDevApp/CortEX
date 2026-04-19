import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit

/// ダウンロード済み WebP アニメ → MP4 変換 + AVPlayer ループ再生ビュー。
///
/// 状態遷移:
/// - 未変換: ポスター（先頭フレーム）+ 再生ボタン overlay → タップで変換開始
/// - 変換中: ポスター + ProgressView
/// - 変換済: AVPlayerLayer でループ再生
struct AnimatedVideoView: View {
    /// WebP/GIFのファイルパス（ディスクベース、Dataメモリ保持しない）
    let sourceURL: URL
    let gid: Int
    let page: Int
    /// タップで自動変換する（false なら再生ボタンのタップで開始）
    var autoStart: Bool = false
    /// 親ビューのツールバー/コントロール表示切替（長押し競合回避: 変換メニューから呼ぶ）
    var onToggleControls: (() -> Void)? = nil

    @State private var status: Status = .notConverted
    @State private var progress: Double = 0
    @State private var posterImage: UIImage?
    @State private var convertedURL: URL?
    @State private var showReconvertDialog: Bool = false

    enum Status {
        case notConverted
        case converting
        case ready
        case failed(String)
    }

    enum Quality {
        case fast       // 360px、最速低画質
        case standard   // 720px（デフォルト）
        case original   // 縮小なし

        var maxPixelSize: CGFloat? {
            switch self {
            case .fast: return 360
            case .standard: return nil  // convert 側の maxOutputPixelSize 使用（720）
            case .original: return .greatestFiniteMagnitude
            }
        }
    }

    var body: some View {
        ZStack {
            if let posterImage {
                Image(uiImage: posterImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
            }

            switch status {
            case .notConverted:
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showReconvertDialog = true
                } label: {
                    ZStack {
                        Circle().fill(.black.opacity(0.55)).frame(width: 72, height: 72)
                        Image(systemName: "play.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                            .offset(x: 3)
                    }
                }
                .buttonStyle(.plain)

            case .converting:
                ZStack {
                    Circle().fill(.black.opacity(0.55)).frame(width: 72, height: 72)
                    VStack(spacing: 4) {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }

            case .ready:
                if let url = convertedURL {
                    LoopingPlayerView(url: url)
                        .onLongPressGesture(minimumDuration: 0.6) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            showReconvertDialog = true
                        }
                }

            case .failed(let msg):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("変換失敗").font(.caption).foregroundStyle(.white)
                    Text(msg).font(.caption2).foregroundStyle(.gray).lineLimit(2)
                    Button("再試行") { startConvert() }
                        .buttonStyle(.bordered).tint(.white)
                }
            }
        }
        .onAppear {
            loadPoster()
            if WebPToMP4Converter.isFullyConverted(gid: gid, page: page) {
                convertedURL = WebPToMP4Converter.mp4Path(gid: gid, page: page)
                status = .ready
            } else {
                WebPToMP4Converter.cleanupStaleIfNeeded(gid: gid, page: page)
                if autoStart { startConvert() }
            }
        }
        .confirmationDialog("メニュー", isPresented: $showReconvertDialog, titleVisibility: .visible) {
            if onToggleControls != nil {
                Button("ツールバー表示切替") { onToggleControls?() }
            }
            Button("ファスト（低画質・最速）") { reconvert(quality: .fast) }
            Button("標準画質") { reconvert(quality: .standard) }
            Button("オリジナル画質") { reconvert(quality: .original) }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("MP4変換またはツールバー表示切替")
        }
    }

    /// 既存 MP4 削除 → 指定画質で再変換
    private func reconvert(quality: Quality) {
        let url = WebPToMP4Converter.mp4Path(gid: gid, page: page)
        let ok = WebPToMP4Converter.okMarkerURL(for: url)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ok)
        convertedURL = nil
        status = .notConverted
        LogManager.shared.log("Convert", "reconvert triggered gid=\(gid) page=\(page) quality=\(quality)")
        startConvert(quality: quality)
    }

    private func loadPoster() {
        guard posterImage == nil else { return }
        let url = sourceURL
        Task.detached(priority: .userInitiated) {
            // URL ベース mmap 経由でポスター decode。サムネ縮小で小さく
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 540
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
            let img = UIImage(cgImage: cg)
            await MainActor.run { self.posterImage = img }
        }
    }

    private func startConvert(quality: Quality = .standard) {
        switch status {
        case .notConverted, .failed: break
        default: return
        }
        LogManager.shared.log("Convert", "startConvert tapped gid=\(gid) page=\(page) quality=\(quality)")
        status = .converting
        progress = 0
        let url = WebPToMP4Converter.mp4Path(gid: gid, page: page)
        let srcURL = sourceURL
        let maxDim = quality.maxPixelSize
        Task.detached(priority: .userInitiated) {
            do {
                try await WebPToMP4Converter.convert(sourceURL: srcURL, outputURL: url, maxPixelSize: maxDim) { p in
                    progress = p
                }
                await MainActor.run {
                    convertedURL = url
                    status = .ready
                    progress = 1
                }
            } catch {
                LogManager.shared.log("Convert", "THROWN: \(error)")
                await MainActor.run {
                    status = .failed(String(describing: error))
                }
            }
        }
    }
}

/// AVPlayerLayer で ループ再生する UIViewRepresentable
struct LoopingPlayerView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.setURL(url)
        return v
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.setURL(url)
    }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var player: AVPlayer?
    private var endObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var currentURL: URL?

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    func setURL(_ url: URL) {
        if currentURL == url, player != nil { return }
        currentURL = url
        rebuildPlayer(url: url)
    }

    private func rebuildPlayer(url: URL) {
        stopInternal()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .none
        playerLayer.player = p
        playerLayer.videoGravity = .resizeAspect

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }

        // .readyToPlay になってから再生開始（新規書き込みMP4の読み込み待機）
        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak p] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    p?.play()
                case .failed:
                    LogManager.shared.log("Player", "item failed: \(item.error?.localizedDescription ?? "unknown")")
                default:
                    break
                }
            }
        }

        self.player = p
    }

    func stop() {
        stopInternal()
    }

    private func stopInternal() {
        player?.pause()
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        playerLayer.player = nil
        player = nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            player?.pause()
        } else {
            player?.play()
        }
    }

    deinit {
        stopInternal()
    }
}
#endif
