import Foundation
import Combine
import SwiftUI

/// リーダーのメインViewModel
/// ページロード: ReaderViewModel+PageLoad.swift
/// フィルタパイプライン: ReaderViewModel+FilterPipeline.swift
class ReaderViewModel: ObservableObject {
    @Published var currentIndex: Int = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var totalPages: Int = 0
    @Published var scrollTarget: Int?
    @Published var isScrolling = false

    // MARK: - Internal State（extension からアクセス可能）

    var pageHolders: [Int: PageImageHolder] = [:]
    let client = EhClient.shared
    var imagePageURLs: [URL] = []
    var resolvedImageURLs: [Int: URL] = [:]
    var loadingPages: Set<Int> = []
    var completedPages: Set<Int> = []
    /// スキップログ抑制用
    var lastSkipLogTime: CFAbsoluteTime = 0
    var skippedSinceLastLog: Int = 0
    /// URL先行解決の重複防止
    var urlResolvingPages: Set<Int> = []
    var maxConcurrent: Int {
        if EcoMode.shared.isEnabled { return 3 }
        return SafetyMode.shared.isEnabled ? 5 : 20
    }
    let gallery: Gallery
    let host: GalleryHost
    let initialPage: Int
    var thumbnails: [ThumbnailInfo]
    let requestDelay: UInt64 = 2_000_000_000
    var rawImages: [Int: PlatformImage] = [:]
    var processedPages: Set<Int> = []
    var placeholderPages: Set<Int> = []
    var hasLoadedImagePages = false

    var qualityMode: Int {
        UserDefaults.standard.integer(forKey: "onlineQualityMode")
    }
    var isOfflineMode: Bool { qualityMode <= 1 }

    // MARK: - Init

    init(gallery: Gallery, host: GalleryHost, initialPage: Int = 0, thumbnails: [ThumbnailInfo] = []) {
        self.gallery = gallery
        self.host = host
        self.initialPage = initialPage
        self.thumbnails = thumbnails
        self.totalPages = max(gallery.pageCount, 1)
        self.currentIndex = initialPage

        if let resolved = Self.loadResolvedURLs(gid: gallery.gid) {
            resolvedImageURLs = resolved
        }

        if let thumb = thumbnailImage(for: initialPage) {
            holder(for: initialPage).setLoaded(thumb)
            placeholderPages.insert(initialPage)
        }
    }

    // MARK: - PageHolder

    func holder(for index: Int) -> PageImageHolder {
        if let h = pageHolders[index] { return h }
        let h = PageImageHolder()
        pageHolders[index] = h
        return h
    }

    // MARK: - UI Actions

    func onAppear(index: Int) {
        currentIndex = index
        requestLoad(index)
        if !isScrolling && !EcoMode.shared.isEnabled {
            let prefetchRange = SafetyMode.shared.isEnabled ? 1 : 5
            for offset in 1...prefetchRange {
                requestLoad(index + offset)
                requestLoad(index - offset)
            }
        }
        // ★ スクロール先の URL が未取得なら動的に優先取得
        ensureImagePageURLs(around: index)
    }

    /// currentIndex 周辺の imagePageURLs が未取得なら動的にフェッチ
    private var urlPageFetchingSet: Set<Int> = []
    private func ensureImagePageURLs(around index: Int) {
        let urlsPerPage = 20
        let neededPage = index / urlsPerPage
        // 既に十分な URL があるか、フェッチ中ならスキップ
        guard index >= imagePageURLs.count || (index < imagePageURLs.count && imagePageURLs[index].absoluteString == "about:blank") else { return }
        guard !urlPageFetchingSet.contains(neededPage) else { return }
        urlPageFetchingSet.insert(neededPage)
        Task(priority: .userInitiated) {
            do {
                let urls = try await client.fetchImagePageURLs(host: host, gallery: gallery, page: neededPage)
                if !urls.isEmpty {
                    let offset = neededPage * urlsPerPage
                    var current = imagePageURLs
                    while current.count < offset + urls.count {
                        current.append(URL(string: "about:blank")!)
                    }
                    for (i, url) in urls.enumerated() {
                        current[offset + i] = url
                    }
                    imagePageURLs = current
                    LogManager.shared.log("Perf", "ensureImagePageURLs: dynamic fetch p=\(neededPage) count=\(urls.count) total=\(current.count)")
                    // 取得完了 → 即座にリクエスト
                    requestLoad(index)
                    requestLoad(index + 1)
                    requestLoad(index - 1)
                }
            } catch {}
            urlPageFetchingSet.remove(neededPage)
        }
    }

