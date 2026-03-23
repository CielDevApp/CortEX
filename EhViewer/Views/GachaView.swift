import SwiftUI
import Combine
import TipKit
#if canImport(UIKit)
import UIKit
#endif

/// ProMotion 120Hz CADisplayLinkドライバー
final class DisplayLinkDriver: ObservableObject {
    @Published var tick: UInt64 = 0
    private var displayLink: CADisplayLink?
    var onFrame: (() -> Void)?

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleFrame))
        #if os(iOS)
        if EcoMode.shared.isEnabled {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        } else {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
        #endif
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleFrame(_ link: CADisplayLink) {
        onFrame?()
        tick &+= 1
    }

    deinit { stop() }
}

/// モザイクタイル
private struct MosaicTile: Identifiable {
    let id = UUID()
    let image: PlatformImage
    let targetX: CGFloat
    let targetY: CGFloat
    let size: CGFloat
    var currentX: CGFloat
    var currentY: CGFloat
    var opacity: Double
    var scale: Double
    let speed: CGFloat
    var arrived: Bool = false
}

struct GachaView: View {
    @State private var allFavorites: [Gallery] = []
    @State private var selectedGallery: Gallery?
    @State private var multiResults: [Gallery] = []
    @State private var isMultiMode = false
    // 演出
    @State private var phase: GachaPhase = .idle
    @State private var tiles: [MosaicTile] = []
    @State private var fadeOverlayOpacity: Double = 0
    @State private var resultScale: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var buttonsOpacity: Double = 0
    @State private var uiOpacity: Double = 1
    @State private var showFullscreen = false
    @StateObject private var displayLink = DisplayLinkDriver()
    @State private var resultDragOffset: CGFloat = 0
    // 画面サイズ
    @State private var screenSize: CGSize = .zero

    private enum GachaPhase {
        case idle, filling, darkening, result
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let _ = updateScreenSize(geo.size)

