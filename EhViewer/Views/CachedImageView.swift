import SwiftUI

/// cookie付きで画像をダウンロードし、キャッシュして表示するビュー
struct CachedImageView: View {
    let url: URL?
    let host: GalleryHost
    /// ダウンロード済みギャラリーのカバー流用（gid指定時はローカルを先にチェック）
    var gid: Int? = nil

    @State private var uiImage: PlatformImage?
    @State private var failed = false

    var body: some View {
        if let uiImage {
            Image(platformImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .transition(.opacity)
        } else if failed {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .task(id: url) { await loadImage() }
        }
    }

    private func loadImage() async {
        guard let url else { failed = true; return }
        let t0 = CFAbsoluteTimeGetCurrent()

        // ダウンロード済みカバー → API不要で即表示
        if let gid, let localCover = DownloadManager.shared.loadCoverImage(gid: gid) {
            LogManager.shared.log("Thumb", "local cover hit gid=\(gid)")
            uiImage = localCover
            return
        }

        // キャッシュヒット → 即表示
        if let cached = ImageCache.shared.image(for: url) {
            LogManager.shared.log("Thumb", "cache hit \(url.lastPathComponent)")
            LogManager.shared.log("Perf", "coverImage(cache hit): \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms \(url.lastPathComponent)")
            uiImage = cached
            return
        }

        LogManager.shared.log("Thumb", "start \(url.lastPathComponent)")

        // 重複防止: 他が取得中なら待つ
        if ImageCache.shared.isLoading(url) {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                if let cached = ImageCache.shared.image(for: url) {
                    withAnimation(.easeIn(duration: 0.15)) { uiImage = cached }
                    return
                }
                if !ImageCache.shared.isLoading(url) { break }
            }
            if let cached = ImageCache.shared.image(for: url) {
                withAnimation(.easeIn(duration: 0.15)) { uiImage = cached }
            }
            return
        }

        ImageCache.shared.setLoading(url)

        // 同時ダウンロード数制限（エクストリーム時はスキップ）
        let useSlot = !ExtremeMode.shared.isEnabled
        if useSlot { await ImageCache.shared.acquireThumbSlot() }
        defer { if useSlot { ImageCache.shared.releaseThumbSlot() } }

        // キャッシュに入っていたら即返却（待機中に他が取得した場合）
        if let cached = ImageCache.shared.image(for: url) {
            ImageCache.shared.removeLoading(url)
            withAnimation(.easeIn(duration: 0.15)) { uiImage = cached }
            return
        }

        // ネットワーク取得+GPUデコードをMainActorから外して並列実行
        let capturedHost = host
        let result: PlatformImage? = await Task.detached(priority: .userInitiated) {
            let totalStart = CFAbsoluteTimeGetCurrent()
            do {
                let netStart = CFAbsoluteTimeGetCurrent()
                let data = try await EhClient.shared.fetchThumbData(url: url, host: capturedHost)
                let netMs = (CFAbsoluteTimeGetCurrent() - netStart) * 1000

                guard !Task.isCancelled else { return nil }

                let decStart = CFAbsoluteTimeGetCurrent()
                #if canImport(UIKit)
                // GPU経由デコード: CIImage → CIContext(GPU) → CGImage
                let ciCtx = SpriteCache.ciContext
                if let ciImage = CIImage(data: data),
                   let cgImage = ciCtx.createCGImage(ciImage, from: ciImage.extent) {
                    let gpuDecoded = UIImage(cgImage: cgImage)
                    let decMs = (CFAbsoluteTimeGetCurrent() - decStart) * 1000
                    let totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
                    LogManager.shared.log("Thumb", "\(url.lastPathComponent) net=\(String(format: "%.0f", netMs))ms dec=\(String(format: "%.0f", decMs))ms total=\(String(format: "%.0f", totalMs))ms")
                    ImageCache.shared.setThumb(gpuDecoded, for: url)
                    return gpuDecoded
                }
                // GPUデコード失敗時のCPUフォールバック
                guard let img = PlatformImage(data: data) else { return nil }
                if let prepared = await img.byPreparingForDisplay() {
                    ImageCache.shared.setThumb(prepared, for: url)
                    return prepared
                }
                return img
                #else
                guard let img = PlatformImage(data: data) else { return nil }
                return img
                #endif
            } catch {
                return nil
            }
        }.value

        ImageCache.shared.removeLoading(url)

        if let result {
            LogManager.shared.log("Perf", "coverImage(fetch): \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms \(url.lastPathComponent)")
            withAnimation(.easeIn(duration: 0.15)) { uiImage = result }
        } else if !Task.isCancelled {
            failed = true
        }
    }
}