    func scrollStateChanged(isDragging: Bool) {
        isScrolling = isDragging
        if !isDragging {
            requestLoad(currentIndex + 1)
            requestLoad(currentIndex - 1)
        }
    }

    func onDisappear(index: Int) {
        let distance = abs(index - currentIndex)
        // 旧実装: distance > 3 で `animatedFileURL = nil + completedPages.remove`。
        // 意図は「rawData ~17MB を解放」だったが、AnimatedImageSource の rawData は
        // BoomerangWebPView の State に保持され LazyVStack の cell unmount で自動 deinit される。
        // URL を nil にすると同じページに戻った時に「静画扱い」「▶︎ ボタン出ない」になる
        // (田中報告 2026-04-25 動画/静画混在作品で動画 page を離れて戻った時の症状)。
        // URL は軽量 String なので保持コスト無視できる、削除した。
        if distance > 50 {
            pageHolders.removeValue(forKey: index)
            rawImages.removeValue(forKey: index)
            processedPages.remove(index)
        } else if distance > 20 {
            pageHolders[index]?.image = nil
            rawImages.removeValue(forKey: index)
            processedPages.remove(index)
        }
    }

    func retry(index: Int) {
        pageHolders.removeValue(forKey: index)
        rawImages.removeValue(forKey: index)
        processedPages.remove(index)
        completedPages.remove(index)
        loadingPages.remove(index)
        requestLoad(index)
    }