                ZStack {
                    // フルスクリーン演出中の黒背景
                    if showFullscreen {
                        Color.black.ignoresSafeArea()
                    }

                    // メインUI
                    VStack(spacing: 0) {
                        Spacer()

                        if allFavorites.isEmpty {
                            emptyState
                        } else if phase == .idle {
                            idleContent
                        }

                        Spacer()
                    }
                    .opacity(uiOpacity)

                    // モザイクタイルレイヤー
                    if phase == .filling || phase == .darkening {
                        mosaicLayer
                            .ignoresSafeArea()

                        // フェードアウト用の黒オーバーレイ（個別タイルのopacityより軽い）
                        Color.black
                            .opacity(fadeOverlayOpacity)
                            .ignoresSafeArea()
                    }

                    // 結果ポップアップ（フルスクリーン上）
                    if phase == .result {
                        Group {
                            if isMultiMode {
                                multiResultOverlay
                            } else if let gallery = selectedGallery {
                                singleResultOverlay(gallery: gallery)
                            }
                        }
                        .offset(x: resultDragOffset)
                        .opacity(resultDragOffset > 0 ? max(0, 1.0 - resultDragOffset / 400.0) : 1.0)
                        .overlay(alignment: .leading) {
                            // 左端30pxのエッジスワイプ領域（サムネタップと競合しない）
                            Color.clear
                                .frame(width: 30)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            if value.translation.width > 0 {
                                                resultDragOffset = value.translation.width
                                            }
                                        }
                                        .onEnded { value in
                                            if value.translation.width > 60 || value.predictedEndTranslation.width > 150 {
                                                returnToTop()
                                            } else {
                                                withAnimation(.easeOut(duration: 0.2)) {
                                                    resultDragOffset = 0
                                                }
                                            }
                                        }
                                )
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                if showFullscreen {
                    TipView(GachaSwipeTip(), arrowEdge: .top)
                        .padding(.horizontal)
                        .padding(.top, 60)
                }
            }
            .navigationTitle(showFullscreen ? "" : "ガチャ")
            #if os(iOS)
            .navigationBarHidden(showFullscreen)
            .statusBarHidden(showFullscreen)
            .toolbar(showFullscreen ? .hidden : .visible, for: .tabBar)
            #endif
            .onAppear { loadFromCache() }
            .onDisappear { displayLink.stop() }
            .navigationDestination(for: Gallery.self) { gallery in
                GalleryDetailView(gallery: gallery, host: .exhentai)
            }
        }
    }

    private func updateScreenSize(_ size: CGSize) {
        if screenSize != size { screenSize = size }
    }

    private func loadFromCache() {
        let cached = FavoritesCache.shared.load()
        if !cached.isEmpty { allFavorites = cached }
    }

    // MARK: - 通常UI

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "dice.fill").font(.system(size: 60)).foregroundStyle(.secondary)
            Text("お気に入りに追加してから\nお試しください")
                .font(.headline).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var idleContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 80)).foregroundStyle(.secondary)
                Text("？？？").font(.title2).foregroundStyle(.secondary)
            }
            .frame(width: 280, height: 260)
            .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))

            Button { isMultiMode = false; startGacha() } label: {
                Label("ガチャを回す", systemImage: "dice.fill")
                    .font(.title3).bold().frame(maxWidth: 280).padding()
                    .background(LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing))
                    .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(allFavorites.isEmpty)

            Button { isMultiMode = true; startGacha() } label: {
                Label("10連ガチャ", systemImage: "sparkles")
                    .font(.title3).bold().frame(maxWidth: 280).padding()
                    .background(LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing))
                    .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(allFavorites.isEmpty)

            Text("\(allFavorites.count)件のお気に入りから抽選")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func returnToTop() {
        withAnimation(.easeOut(duration: 0.3)) {
            phase = .idle
            showFullscreen = false
            selectedGallery = nil
            multiResults = []
            uiOpacity = 1
            resultDragOffset = 0
        }
    }

    // MARK: - モザイクレイヤー

    private var mosaicLayer: some View {
        let _ = displayLink.tick
        #if os(iOS)
        let bounds = UIScreen.main.bounds
        #else
        let bounds = CGRect(origin: .zero, size: screenSize)
        #endif
        return ZStack {
            ForEach(tiles) { tile in
                Image(platformImage: tile.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: tile.size, height: tile.size * 1.4)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .position(x: tile.currentX, y: tile.currentY)
                    .opacity(tile.opacity)
                    .scaleEffect(tile.scale)
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .ignoresSafeArea(.all)
    }

    // MARK: - 結果オーバーレイ

    private func singleResultOverlay(gallery: Gallery) -> some View {
        VStack(spacing: 12) {
            CachedImageView(url: gallery.coverURL, host: .exhentai)
                .frame(width: 200, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .purple.opacity(0.5), radius: 16)
                .scaleEffect(resultScale)

            Text(gallery.title).font(.subheadline).fontWeight(.medium)
                .lineLimit(3).multilineTextAlignment(.center)
                .foregroundStyle(.white).opacity(titleOpacity)

            if gallery.rating > 0 {
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        let v = gallery.rating - Double(i)
                        Image(systemName: v >= 1 ? "star.fill" : v >= 0.5 ? "star.leadinghalf.filled" : "star")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }.opacity(titleOpacity)
            }

            if gallery.pageCount > 0 {
                Text("\(gallery.pageCount)ページ").font(.caption)
                    .foregroundStyle(.gray).opacity(titleOpacity)
            }

            VStack(spacing: 8) {
                NavigationLink(value: gallery) {
                    Label("読む / 詳細", systemImage: "book.fill").font(.subheadline).bold()
                        .frame(maxWidth: 280).padding(.vertical, 10)
                        .background(.blue).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button { isMultiMode = false; startGacha() } label: {
                    Label("もう一回", systemImage: "arrow.clockwise").font(.subheadline)
                        .frame(maxWidth: 280).padding(.vertical, 10)
                        .background(Color.white.opacity(0.15)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button { returnToTop() } label: {
                    Label("トップに戻る", systemImage: "house").font(.caption)
                        .frame(maxWidth: 280).padding(.vertical, 8)
                        .foregroundStyle(.gray)
                }
            }
            .opacity(buttonsOpacity)
        }
        .padding()
    }

    // MARK: - 10連結果オーバーレイ

    private var multiResultOverlay: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("10連ガチャ結果")
                    .font(.title2).bold().foregroundStyle(.white)
                    .opacity(titleOpacity)
                    .padding(.top, 60)

                if allFavorites.count < 10 {
                    Text("作品数が足りないため\(multiResults.count)件を表示")
                        .font(.caption).foregroundStyle(.orange)
                        .opacity(titleOpacity)
                }

                let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(multiResults) { gallery in
                        NavigationLink(value: gallery) {
                            VStack(spacing: 6) {
                                CachedImageView(url: gallery.coverURL, host: .exhentai)
                                    .aspectRatio(contentMode: .fill)
                                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 200, maxHeight: 200)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .shadow(color: .purple.opacity(0.3), radius: 6)

                                Text(gallery.title)
                                    .font(.caption2).lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .scaleEffect(resultScale)

                VStack(spacing: 8) {
                    Button { isMultiMode = true; startGacha() } label: {
                        Label("もう一回（10連）", systemImage: "sparkles").font(.subheadline).bold()
                            .frame(maxWidth: 280).padding(.vertical, 10)
                            .background(LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing))
                            .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button { returnToTop() } label: {
                        Label("トップに戻る", systemImage: "house").font(.caption)
                            .frame(maxWidth: 280).padding(.vertical, 8)
                            .foregroundStyle(.gray)
                    }
                }
                .opacity(buttonsOpacity)
                .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Haptic

    #if canImport(UIKit)
    private let hapticLight = UIImpactFeedbackGenerator(style: .light)
    private let hapticMedium = UIImpactFeedbackGenerator(style: .medium)
    private let hapticSuccess = UINotificationFeedbackGenerator()
    #endif

    private func haptic(_ style: String) {
        #if canImport(UIKit)
        switch style {
        case "light": hapticLight.impactOccurred()
        case "medium": hapticMedium.impactOccurred()
        case "success": hapticSuccess.notificationOccurred(.success)
        default: break
        }
        #endif
    }

    // MARK: - ガチャ演出制御

    private func startGacha() {
        guard !allFavorites.isEmpty else { return }
        let pool = allFavorites

        // 当選者決定
        let winner: Gallery
        if isMultiMode {
            let count = min(10, pool.count)
            multiResults = Array(pool.shuffled().prefix(count))
            guard let first = multiResults.first else { return }
            winner = first
        } else {
            multiResults = []
            guard let picked = pool.randomElement() else { return }
            winner = picked
        }
        selectedGallery = nil
        resultScale = 0
        titleOpacity = 0
        buttonsOpacity = 0
        fadeOverlayOpacity = 0

        // サムネプリロード
        var cachedImages: [PlatformImage] = []
        for g in pool.shuffled().prefix(80) {
            if let url = g.coverURL, let img = ImageCache.shared.image(for: url) {
                cachedImages.append(img)
            }
        }
        if cachedImages.isEmpty {
            selectedGallery = winner
            phase = .result
            showFullscreen = true
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { resultScale = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.2)) { titleOpacity = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.4)) { buttonsOpacity = 1 }
            return
        }

        // フェーズ1: UI非表示→フルスクリーン
        withAnimation(.easeIn(duration: 0.3)) {
            uiOpacity = 0
        }

        haptic("medium")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showFullscreen = true
            phase = .filling

            generateTiles(images: cachedImages)

            var hapticCount = 0
            displayLink.onFrame = { [self] in
                animateTiles()
                // 埋め尽くし中のみハプティック
                if phase == .filling {
                    hapticCount += 1
                    if hapticCount % 15 == 0 { haptic("light") }
                }
            }
            displayLink.start()

            // 3秒後: 暗転
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                phase = .darkening
                haptic("medium")
                withAnimation(.easeIn(duration: 0.5)) {
                    fadeOverlayOpacity = 1
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    tiles.removeAll()
                    selectedGallery = winner
                    phase = .result
                    haptic("success")

                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        resultScale = 1
                    }
                    withAnimation(.easeOut(duration: 0.3).delay(0.3)) {
                        titleOpacity = 1
                    }
                    withAnimation(.easeOut(duration: 0.3).delay(0.5)) {
                        buttonsOpacity = 1
                    }
                }
            }
        }
    }

    // MARK: - タイル生成

    private func generateTiles(images: [PlatformImage]) {
        tiles.removeAll()
        #if os(iOS)
        let bounds = UIScreen.main.bounds
        let w = bounds.width
        let h = bounds.height
        #else
        let w = max(screenSize.width, 400)
        let h = max(screenSize.height, 700)
        #endif

        // グリッドベースで画面全体を確実にカバー（重なりあり）
        let tileSize: CGFloat = 65
        let tileH: CGFloat = tileSize * 1.4
        let cols = Int(ceil(w / (tileSize * 0.85))) + 1
        let rows = Int(ceil(h / (tileH * 0.85))) + 1
        let totalNeeded = cols * rows

        for row in 0..<rows {
            for col in 0..<cols {
                let img = images[(row * cols + col) % images.count]
                let size = CGFloat.random(in: 55...75)
                // グリッド位置にランダムなジッター追加
                let jitterX = CGFloat.random(in: -8...8)
                let jitterY = CGFloat.random(in: -8...8)
                let targetX = CGFloat(col) * (w / CGFloat(cols)) + (w / CGFloat(cols)) / 2 + jitterX
                let targetY = CGFloat(row) * (h / CGFloat(rows)) + (h / CGFloat(rows)) / 2 + jitterY

                // 開始位置: 四方の画面外からランダム
                let edge = Int.random(in: 0...3)
                let startX: CGFloat
                let startY: CGFloat
                switch edge {
                case 0: startX = targetX; startY = -size - CGFloat.random(in: 50...300)
                case 1: startX = targetX; startY = h + size + CGFloat.random(in: 50...300)
                case 2: startX = -size - CGFloat.random(in: 50...300); startY = targetY
                default: startX = w + size + CGFloat.random(in: 50...300); startY = targetY
                }

                // 速度をランダムに（出現タイミングにバラつき）
                let speed = CGFloat.random(in: 0.03...0.08)

                tiles.append(MosaicTile(
                    image: img, targetX: targetX, targetY: targetY, size: size,
                    currentX: startX, currentY: startY,
                    opacity: 0, scale: 0.3, speed: speed
                ))
            }
        }

        // シャッフルして出現順をランダムに
        tiles.shuffle()
        _ = totalNeeded // suppress unused warning
    }

    // MARK: - タイルアニメーション（毎フレーム）

    private func animateTiles() {
        guard phase == .filling else { return }

        var allArrived = true
        for i in tiles.indices {
            if tiles[i].arrived { continue }

            allArrived = false
            let dx = tiles[i].targetX - tiles[i].currentX
            let dy = tiles[i].targetY - tiles[i].currentY
            let dist = sqrt(dx * dx + dy * dy)

            if dist > 2 {
                tiles[i].currentX += dx * tiles[i].speed
                tiles[i].currentY += dy * tiles[i].speed
            } else {
                tiles[i].currentX = tiles[i].targetX
                tiles[i].currentY = tiles[i].targetY
                tiles[i].arrived = true
            }

            if tiles[i].opacity < 1 {
                tiles[i].opacity = min(1, tiles[i].opacity + 0.06)
            }
            if tiles[i].scale < 1 {
                tiles[i].scale = min(1, tiles[i].scale + 0.04)
            }
        }

        // 全タイル到着 → DisplayLink停止（タイルは静止したまま）
        if allArrived {
            displayLink.stop()
        }
    }
}
