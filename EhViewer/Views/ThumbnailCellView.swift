import SwiftUI

/// ページ一覧の1セル（自身の@Stateで画像を管理）
struct ThumbnailCellView: View {
    let index: Int
    let coverURL: URL?
    let host: GalleryHost
    let info: ThumbnailInfo?
    let cellHeight: CGFloat
    let onTap: () -> Void

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
        .task(id: info?.spriteURL) {
            await loadThumb()
        }
    }

    private func loadThumb() async {
        guard let info else { return }
        if image != nil { return }

        let cache = SpriteCache.shared
        let croppedKey = cache.croppedKey(url: info.spriteURL, offsetX: info.offsetX)

        // メモリ/ディスクキャッシュチェック
        if let cached = cache.croppedImage(key: croppedKey) {
            image = cached
            return
        }

        // スプライトシート取得
        var sprite = cache.sprite(for: info.spriteURL)
        if sprite == nil {
            if let data = try? await EhClient.shared.fetchThumbData(url: info.spriteURL, host: host) {
                if let downloaded = PlatformImage(data: data) {
                    cache.setSprite(downloaded, for: info.spriteURL)
                    sprite = downloaded
                }
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

        let result: PlatformImage? = await Task.detached(priority: .utility) {
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
