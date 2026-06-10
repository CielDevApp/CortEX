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
    /// 直近ロード済みページの縦横比 (height/width)。縦リーダー未ロードセルの高さ推定用。
    /// 初期値 1.42 ≒ 一般的な漫画ページ。@Published にしない: 値更新のたびに既存セルを
    /// 強制再レイアウトすると逆に位置ズレを誘発するため、セル再生成時に反映されれば十分。
    var estimatedPageAspect: CGFloat = 1.42
    /// サムネ placeholder の背景読込中ページ (重複起動防止)
    var thumbPlaceholderLoading: Set<Int> = []
    /// evictDistantHolders の前回掃引中心。毎セル onAppear の全キー走査を抑制する
    /// (Int.min は減算オーバーフローするので十分大きい負数で初期化)
    private var lastEvictionSweepCenter: Int = -(1 << 30)

    // MARK: - 閉鎖フラグ + Task 管理 (2026-06-10)

    /// リーダー閉鎖済みフラグ。close 後も走り続ける unstructured Task や DL 進捗 callback が
    /// holder(for:) 経由で pageHolders を再 populate し、releaseAllForClose の解放を無効化
    /// していた (「リーダー閉じてもメモリ解放されない」3度目指摘の構造的真因)。
    private(set) var isClosed = false
    /// 生成した unstructured Task のハンドル。close 時に一括 cancel するために保持する。
    /// 完了した Task は自己除去するので増殖しない。
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// unstructured Task を activeTasks に登録して生成する。
    /// releaseAllForClose が一括 cancel できるよう、この VM 配下では生の Task {} を直接書かない。
    /// 注意: cancel は協調的なので、呼び出し側はループ/await 後に
    /// `Task.isCancelled || isClosed` を必ずチェックすること (SafetyMode.delay は cancel を握り潰す)。
    func trackTask(priority: TaskPriority? = nil, _ operation: @escaping @MainActor () async -> Void) {
        guard !isClosed else { return }
        let id = UUID()
        let task = Task(priority: priority) { [weak self] in
            await operation()
            self?.activeTasks.removeValue(forKey: id)
        }
        activeTasks[id] = task
    }

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
        // close 後は dict に登録しない: 残存 Task の進捗 callback (onProgress 等) が
        // 解放済みの pageHolders に空 holder を再 populate して解放を無効化するのを防ぐ。
        // 一時 holder を返すので呼び出し側はクラッシュせず、参照が切れれば即 deinit される。
        if !isClosed {
            pageHolders[index] = h
        }
        return h
    }

    // MARK: - UI Actions

    func onAppear(index: Int) {
        guard !isClosed else { return }
        currentIndex = index
        // 横/見開きモードは LazyVStack の onDisappear 経由 eviction が存在せず、
        // 訪問済み全ページのビットマップが pageHolders/rawImages に蓄積し続けていた。
        // onAppear 毎に縦モードと同じ >20/>50 閾値で全ホルダーを掃引する (縦モードでも
        // onDisappear は viewport 離脱時の distance が小さく実質発火しないため両モードで有効)。
        // 閾値 >20 は先読み窓 (最大 ±15) と見開き合成 (±1) の外側なので表示には影響しない。
        // 掃引軽量化 2026-06-10: 毎セル onAppear の全キー走査をやめ、前回掃引から
        // 10 ページ以上移動した時だけ実行 (evict 閾値 >20/>50 に対し余裕があり表示影響なし)。
        if abs(index - lastEvictionSweepCenter) >= 10 {
            lastEvictionSweepCenter = index
            evictDistantHolders(center: index)
        }
        requestLoad(index)
        if !isScrolling && !EcoMode.shared.isEnabled {
            // 田中要望 2026-05-02: iPad 見開きモードは 1 画面 = 2 ページなので
            // ±5 (= 2.5 画面分) では足りず、左右綴じ両対応のため均等に +10 して ±15 に拡張。
            #if canImport(UIKit)
            let isSpread = PagedReaderView.isSpreadMode
            #else
            let isSpread = false
            #endif
            let prefetchRange: Int
            if SafetyMode.shared.isEnabled {
                // 緩和 2026-06-09 (田中要望): 旧 range=1 は見開き(1画面=2ページ)で次の見開き
                // (現在+2,+3) に届かず、到達時DL→左右のhath速度差で片側が低画質になっていた。
                // BAN 予防の本体 (ディレイ + maxConcurrent=5) は維持したまま、先読み窓だけ拡張。
                prefetchRange = isSpread ? 5 : 2
            } else {
                prefetchRange = isSpread ? 15 : 5
            }
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
        trackTask(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer { self.urlPageFetchingSet.remove(neededPage) }
            do {
                let urls = try await self.client.fetchImagePageURLs(host: self.host, gallery: self.gallery, page: neededPage)
                // close 後は releaseAllForClose で空にした imagePageURLs を再構築しない
                if Task.isCancelled || self.isClosed { return }
                if !urls.isEmpty {
                    let offset = neededPage * urlsPerPage
                    var current = self.imagePageURLs
                    while current.count < offset + urls.count {
                        current.append(URL(string: "about:blank")!)
                    }
                    for (i, url) in urls.enumerated() {
                        current[offset + i] = url
                    }
                    self.imagePageURLs = current
                    LogManager.shared.log("Perf", "ensureImagePageURLs: dynamic fetch p=\(neededPage) count=\(urls.count) total=\(current.count)")
                    // 取得完了 → 即座にリクエスト
                    self.requestLoad(index)
                    self.requestLoad(index + 1)
                    self.requestLoad(index - 1)
                }
            } catch {}
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
        evictHolder(index: index, distance: distance)
    }

    /// distance 閾値に応じた段階的解放 (縦 onDisappear / onAppear sweep 共用)。
    ///   - >50: holder ごと破棄
    ///   - >20: ビットマップのみ解放 (holder 構造は維持、再訪時に再ロード)
    /// completedPages も外す: 残すと requestLoad が「完了済み」で早期 return し、
    /// 解放したページに戻った時に画像が永遠に復活しない (解放と再ロード可否はペアで管理)。
    private func evictHolder(index: Int, distance: Int) {
        if distance > 50 {
            pageHolders.removeValue(forKey: index)
            rawImages.removeValue(forKey: index)
            processedPages.remove(index)
            completedPages.remove(index)
        } else if distance > 20 {
            // 旧実装は holder.image = nil のみで originalImage/translatedImage に
            // 同一ビットマップが残り続け実質解放されていなかった → 一括解放に変更。
            pageHolders[index]?.releaseBitmaps()
            rawImages.removeValue(forKey: index)
            processedPages.remove(index)
            completedPages.remove(index)
        }
    }

    /// 全ホルダーを distance ベースで掃引 (横/見開きモードの eviction 経路)。
    /// pageHolders は eviction が効いていれば高々 ~70 エントリなので毎 onAppear で回しても軽い。
    private func evictDistantHolders(center: Int) {
        for index in Array(pageHolders.keys) {
            let distance = abs(index - center)
            if distance > 20 {
                evictHolder(index: index, distance: distance)
            }
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
        trackTask(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for offset in 0...2 {
                // close 後にネットワーク fetch を続けない (3周ループ × DL で VM を retain し続けるため)
                if Task.isCancelled || self.isClosed { return }
                let idx = clamped + offset
                guard idx < self.thumbnails.count else { break }
                let info = self.thumbnails[idx]
                if SpriteCache.shared.sprite(for: info.spriteURL) == nil {
                    if let data = try? await self.client.fetchImageData(url: info.spriteURL, host: self.host) {
                        if Task.isCancelled || self.isClosed { return }
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
        urlResolvingPages.removeAll()
        for (_, holder) in pageHolders {
            // 解放漏れ対策 2026-06-10: image だけでなく originalImage/translatedImage/
            // animatedWebPData/loadProgress も一括リセット (image=nil だけでは同一
            // ビットマップが original/translated に残り解放されない)
            holder.releaseBitmaps()
            holder.isPlaceholder = false
            holder.isFailed = false
            holder.failReason = nil
        }
    }

    /// 田中要望 2026-04-28 (3度目指摘): リーダー閉じる時の memory 完全解放。
    /// resetAllState は qualityModeChanged/filterSettingsChanged からも呼ばれるため holder 構造は維持。
    /// このメソッドは onDisappear 専用で pageHolders/imagePageURLs/thumbnails も全 drop。
    func releaseAllForClose() {
        // 順序重要: 先に閉鎖フラグ + 全 Task cancel。残存 Task の callback が
        // holder(for:) 経由で pageHolders を再 populate するのを塞いでから dict を落とす。
        isClosed = true
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        resetAllState()
        pageHolders.removeAll()
        imagePageURLs.removeAll()
        resolvedImageURLs.removeAll()
        thumbnails.removeAll()
        // 同一 VM が再表示されるケース (push 先から戻る等) で loadImagePages が
        // 「読込済み」扱いのまま空配列で固まるのを防ぐ (URL はディスクキャッシュから復元可能)
        hasLoadedImagePages = false
    }

    /// リーダー再表示時に閉鎖フラグを解除する (GalleryReaderView の onAppear/.task から呼ぶ)。
    /// これが無いと onDisappear → 再表示で isClosed=true のまま全ロードが止まる。
    func reopenForDisplay() {
        isClosed = false
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
        trackTask(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.loadImagePages()
            // close を跨いだら reloadAround で再 populate しない
            if Task.isCancelled || self.isClosed { return }
            self.reloadAround()
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
        trackTask(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.loadImagePages()
            if Task.isCancelled || self.isClosed { return }
            self.reloadAround()
        }
    }

    // MARK: - サムネプレースホルダー

    /// thumbnailImage のメモリキャッシュ限定版 (ディスクIO/デコード/クロップなし)。
    /// requestLoad はセル onAppear ごとに main で同期実行されるため、cache miss 時の
    /// Data(contentsOf:) + CIContext デコードが main を塞ぎスクロールヒッチ源だった。
    /// main 同期パスはメモリヒットのみ即表示し、miss は loadThumbnailPlaceholderAsync へ。
    func thumbnailMemoryImage(for index: Int) -> PlatformImage? {
        if index == 0, let coverURL = gallery.coverURL {
            return ImageCache.shared.memoryImage(for: coverURL)
        }
        guard index < thumbnails.count else { return nil }
        let info = thumbnails[index]
        let key = SpriteCache.shared.croppedKey(url: info.spriteURL, offsetX: info.offsetX)
        return SpriteCache.shared.croppedImageInMemory(key: key)
    }

    /// ロード済み画像から未ロードセルの高さ推定用 aspect を更新。
    /// サムネ (スプライトクロップ) も実ページと同比率なので入力に使ってよい。
    func noteEstimatedAspect(of image: PlatformImage) {
        let w = image.pixelWidth
        guard w > 0 else { return }
        let aspect = CGFloat(image.pixelHeight) / CGFloat(w)
        // 異常値 (誤クロップ等) で placeholder 高さが潰れる/暴れるのを防ぐ
        guard aspect > 0.3, aspect < 3.0 else { return }
        // 微小変動での placeholder 高さジッタを避ける (1% 未満は無視)
        if abs(aspect - estimatedPageAspect) > 0.01 {
            estimatedPageAspect = aspect
        }
    }

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
                if let cropped = sprite.croppedImage(rect: CGRect(x: clampedX, y: 0, width: clampedW, height: clampedH)) {
                    // 書き戻し必須: これが無いとスライダースクラブ中の body 再評価のたびに
                    // 同じスプライトを再クロップして CPU/メモリを浪費していた
                    SpriteCache.shared.setCropped(cropped, key: croppedKey)
                    return cropped
                }
                return nil
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

    /// nonisolated (2026-06-10): UIGraphicsImageRenderer の全面再描画 = 実質フルデコードで、
    /// main 実行だとページ完了のたびスクロールがヒッチした。UIScreen 依存は targetWidth
    /// 引数に切り出し (呼び出し元が main で displayWidth を捕捉)、本体は背景キューで実行可能に。
    nonisolated static func downsample(_ image: PlatformImage, targetWidth: CGFloat) -> PlatformImage {
        #if canImport(UIKit)
        let imgW = CGFloat(image.pixelWidth)
        guard imgW > targetWidth * 1.2 else { return image }
        let scale = targetWidth / imgW
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