    func jumpTo(page: Int) {
        let clamped = max(0, min(page, totalPages - 1))
        // 縦モードのみscrollTarget（横モードはhorizontalPageで制御）
        let direction = UserDefaults.standard.integer(forKey: "readerDirection")
        if direction == 0 {
            scrollTarget = clamped
        }
        currentIndex = clamped
        requestLoad(clamped)
        requestLoad(clamped + 1)

        // ジャンプ先のスプライトシートを優先 preload（サムネプレースホルダー高速化）
        Task(priority: .userInitiated) {
            for offset in 0...2 {
                let idx = clamped + offset
                guard idx < thumbnails.count else { break }
                let info = thumbnails[idx]
                if SpriteCache.shared.sprite(for: info.spriteURL) == nil {
                    if let data = try? await client.fetchImageData(url: info.spriteURL, host: host) {
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            SpriteCache.imageQueue.async {
                                if let ciImage = CIImage(data: data),
                                   let cgImage = SpriteCache.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                                    SpriteCache.shared.setSprite(PlatformImage(cgImage: cgImage), for: info.spriteURL)
                                }
                                cont.resume()
                            }
                        }
                    }
                }
            }
        }
    }

    func isPlaceholder(index: Int) -> Bool {
        placeholderPages.contains(index) && rawImages[index] == nil
    }

    // MARK: - 設定変更

    func resetAllState() {
        rawImages.removeAll()
        loadingPages.removeAll()
        completedPages.removeAll()
        processedPages.removeAll()
        placeholderPages.removeAll()
        for (_, holder) in pageHolders {
            holder.image = nil
            holder.isPlaceholder = false
            holder.isFailed = false
            holder.failReason = nil
        }
    }

    func reloadAround(range: Int = 3) {
        let center = currentIndex
        requestLoad(center)
        for offset in 1...range {
            requestLoad(center + offset)
            requestLoad(center - offset)
        }
    }

    func qualityModeChanged() {
        resetAllState()
        // オフライン(0/1)↔オンライン(2+)切替時はimagePageURLsを再取得する必要がある
        // 常にリセットして確実に再ロード
        hasLoadedImagePages = false
        Task(priority: .userInitiated) {
            await loadImagePages()
            await MainActor.run { self.reloadAround() }
        }
    }

    func filterSettingsChanged() {
        processedPages.removeAll()
        let lo = max(0, currentIndex - 5)
        let hi = min(max(totalPages - 1, 0), currentIndex + 5)
        guard lo <= hi else { return }
        for i in lo...hi {
            if let raw = rawImages[i] {
                applyFilterPipeline(index: i, raw: raw)
            }
        }
    }

    func switchToUpscaleMode() {
        UserDefaults.standard.set(1, forKey: "onlineQualityMode")
        resetAllState()
        reloadAround()
    }

    func switchToLowQualityMode() {
        UserDefaults.standard.set(0, forKey: "onlineQualityMode")
        resetAllState()
        reloadAround()
    }

    func switchToStandardQuality() {
        UserDefaults.standard.set(2, forKey: "onlineQualityMode")
        resetAllState()
        hasLoadedImagePages = false
        Task(priority: .userInitiated) {
            await loadImagePages()
            reloadAround()
        }
    }

    // MARK: - サムネプレースホルダー

    func thumbnailImage(for index: Int) -> PlatformImage? {
        if index == 0, let coverURL = gallery.coverURL {
            return ImageCache.shared.image(for: coverURL)
        }
        if index < thumbnails.count {
            let info = thumbnails[index]
            // SpriteCacheのクロップ済みキャッシュを先に確認
            let croppedKey = SpriteCache.shared.croppedKey(url: info.spriteURL, offsetX: info.offsetX)
            if let cached = SpriteCache.shared.croppedImage(key: croppedKey) {
                return cached
            }
            // スプライトシートからクロップ
            if let sprite = SpriteCache.shared.sprite(for: info.spriteURL) {
                let x = abs(Int(info.offsetX))
                let w = Int(info.width)
                let h = Int(info.height)
                let clampedX = min(x, sprite.pixelWidth - 1)
                let clampedW = min(w, sprite.pixelWidth - clampedX)
                let clampedH = min(h, sprite.pixelHeight)
                return sprite.croppedImage(rect: CGRect(x: clampedX, y: 0, width: clampedW, height: clampedH))
            }
        }
        return nil
    }

    // MARK: - ダウンサンプル

    static var displayWidth: CGFloat {
        #if os(iOS)
        UIScreen.main.bounds.width * UIScreen.main.scale
        #else
        1200
        #endif
    }

    static func downsample(_ image: PlatformImage) -> PlatformImage {
        #if canImport(UIKit)
        let imgW = CGFloat(image.pixelWidth)
        guard imgW > displayWidth * 1.2 else { return image }
        let scale = displayWidth / imgW
        let newSize = CGSize(width: imgW * scale, height: CGFloat(image.pixelHeight) * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        #else
        return image
        #endif
    }

    // MARK: - URLキャッシュ

    static func urlCacheDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer/urlcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveResolvedURLs(_ urls: [Int: URL], gid: Int) {
        Task.detached(priority: .utility) {
            let path = urlCacheDir().appendingPathComponent("\(gid)_resolved.json")
            let dict = urls.mapValues(\.absoluteString)
            if let data = try? JSONEncoder().encode(dict) { try? data.write(to: path) }
        }
    }

    static func loadResolvedURLs(gid: Int) -> [Int: URL]? {
        let path = urlCacheDir().appendingPathComponent("\(gid)_resolved.json")
        guard let data = try? Data(contentsOf: path),
              let dict = try? JSONDecoder().decode([Int: String].self, from: data) else { return nil }
        var result: [Int: URL] = [:]
        for (k, v) in dict { if let url = URL(string: v) { result[k] = url } }
        return result.isEmpty ? nil : result
    }

    static func saveURLCache(_ urls: [URL], gid: Int) {
        Task.detached(priority: .utility) {
            let path = urlCacheDir().appendingPathComponent("\(gid).json")
            let strings = urls.map(\.absoluteString)
            if let data = try? JSONEncoder().encode(strings) { try? data.write(to: path) }
        }
    }

    static func loadURLCache(gid: Int) -> [URL]? {
        let path = urlCacheDir().appendingPathComponent("\(gid).json")
        guard let data = try? Data(contentsOf: path),
              let strings = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        let urls = strings.compactMap(URL.init(string:))
        return urls.isEmpty ? nil : urls
    }

    // MARK: - ノイズ除去

    nonisolated static func applyDenoiseStatic(_ image: PlatformImage) -> PlatformImage? {
        #if canImport(UIKit)
        return autoreleasepool {
            guard let cgImage = image.cgImage else { return nil }
            var ciImage = CIImage(cgImage: cgImage)
            let ctx = SpriteCache.ciContext
            if let f = CIFilter(name: "CINoiseReduction") {
                f.setValue(ciImage, forKey: kCIInputImageKey)
                f.setValue(0.02, forKey: "inputNoiseLevel")
                f.setValue(0.4, forKey: kCIInputSharpnessKey)
                if let out = f.outputImage { ciImage = out }
            }
            guard let cg = ctx.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: cg)
        }
        #else
        return nil
        #endif
    }
}
