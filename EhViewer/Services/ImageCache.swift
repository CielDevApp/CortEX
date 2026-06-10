import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// アプリ共通の画像キャッシュ（メモリ + ディスク、reader/thumbs分離）
///
/// 読み書き経路 (image(for:) / loadFromDisk / setThumb 等) は nonisolated:
/// プロジェクトの Default Actor Isolation = @MainActor 設定により、無注釈のままだと
/// Task.detached 内から呼んでも main へホップしてディスク I/O が main thread 実行になる
/// (EhClient / HDREnhancer と同じ対策の横展開)。
/// 内部可変状態は NSCache (スレッドセーフ) と NSLock 保護の Set のみ → @unchecked Sendable。
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSURL, PlatformImage>()
    // nonisolated(unsafe): loadingLock 保護下でのみアクセス
    nonisolated(unsafe) private var loading: Set<URL> = []
    /// loading Set への並行 read/write 保護 (FavoritesViewModel.prefetchThumbnails が
    /// detached task から removeLoading 呼ぶと Set の COW で race → swift_isUniquelyReferenced
    /// で SIGSEGV、2026-04-26 観測)。
    private let loadingLock = NSLock()
    /// ディスクキャッシュのファイル名一覧（高速存在チェック用）
    // nonisolated(unsafe): diskIndexLock 保護下でのみアクセス
    nonisolated(unsafe) private var diskIndex: Set<String> = []
    private let diskIndexLock = NSLock()

    /// サムネ同時ダウンロード数制限（GPU化済みなので並列数を増やせる）
    private let thumbDownloadSemaphore = AsyncSemaphore(limit: 20)

    private init() {
        memoryCache.countLimit = 500
        recalculateCacheLimit()

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.recalculateCacheLimit()
            self?.memoryCache.removeAllObjects()
            LogManager.shared.log("App", "memory warning: cache cleared")
        }
        #endif
    }

    /// 空きメモリの12%をキャッシュ上限に設定（100MB〜300MB）
    private func recalculateCacheLimit() {
        let freeMem = Int(os_proc_available_memory())
        let target = max(100 * 1024 * 1024, min(freeMem / 8, 300 * 1024 * 1024))
        memoryCache.totalCostLimit = target
        LogManager.shared.log("App", "cache limit: \(target / 1_048_576)MB (free=\(freeMem / 1_048_576)MB)")
    }

    /// 軽度メモリ圧迫時の soft trim (田中要望 2026-06-09)。
    /// NSCache の totalCostLimit を一時的に半減 → LRU で「最近使っていない=オフスクリーン」
    /// 画像だけが排出される。可視ページは直近使用なので残り、体感は落ちない。
    /// 圧迫が去る頃 (20s 後) に通常上限へ自動復帰。
    func softTrim() {
        let reduced = max(50 * 1024 * 1024, memoryCache.totalCostLimit / 2)
        memoryCache.totalCostLimit = reduced
        LogManager.shared.log("Mem", "softTrim: cost limit → \(reduced / 1_048_576)MB")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.recalculateCacheLimit()
        }
    }

    /// 重度メモリ圧迫時: メモリキャッシュ全破棄 + 上限再計算。
    func clearMemory() {
        memoryCache.removeAllObjects()
        recalculateCacheLimit()
        LogManager.shared.log("Mem", "ImageCache memory cleared (pressure)")
    }

    private let fileManager = FileManager.default
    let maxDiskBytes: Int = 8_589_934_592 // 8GB
    private let maxAgeDays: Int = 30

    nonisolated private var baseDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("EhViewer/cache", isDirectory: true)
    }

    nonisolated var readerCacheDir: URL {
        let dir = baseDir.appendingPathComponent("reader", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    nonisolated var thumbsCacheDir: URL {
        let dir = baseDir.appendingPathComponent("thumbs", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 動画 WebP の生バイト保存先。ImageCache が JPEG 再エンコードして保存するため
    /// アニメ情報が失われる問題への対策。loadFromDisk の前にここを参照する。
    nonisolated var animatedWebPCacheDir: URL {
        let dir = baseDir.appendingPathComponent("animated_webp", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// アニメ WebP 生 Data を URL 単位で永続化。保存先のファイル URL を同期返す
    /// (実ディスク書き込みは background キュー、URL は即返す)。
    /// gid+page も渡された場合、副 index (`byGid/<gid>_<page>.webp` への hard link) を
    /// 作って ThumbnailCellView 等の URL 非保持 view からも参照できるようにする
    /// (混在作品で動画 page にだけマーク表示するための情報源、田中指示 2026-04-25)。
    @discardableResult
    nonisolated func saveAnimatedWebPData(_ data: Data, for url: URL, gid: Int? = nil, page: Int? = nil) -> URL {
        let path = animatedWebPCacheDir.appendingPathComponent(cacheFileHash(for: url))
        // 同期書き込み (return 時点でファイルが disk に在る契約 = AVPlayer が即読める)。
        // nonisolated 化 (2026-06-10): 毎ページ main で write していたのがスクロールヒッチ源
        // だったため、呼び出し側 (loadSingle) は imageQueue 上から呼ぶ。FileManager/write は
        // スレッド安全、同期完了の契約は維持。
        try? data.write(to: path)
        // 副 index (gid+page → 同じ data の hard link)
        if let gid, let page {
            let byGidDir = animatedWebPCacheDir.appendingPathComponent("byGid")
            if !fileManager.fileExists(atPath: byGidDir.path) {
                try? fileManager.createDirectory(at: byGidDir, withIntermediateDirectories: true)
            }
            let altPath = byGidDir.appendingPathComponent("\(gid)_\(page).webp")
            // 既存 link/file があれば削除してから link 張り直す
            try? fileManager.removeItem(at: altPath)
            try? fileManager.linkItem(at: path, to: altPath)
        }
        return path
    }

    /// 過去にアニメ WebP として保存された URL の生 Data を取得 (なければ nil)。
    func loadAnimatedWebPData(for url: URL) -> Data? {
        let path = animatedWebPCacheDir.appendingPathComponent(cacheFileHash(for: url))
        return try? Data(contentsOf: path)
    }

    /// 永続化済み生 WebP のファイル URL を返す (存在しなければ nil)。
    /// Data をメモリに載せず、AVPlayer が disk から直接読めるようにするための API。
    func animatedWebPFileURL(for url: URL) -> URL? {
        let path = animatedWebPCacheDir.appendingPathComponent(cacheFileHash(for: url))
        return fileManager.fileExists(atPath: path.path) ? path : nil
    }

    /// gid+page 副 index 経由で永続化済み animated WebP file URL を返す (存在しなければ nil)。
    /// imageURL 不明な view (詳細画面 ThumbnailCellView 等) から「過去 reader で fetch
    /// 済の動画 page」を判定するための API (田中指示 2026-04-25 混在作品の動画/静画区別)。
    func animatedWebPFileURL(gid: Int, page: Int) -> URL? {
        let path = animatedWebPCacheDir.appendingPathComponent("byGid").appendingPathComponent("\(gid)_\(page).webp")
        return fileManager.fileExists(atPath: path.path) ? path : nil
    }

    // 後方互換: 旧cache/直下のファイルも読める
    nonisolated private var legacyCacheDir: URL {
        baseDir
    }

    // MARK: - メモリキャッシュ

    nonisolated func image(for url: URL) -> PlatformImage? {
        let key = url as NSURL
        if let img = memoryCache.object(forKey: key) { return img }
        let t0 = CFAbsoluteTimeGetCurrent()
        if let img = loadFromDisk(url: url) {
            LogManager.shared.log("Perf", "ImageCache diskRead: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms \(url.lastPathComponent)")
            memoryCache.setObject(img, forKey: key)
            return img
        }
        return nil
    }

    /// メモリキャッシュのみ参照（ディスクI/Oなし、壁紙リフィル等の高頻度呼び出し用）
    nonisolated func memoryImage(for url: URL) -> PlatformImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    /// リーダー用画像を保存
    nonisolated func set(_ image: PlatformImage, for url: URL) {
        memoryCache.setObject(image, forKey: url as NSURL)
        saveToDisk(image: image, url: url, directory: readerCacheDir)
    }

    /// サムネイル用画像を保存
    nonisolated func setThumb(_ image: PlatformImage, for url: URL) {
        memoryCache.setObject(image, forKey: url as NSURL)
        saveToDisk(image: image, url: url, directory: thumbsCacheDir)
    }

    nonisolated func isLoading(_ url: URL) -> Bool {
        loadingLock.lock(); defer { loadingLock.unlock() }
        return loading.contains(url)
    }
    nonisolated func setLoading(_ url: URL) {
        loadingLock.lock(); defer { loadingLock.unlock() }
        loading.insert(url)
    }
    nonisolated func removeLoading(_ url: URL) {
        loadingLock.lock(); defer { loadingLock.unlock() }
        loading.remove(url)
    }

    /// サムネダウンロードスロットを取得（5並列制限）
    nonisolated func acquireThumbSlot() async {
        await thumbDownloadSemaphore.wait()
    }

    /// サムネダウンロードスロットを解放
    nonisolated func releaseThumbSlot() {
        thumbDownloadSemaphore.signal()
    }

    // MARK: - ディスクキャッシュサイズ

    func readerCacheSize() -> Int {
        dirSize(readerCacheDir)
    }

    func thumbsCacheSize() -> Int {
        dirSize(thumbsCacheDir)
    }

    func diskCacheSize() -> Int {
        readerCacheSize() + thumbsCacheSize()
    }

    private func dirSize(_ dir: URL) -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for file in files {
            if let v = try? file.resourceValues(forKeys: [.fileSizeKey]) {
                total += v.fileSize ?? 0
            }
        }
        return total
    }

    /// リーダーキャッシュを削除
    func clearReaderCache() {
        clearDir(readerCacheDir)
        // メモリキャッシュも一応クリア
        memoryCache.removeAllObjects()
    }

    /// 田中要望 2026-04-26: メモリキャッシュのみ flush (disk は残す)、reader close 時の RAM 開放用。
    func purgeMemoryCache() {
        memoryCache.removeAllObjects()
    }

    /// サムネキャッシュを削除
    func clearThumbsCache() {
        clearDir(thumbsCacheDir)
        memoryCache.removeAllObjects()
    }

    /// 全キャッシュ削除
    func clearDiskCache() {
        clearDir(readerCacheDir)
        clearDir(thumbsCacheDir)
        clearDir(legacyCacheDir) // 旧ファイルも掃除
        memoryCache.removeAllObjects()
    }

    private func clearDir(_ dir: URL) {
        if let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                // サブディレクトリは残す
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }

    nonisolated func cleanupOnLaunch() {
        Task.detached(priority: .utility) {
            self.buildDiskIndex()
            await self.evictIfNeeded()
        }
    }

    /// ディスクキャッシュのファイル一覧をメモリにロード（起動時）
    nonisolated private func buildDiskIndex() {
        var index = Set<String>()
        for dir in [readerCacheDir, thumbsCacheDir, legacyCacheDir] {
            if let files = try? fileManager.contentsOfDirectory(atPath: dir.path) {
                index.formUnion(files)
            }
        }
        diskIndexLock.lock()
        diskIndex = index
        diskIndexLock.unlock()
        LogManager.shared.log("App", "disk index: \(index.count) files")
    }

    /// 直近のサムネをNSCacheにプリウォーム
    nonisolated func prewarmRecentThumbs() {
        Task.detached(priority: .utility) {
            let galleries = FavoritesCache.shared.load()
            var loaded = 0
            for g in galleries.prefix(25) {
                if let url = g.coverURL {
                    let key = url as NSURL
                    if self.memoryCache.object(forKey: key) == nil {
                        if let img = self.loadFromDisk(url: url) {
                            self.memoryCache.setObject(img, forKey: key)
                            loaded += 1
                        }
                    }
                }
            }
            LogManager.shared.log("App", "prewarm: \(loaded) thumbs loaded to memory")
        }
    }

    // MARK: - ディスクキャッシュ内部

    nonisolated private func cacheFileHash(for url: URL) -> String {
        let hash = url.absoluteString.utf8.reduce(into: UInt64(5381)) { h, c in
            h = h &* 33 &+ UInt64(c)
        }
        return "\(hash).dat"
    }

    nonisolated private func loadFromDisk(url: URL) -> PlatformImage? {
        let filename = cacheFileHash(for: url)
        // diskIndexで高速存在チェック（FileManager.fileExists不要）
        diskIndexLock.lock()
        let snapshot = diskIndex
        diskIndexLock.unlock()
        guard snapshot.isEmpty || snapshot.contains(filename) else { return nil }
        for dir in [readerCacheDir, thumbsCacheDir, legacyCacheDir] {
            let path = dir.appendingPathComponent(filename)
            if let data = try? Data(contentsOf: path) {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
                // ディスクキャッシュは小画像が多いため CPU デコードが最速
                // GPU dispatch のオーバーヘッドが MainActor をブロックする
                return PlatformImage(data: data)
            }
        }
        return nil
    }

    /// ディスク保存用の専用キュー（MainActor・cooperative pool から完全分離）
    private static let diskWriteQueue = DispatchQueue(label: "imageCache-diskWrite", qos: .utility)

    nonisolated private func saveToDisk(image: PlatformImage, url: URL, directory: URL) {
        let filename = cacheFileHash(for: url)
        diskIndexLock.lock()
        diskIndex.insert(filename)
        diskIndexLock.unlock()
        let path = directory.appendingPathComponent(filename)
        // JPEG エンコード + disk write を専用キューで実行（MainActor ブロック防止）
        let capturedImage = image
        Self.diskWriteQueue.async {
            #if canImport(UIKit)
            guard let data = capturedImage.jpegData(compressionQuality: 0.9) else { return }
            #elseif canImport(AppKit)
            guard let tiff = capturedImage.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
            #endif
            try? data.write(to: path)
        }
        // evict は throttle（保存毎ではなく最大1分1回、cooperative pool占有を回避）
        Self.scheduleEvictIfNeeded(self)
    }

    /// evict throttle 用
    // nonisolated(unsafe): evictThrottleQueue (serial) 上でのみアクセス
    nonisolated(unsafe) private static var lastEvictTime: TimeInterval = 0
    private static let evictThrottleQueue = DispatchQueue(label: "imageCache-evictThrottle")
    nonisolated private static func scheduleEvictIfNeeded(_ cache: ImageCache) {
        evictThrottleQueue.async {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastEvictTime < 60 { return }
            lastEvictTime = now
            Task.detached(priority: .background) {
                await cache.evictIfNeeded()
            }
        }
    }

    nonisolated private func evictIfNeeded() async {
        // reader キャッシュのみ evict 対象
        let dir = readerCacheDir
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        let now = Date()
        let maxAge = TimeInterval(maxAgeDays * 24 * 60 * 60)
        var totalSize: Int = 0
        var fileInfos: [(url: URL, size: Int, date: Date)] = []

        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = values.fileSize ?? 0
            let date = values.contentModificationDate ?? .distantPast

            if now.timeIntervalSince(date) > maxAge {
                try? fileManager.removeItem(at: file)
                continue
            }

            totalSize += size
            fileInfos.append((file, size, date))
        }

        guard totalSize > maxDiskBytes else { return }

        fileInfos.sort { $0.date < $1.date }

        for info in fileInfos {
            guard totalSize > maxDiskBytes else { break }
            try? fileManager.removeItem(at: info.url)
            totalSize -= info.size
        }
    }
}

/// メモリ枯渇を OS の memoryWarning (発火が遅め・全か無か) より早く段階検知し、
/// 可視ページの体感を落とさない範囲で先回り解放する。DispatchSource のメモリ圧迫
/// ソースで warning / critical を区別:
///   - warning: ImageCache を soft trim (NSCache LRU でオフスクリーン静止画のみ排出、
///              可視ページ・再生中アニメは温存 → 体感維持)。
///   - critical: Jetsam 寸前。再デコードが入っても kill より遥かにマシなので全力解放
///              (メモリキャッシュ全破棄 + 全 frameCache 解放 + 多重アニメ停止)。
/// 田中要望 2026-06-09 (DL/閲覧でメモリ枯渇間近に落とさず解放したい)。
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()
    private var source: DispatchSourceMemoryPressure?
    private init() {}

    func start() {
        guard source == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let event = self?.source?.data else { return }
            if event.contains(.critical) {
                MemoryPressureMonitor.handleCritical()
            } else if event.contains(.warning) {
                MemoryPressureMonitor.handleWarning()
            }
        }
        src.resume()
        source = src
        LogManager.shared.log("Mem", "MemoryPressureMonitor started")
    }

    /// 軽度: オフスクリーン中心に解放。可視ページの表示/再生は維持。
    private static func handleWarning() {
        let freeMB = Int(os_proc_available_memory()) / 1_048_576
        LogManager.shared.log("Mem", "pressure=warning free=\(freeMB)MB → soft trim")
        ImageCache.shared.softTrim()
    }

    /// 重度: Jetsam 寸前。全力解放 (kill 回避を最優先)。
    private static func handleCritical() {
        let freeMB = Int(os_proc_available_memory()) / 1_048_576
        LogManager.shared.log("Mem", "pressure=critical free=\(freeMB)MB → full release")
        ImageCache.shared.clearMemory()
        #if canImport(UIKit)
        BoomerangWebPView.systemDowngraded = true
        AnimatedImageSourceRegistry.shared.dropAllCaches()
        Task { @MainActor in
            AnimatedImageSourceCache.shared.clear()
            AnimatedPlaybackCoordinator.shared.stopAll()
        }
        #endif
    }
}
