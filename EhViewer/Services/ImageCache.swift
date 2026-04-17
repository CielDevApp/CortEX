import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// アプリ共通の画像キャッシュ（メモリ + ディスク、reader/thumbs分離）
final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSURL, PlatformImage>()
    private var loading: Set<URL> = []
    /// ディスクキャッシュのファイル名一覧（高速存在チェック用）
    private var diskIndex: Set<String> = []

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

    private let fileManager = FileManager.default
    let maxDiskBytes: Int = 8_589_934_592 // 8GB
    private let maxAgeDays: Int = 30

    private var baseDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("EhViewer/cache", isDirectory: true)
    }

    var readerCacheDir: URL {
        let dir = baseDir.appendingPathComponent("reader", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    var thumbsCacheDir: URL {
        let dir = baseDir.appendingPathComponent("thumbs", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // 後方互換: 旧cache/直下のファイルも読める
    private var legacyCacheDir: URL {
        baseDir
    }

    // MARK: - メモリキャッシュ

    func image(for url: URL) -> PlatformImage? {
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
    func memoryImage(for url: URL) -> PlatformImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    /// リーダー用画像を保存
    func set(_ image: PlatformImage, for url: URL) {
        memoryCache.setObject(image, forKey: url as NSURL)
        saveToDisk(image: image, url: url, directory: readerCacheDir)
    }

    /// サムネイル用画像を保存
    func setThumb(_ image: PlatformImage, for url: URL) {
        memoryCache.setObject(image, forKey: url as NSURL)
        saveToDisk(image: image, url: url, directory: thumbsCacheDir)
    }

    func isLoading(_ url: URL) -> Bool { loading.contains(url) }
    func setLoading(_ url: URL) { loading.insert(url) }
    func removeLoading(_ url: URL) { loading.remove(url) }

    /// サムネダウンロードスロットを取得（5並列制限）
    func acquireThumbSlot() async {
        await thumbDownloadSemaphore.wait()
    }

    /// サムネダウンロードスロットを解放
    func releaseThumbSlot() {
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

    func cleanupOnLaunch() {
        Task.detached(priority: .utility) {
            self.buildDiskIndex()
            await self.evictIfNeeded()
        }
    }

    /// ディスクキャッシュのファイル一覧をメモリにロード（起動時）
    private func buildDiskIndex() {
        var index = Set<String>()
        for dir in [readerCacheDir, thumbsCacheDir, legacyCacheDir] {
            if let files = try? fileManager.contentsOfDirectory(atPath: dir.path) {
                index.formUnion(files)
            }
        }
        diskIndex = index
        LogManager.shared.log("App", "disk index: \(index.count) files")
    }

    /// 直近のサムネをNSCacheにプリウォーム
    func prewarmRecentThumbs() {
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

    private func cacheFileHash(for url: URL) -> String {
        let hash = url.absoluteString.utf8.reduce(into: UInt64(5381)) { h, c in
            h = h &* 33 &+ UInt64(c)
        }
        return "\(hash).dat"
    }

    private func loadFromDisk(url: URL) -> PlatformImage? {
        let filename = cacheFileHash(for: url)
        // diskIndexで高速存在チェック（FileManager.fileExists不要）
        guard diskIndex.isEmpty || diskIndex.contains(filename) else { return nil }
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

    private func saveToDisk(image: PlatformImage, url: URL, directory: URL) {
        let filename = cacheFileHash(for: url)
        diskIndex.insert(filename)
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
    private static var lastEvictTime: TimeInterval = 0
    private static let evictThrottleQueue = DispatchQueue(label: "imageCache-evictThrottle")
    private static func scheduleEvictIfNeeded(_ cache: ImageCache) {
        evictThrottleQueue.async {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastEvictTime < 60 { return }
            lastEvictTime = now
            Task.detached(priority: .background) {
                await cache.evictIfNeeded()
            }
        }
    }

    private func evictIfNeeded() async {
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
