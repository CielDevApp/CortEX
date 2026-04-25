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

    @State private var image: PlatformImage?

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
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: info?.spriteURL ?? URL(string: "local://\(index)")) {
            await loadThumb()
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
