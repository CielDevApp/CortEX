import SwiftUI

/// ページ一覧の1セル（自身の@Stateで画像を管理）
struct ThumbnailCellView: View {
    let index: Int
    let coverURL: URL?
    let host: GalleryHost
    let info: ThumbnailInfo?
    let cellHeight: CGFloat
    let onTap: () -> Void
    /// ダウンロード済み画像流用（gid指定時はローカルを先にチェック）
    var gid: Int? = nil
    /// 未 DL ページのフォールバック判定値 (作品単位、タグに animated 含むか)。
    /// DL 済みファイル不在時に detectAnimated でファイル判定できないため、
    /// この値を採用してマーク表示する。混在作品の正確な動画/静画区別は DL 済みでのみ可能。
    var isAnimatedFallback: Bool = false

    @State private var image: PlatformImage?
    /// 個別ページの動画判定 (DL 済みファイルを実バイト走査)。動画と静画混在作品で
    /// 動画ページにだけ再生マーク overlay 表示するため、ページ単位で判定 (田中指示 2026-04-25)。
    /// gid 指定 + DL 済みファイルがある時のみ true になりうる、未 DL ページは fallback 値を採用。
    @State private var isAnimated: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: cellHeight, maxHeight: cellHeight)
                    .clipped()
            } else if index == 0, let coverURL, let coverImg = ImageCache.shared.image(for: coverURL) {
                Image(platformImage: coverImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: cellHeight, maxHeight: cellHeight)
                    .clipped()
            } else {
                Color.gray.opacity(0.1)
                    .frame(height: cellHeight)
            }

            Text("\(index + 1)")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(3)
        }
        .frame(maxWidth: .infinity, minHeight: cellHeight, maxHeight: cellHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .center) {
            // DL一覧 PageThumbCell の長押しプレビューと同じ形・位置: 中央 .title2 白 shadow。
            if isAnimated {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .overlay {
            // 紫枠線も DL 一覧 PageThumbCell (line 822-826) と統一 (田中指示「ドラの枠もパクって」)。
            if isAnimated {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.purple, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: info?.spriteURL ?? URL(string: "local://\(index)")) {
            await loadThumb()
            await detectAnimated()
        }
    }

    /// 判定優先順 (混在作品で動画 page のみマーク表示の精度確保):
    /// (1) DL 済みファイルあり → 実バイト判定
    /// (2) ImageCache に reader 経由で保存済 animated WebP あり → true
    /// (3) 未 DL & cache 無 → 作品単位 fallback (全 page、誤情報あり)
    private func detectAnimated() async {
        guard let gid else {
            if isAnimatedFallback {
                await MainActor.run { self.isAnimated = true }
            }
            return
        }
        let dlURL = DownloadManager.shared.imageFilePath(gid: gid, page: index)
        if FileManager.default.fileExists(atPath: dlURL.path) {
            // DL 済み: ファイル実バイト判定
            let animated = await Task.detached(priority: .utility) {
                WebPFileDetector.isAnimatedWebP(url: dlURL)
            }.value
            await MainActor.run { self.isAnimated = animated }
            return
        }
        // 未 DL: reader 経由で fetch 済の animated WebP cache を gid+page で確認。
        // 混在作品で動画 page だけ reader が判定して保存しているはずなので、
        // この cache 存在 = 動画 page と確定できる (静画 page は cache に来ない)。
        if ImageCache.shared.animatedWebPFileURL(gid: gid, page: index) != nil {
            await MainActor.run { self.isAnimated = true }
            return
        }
        // それも無ければ作品単位タグ fallback (全 page、混在区別不能)
        if isAnimatedFallback {
            await MainActor.run { self.isAnimated = true }
        }
    }

    private func loadThumb() async {
        if image != nil { return }

        // ダウンロード済み画像を縮小してサムネに転用（API不要）
        if let gid, let localImg = DownloadManager.shared.loadLocalImage(gid: gid, page: index) {
            let thumb: PlatformImage? = await withCheckedContinuation { cont in
                SpriteCache.imageQueue.async {
                    let maxW: CGFloat = 360
                    let scale = min(maxW / CGFloat(localImg.pixelWidth), 1.0)
                    if scale < 1.0 {
                        let newW = Int(CGFloat(localImg.pixelWidth) * scale)
                        let newH = Int(CGFloat(localImg.pixelHeight) * scale)
                        #if canImport(UIKit)
                        let renderer = UIGraphicsImageRenderer(size: CGSize(width: newW, height: newH))
                        let resized = renderer.image { _ in
                            localImg.draw(in: CGRect(x: 0, y: 0, width: newW, height: newH))
                        }
                        cont.resume(returning: resized)
                        #else
                        cont.resume(returning: localImg)
                        #endif
                    } else {
                        cont.resume(returning: localImg)
                    }
                }
            }
            if let thumb { image = thumb; return }
        }

        guard let info else { return }

        let cache = SpriteCache.shared
        let croppedKey = cache.croppedKey(url: info.spriteURL, offsetX: info.offsetX)

        // メモリ/ディスクキャッシュチェック
        if let cached = cache.croppedImage(key: croppedKey) {
            image = cached
            return
        }

        // スプライトシート取得（他 Task がフェッチ中ならスキップ）
        var sprite = cache.sprite(for: info.spriteURL)
        if sprite == nil && !SpriteCache.shared.fetchingSprites.contains(info.spriteURL) {
            SpriteCache.shared.fetchingSprites.insert(info.spriteURL)
            defer { SpriteCache.shared.fetchingSprites.remove(info.spriteURL) }
            if let data = try? await EhClient.shared.fetchThumbData(url: info.spriteURL, host: host) {
                if let downloaded = PlatformImage(data: data) {
                    cache.setSprite(downloaded, for: info.spriteURL)
                    sprite = downloaded
                }
            }
        } else if sprite == nil {
            // 他 Task のフェッチ完了を待つ
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                sprite = cache.sprite(for: info.spriteURL)
                if sprite != nil { break }
            }
        }
        guard let sprite else { return }

        // バックグラウンドでクロップ+リサイズ
        let x = abs(Int(info.offsetX))
        let w = Int(info.width), h = Int(info.height)
        let clampedX = min(x, sprite.pixelWidth - 1)
        let clampedW = min(w, sprite.pixelWidth - clampedX)
        let clampedH = min(h, sprite.pixelHeight)
        let cropRect = CGRect(x: clampedX, y: 0, width: clampedW, height: clampedH)

        let result: PlatformImage? = await Task.detached(priority: .userInitiated) {
            guard let cropped = sprite.croppedImage(rect: cropRect) else { return nil }
            #if canImport(UIKit)
            let maxPx: CGFloat = 360
            let scale = min(maxPx / CGFloat(clampedW), maxPx / CGFloat(clampedH), 1.0)
            if scale < 1.0 {
                let newSize = CGSize(width: CGFloat(clampedW) * scale, height: CGFloat(clampedH) * scale)
                return UIGraphicsImageRenderer(size: newSize).image { _ in
                    cropped.draw(in: CGRect(origin: .zero, size: newSize))
                }
            }
            return cropped
            #else
            return cropped
            #endif
        }.value

        if let result {
            cache.setCropped(result, key: croppedKey)
            image = result
        }
    }
}
