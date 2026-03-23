import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct WallpaperView: View {
    let onDismiss: () -> Void

    @State private var tiles: [WallTile] = []
    @State private var scrollOffset: CGFloat = 0
    @State private var speedLevel = 0
    @State private var isReady = false
    @StateObject private var displayLink = DisplayLinkDriver()

    /// 全お気に入りのcoverURL（マスタープール）
    @State private var masterPool: [URL] = []
    /// リサイクル用プリリサイズ済み画像キュー（メインスレッドで即取得可能）
    @State private var readyImages: [PlatformImage] = []
    /// readyImagesの次の取り出し位置
    @State private var readyIndex: Int = 0
    /// バックグラウンドで次バッチを補充中か
    @State private var isRefilling = false
    /// 前回バッチの末尾URL（次バッチで除外して隣接重複を防止）
    @State private var lastBatchTailURLs: Set<URL> = []

    private let poolLimit = 120

    private let speeds: [CGFloat] = [0.5, 2.0, 4.0, 6.0, 8.0, 16.0, 32.0]
    private let speedLabels = ["×1", "×4", "×8", "×12", "×16", "×32", "×64"]
    private let tileRatio: CGFloat = 1.4
    private let thumbSize: CGFloat = 120

    /// scroll()用キャッシュ（タイル構造変更時に更新）
    @State private var cachedTileH: CGFloat = 0
    @State private var cachedTotalH: CGFloat = 0

    private var portraitSize: CGSize {
        #if os(iOS)
        let bounds = UIScreen.main.bounds
        let w = min(bounds.width, bounds.height)
        let h = max(bounds.width, bounds.height)
        return CGSize(width: w, height: h)
        #else
        return CGSize(width: 400, height: 900)
        #endif
    }

    struct WallTile: Identifiable {
        let id = UUID()
        var image: PlatformImage
        var x: CGFloat
        var y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    var body: some View {
        let _ = displayLink.tick
        let pSize = portraitSize

        ZStack {
            Color.black.ignoresSafeArea()

            if isReady {
                ZStack {
                    ForEach(tiles) { tile in
                        let sy = tile.y + scrollOffset
                        if sy > -tile.height && sy < pSize.height + tile.height {
                            Image(platformImage: tile.image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: tile.width, height: tile.height)
                                .clipped()
                                .position(x: tile.x + tile.width / 2, y: sy + tile.height / 2)
                        }
                    }
                }
                .frame(width: pSize.width, height: pSize.height)
            } else {
                ProgressView("読み込み中...")
                    .tint(.white).foregroundStyle(.white)
            }

            // UI
            VStack {
                HStack {
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding()
                }

                Spacer()

                HStack {
                    Spacer()
                    Button {
                        speedLevel = (speedLevel + 1) % speeds.count
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        #endif
                    } label: {
                        Text(speedLabels[speedLevel])
                            .font(.caption).bold().monospacedDigit()
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial.opacity(0.5))
                            .clipShape(Capsule())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding()
                }
            }
        }
        .ignoresSafeArea()
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        #endif
        .task { await loadImages() }
        .onDisappear {
            displayLink.stop()
            tiles.removeAll()
            masterPool.removeAll()
            readyImages.removeAll()
        }
    }

    // MARK: - 画像ロード

    private func loadImages() async {
        let galleries = FavoritesCache.shared.load()
        // URL重複を排除（同じ表紙が複数回登録されているケース対策）
        var seen = Set<URL>()
        masterPool = galleries.compactMap(\.coverURL).filter { seen.insert($0).inserted }

        // バックグラウンドでリサイズ済み画像を準備
        let pool = masterPool
        let maxSide = thumbSize
        let limit = poolLimit
        let (loaded, tailURLs): ([PlatformImage], Set<URL>) = await Task.detached(priority: .utility) {
            let sampled = pool.count <= limit
                ? pool.shuffled()
                : Array(pool.shuffled().prefix(limit))
            var result: [PlatformImage] = []
            var usedURLs = Set<URL>()
            var sampledURLs: [URL] = []
            for url in sampled {
                guard usedURLs.insert(url).inserted else { continue }
                if let img = ImageCache.shared.image(for: url) {
                    if let resized = Self.resize(img, maxSide: maxSide) {
                        result.append(resized)
                    } else {
                        result.append(img)
                    }
                    sampledURLs.append(url)
                }
            }
            return (result, Set(sampledURLs.suffix(5)))
        }.value

        guard !loaded.isEmpty else { onDismiss(); return }

        LogManager.shared.log("App", "wallpaper: \(loaded.count) unique images from \(masterPool.count) pool")
        readyImages = loaded
        readyIndex = 0
        lastBatchTailURLs = tailURLs

        let pSize = portraitSize
        buildAndStart(images: loaded, width: pSize.width, height: pSize.height)
    }

    private func buildAndStart(images: [PlatformImage], width: CGFloat, height: CGFloat) {
        rebuildTiles(images: images, width: width, height: height)
        isReady = true
        displayLink.onFrame = { scroll() }
        displayLink.start()
    }

    #if canImport(UIKit)
    private static func resize(_ image: PlatformImage, maxSide: CGFloat) -> PlatformImage? {
        let w = image.size.width, h = image.size.height
        guard w > maxSide || h > maxSide else { return image }
        let scale = maxSide / max(w, h)
        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
    #else
    private static func resize(_ image: PlatformImage, maxSide: CGFloat) -> PlatformImage? { image }
    #endif

    // MARK: - タイル

    private func rebuildTiles(images: [PlatformImage], width: CGFloat, height: CGFloat) {
        guard !images.isEmpty else { return }
        let cols = 4
        let tileW = width / CGFloat(cols)
        let tileH = tileW * tileRatio
        let rows = max(24, Int(ceil(height * 8 / tileH)))
        let totalTiles = rows * cols

        // 画像を重複なしで配置。足りない分はシャッフルして再利用（隣接回避）
        var tileImages: [PlatformImage] = []
        var remaining = images.shuffled()
        while tileImages.count < totalTiles {
            if remaining.isEmpty {
                remaining = images.shuffled()
            }
            tileImages.append(remaining.removeFirst())
        }

        tiles = (0..<totalTiles).map { i in
            WallTile(
                image: tileImages[i],
                x: CGFloat(i % cols) * tileW,
                y: CGFloat(i / cols) * tileH,
                width: tileW, height: tileH
            )
        }
        scrollOffset = 0

        // scroll()用の定数をキャッシュ
        cachedTileH = tileH
        cachedTotalH = CGFloat(rows) * tileH
    }

    // MARK: - スクロール（毎フレーム、軽量に保つ）

    private func scroll() {
        scrollOffset -= speeds[speedLevel]
        let tileH = cachedTileH
        let totalH = cachedTotalH
        guard tileH > 0, totalH > 0 else { return }

        for i in tiles.indices {
            if tiles[i].y + scrollOffset < -tileH {
                tiles[i].y += totalH
                // リサイクル: キューから1枚取り出し（重複なし）
                if readyIndex < readyImages.count {
                    tiles[i].image = readyImages[readyIndex]
                    readyIndex += 1
                }
                // キュー残り少なくなったら補充開始
                if readyIndex >= readyImages.count - 4 {
                    refillIfNeeded()
                }
            }
        }
    }

    /// バックグラウンドで新しい60件をランダム抽出し、readyImagesの末尾に追加
    private func refillIfNeeded() {
        guard !isRefilling, !masterPool.isEmpty else { return }
        isRefilling = true

        let pool = masterPool
        let maxSide = thumbSize
        let limit = poolLimit
        let excludeURLs = lastBatchTailURLs

        Task.detached(priority: .utility) {
            // 前回末尾5件を除外してからシャッフル抽選
            let candidates = pool.filter { !excludeURLs.contains($0) }
            let sampled = candidates.count <= limit
                ? candidates.shuffled()
                : Array(candidates.shuffled().prefix(limit))
            var result: [PlatformImage] = []
            var usedURLs = Set<URL>()
            var newTailURLs: [URL] = []
            for url in sampled {
                guard usedURLs.insert(url).inserted else { continue }
                if let img = ImageCache.shared.memoryImage(for: url) {
                    if let resized = Self.resize(img, maxSide: maxSide) {
                        result.append(resized)
                    } else {
                        result.append(img)
                    }
                    newTailURLs.append(url)
                }
            }
            // 末尾5件を記録
            let tail = Set(newTailURLs.suffix(5))
            await MainActor.run {
                if !result.isEmpty {
                    if readyIndex > 0 {
                        readyImages.removeFirst(min(readyIndex, readyImages.count))
                        readyIndex = 0
                    }
                    readyImages.append(contentsOf: result)
                    lastBatchTailURLs = tail
                }
                isRefilling = false
            }
        }
    }
}
