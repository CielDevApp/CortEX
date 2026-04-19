import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit

/// ダウンロード済み WebP アニメ → MP4 変換 + AVPlayer ループ再生ビュー。
///
/// ユーザーの操作ゼロで静止画と動画の境界を消す設計:
/// - 表示された瞬間にバックグラウンド変換開始
/// - 変換中はポスター（1フレーム目）を静止表示（待ち時間を隠す）
/// - 変換完了で AVPlayer へシームレス切替（ポスター同アスペクト比で黒帯なし）
/// - キャッシュあれば即 AVPlayer
/// - onDisappear で Task キャンセル（高速スクロール時のキュー詰まり回避）
struct AnimatedVideoView: View {
    /// WebP/GIFのファイルパス（ディスクベース、Dataメモリ保持しない）
    let sourceURL: URL
    let gid: Int
    let page: Int
    /// 親ビューのツールバー/コントロール表示切替（長押し競合回避: 変換メニューから呼ぶ）
    var onToggleControls: (() -> Void)? = nil

    @State private var status: Status = .converting
    @State private var posterImage: UIImage?
    @State private var convertedURL: URL?
    @State private var showReconvertDialog: Bool = false
    @State private var convertTask: Task<Void, Never>?
    @State private var progress: Double = 0
    /// ポスター/プレイヤー共通のアスペクト比（黒帯回避）
    /// WebPヘッダから同期取得 → AVPlayer 生成前にすでに確定している
    @State private var aspectSize: CGSize = .zero

    enum Status {
        case converting   // = ポスター静止表示 + 裏で MP4 変換
        case ready
        case failed(String)
    }

    var body: some View {
        ZStack {
            // 変換中はポスター（1フレーム目）のみ表示。streaming 非表示で速度違和感を消す
            if let posterImage {
                Image(uiImage: posterImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
            }

            switch status {
            case .converting:
                // iPhone 等は 1-3 秒以上かかるため、ポスター上に白文字で進捗表示
                // M系では瞬時に完了 → ほぼ見えない
                if progress > 0 && progress < 1 {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1)
                }

            case .ready:
                if let url = convertedURL {
                    // ポスターと同じアスペクト比で AVPlayer を frame 化 → 黒帯消失
                    Group {
                        if aspectSize.width > 0 && aspectSize.height > 0 {
                            LoopingPlayerView(url: url)
                                .aspectRatio(aspectSize, contentMode: .fit)
                        } else {
                            LoopingPlayerView(url: url)
                        }
                    }
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
            // AVPlayer 生成前にアスペクト比を確定させる
            if aspectSize == .zero, let s = WebPFileDetector.readCanvasSize(url: sourceURL) {
                aspectSize = s
            }
            if WebPToMP4Converter.isFullyConverted(gid: gid, page: page) {
                convertedURL = WebPToMP4Converter.mp4Path(gid: gid, page: page)
                status = .ready
            } else {
                WebPToMP4Converter.cleanupStaleIfNeeded(gid: gid, page: page)
                startConvert()
            }
        }
        .onDisappear {
            // 画面外に出たら変換タスクをキャンセル（semaphore 待ち中なら即破棄される）
            convertTask?.cancel()
            convertTask = nil
        }
        .confirmationDialog("メニュー", isPresented: $showReconvertDialog, titleVisibility: .visible) {
            if onToggleControls != nil {
                Button("ツールバー表示切替") { onToggleControls?() }
            }
            Button("再変換") { reconvert() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("再変換またはツールバー表示切替")
        }
    }

    /// 既存 MP4 削除 → 再変換
    private func reconvert() {
        let url = WebPToMP4Converter.mp4Path(gid: gid, page: page)
        let ok = WebPToMP4Converter.okMarkerURL(for: url)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: ok)
        convertedURL = nil
        status = .converting
        LogManager.shared.log("Convert", "reconvert triggered gid=\(gid) page=\(page)")
        startConvert()
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

    private func startConvert() {
        // すでに進行中 / 完了済みなら何もしない
        if convertTask != nil { return }
        if case .ready = status { return }
        LogManager.shared.log("Convert", "auto start gid=\(gid) page=\(page)")
        status = .converting
        progress = 0
        let url = WebPToMP4Converter.mp4Path(gid: gid, page: page)
        let srcURL = sourceURL
        let maxDim: CGFloat? = .greatestFiniteMagnitude
        convertTask = Task.detached(priority: .userInitiated) {
            do {
                try await WebPToMP4Converter.convert(
                    sourceURL: srcURL,
                    outputURL: url,
                    maxPixelSize: maxDim,
                    progress: { p in progress = p },
                    frameCallback: nil
                )
                await MainActor.run {
                    convertedURL = url
                    status = .ready
                    convertTask = nil
                }
            } catch is CancellationError {
                LogManager.shared.log("Convert", "cancelled gid=\(gid) page=\(page)")
                await MainActor.run { convertTask = nil }
            } catch {
                LogManager.shared.log("Convert", "THROWN: \(error)")
                await MainActor.run {
                    status = .failed(String(describing: error))
                    convertTask = nil
                }
            }
        }
    }
}

/// ストリーミング再生用: 変換中に decode されたフレームをリアルタイム表示
/// Holder が UIView を保持し、decode スレッドから setFrame → main dispatch → layer.contents 更新
final class StreamingFrameHolder: @unchecked Sendable {
    weak var view: StreamingFrameUIView?

    func setFrame(_ cgImage: CGImage) {
        // decode スレッドから呼ばれる → main で layer 更新
        DispatchQueue.main.async { [weak self] in
            self?.view?.applyFrame(cgImage)
        }
    }
}

final class StreamingFrameUIView: UIView {
    override class var layerClass: AnyClass { CALayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.contentsGravity = .resizeAspect
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyFrame(_ cgImage: CGImage) {
        layer.contents = cgImage
    }
}

struct StreamingFrameView: UIViewRepresentable {
    let holder: StreamingFrameHolder

    func makeUIView(context: Context) -> StreamingFrameUIView {
        let v = StreamingFrameUIView()
        holder.view = v
        return v
    }

    func updateUIView(_ uiView: StreamingFrameUIView, context: Context) {
        holder.view = uiView
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
        // ポスターと同アスペクト比で frame 化済み → .resizeAspect で黒帯なし（等価フィット）
        playerLayer.videoGravity = .resizeAspect

        // ループ: seek 完了待ってから play（非同期 seek 中に play 呼ぶと瞬間的な高速再生になる）
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                p?.play()
            }
        }

        // 初回再生: readyToPlay で 0 位置を明示 seek してから play
        // （新規書き込み MP4 の最初の frame デコード追いつかない場合のズレ防止）
        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak p] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    p?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        p?.play()
                    }
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
