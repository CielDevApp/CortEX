import Foundation
import Combine
import UserNotifications
import ImageIO
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct DownloadedGallery: Codable, Identifiable, Sendable {
    var gid: Int
    var token: String
    var title: String
    var coverFileName: String?
    var pageCount: Int
    var downloadDate: Date
    var isComplete: Bool
    var downloadedPages: [Int]
    var source: String?  // "ehentai" or "nhentai"（nilは旧データ=ehentai）
    /// 明示的にキャンセルされたか（trueなら起動時autoResumeをスキップ）
    var isCancelled: Bool? = nil

    var id: Int { gid }
    nonisolated var directoryName: String { "\(gid)" }
    var isNhentai: Bool { source == "nhentai" || token.hasPrefix("nh") }
    /// タイトル文字列から動画作品を推定（"Animated"/"GIF"/"🎥" を含むか）
    var isAnimatedGallery: Bool {
        let t = title
        return t.contains("Animated") || t.contains("GIF") || t.contains("gif") || t.contains("🎥")
    }
    /// nhentai用: 実際のnhentai IDを返す（gidは-nhIdで保存）
    var nhentaiId: Int? {
        guard isNhentai else { return nil }
        if gid < 0 { return -gid }
        return gid // 旧データ（正数gid）
    }
}

class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// カバー画像メモリキャッシュ（DownloadsView 再レンダー時 disk I/O 回避）
    /// NSCache は iOS メモリプレッシャーで自動退避される
    private let coverCache: NSCache<NSNumber, PlatformImage> = {
        let c = NSCache<NSNumber, PlatformImage>()
        c.countLimit = 100
        return c
    }()
    /// gid ごとの DL 済みバイト累積（ページ完了単位。残り容量推定の平均計算用）
    private var downloadedBytes: [Int: Int64] = [:]
    /// gid ごとの DL 開始時点の on-disk バイト数（リアルタイム表示の基準値）
    private var initialOnDiskBytes: [Int: Int64] = [:]

    @Published var downloads: [Int: DownloadedGallery] = [:] {
        didSet { activeDownloadCount = downloads.values.filter { !$0.isComplete }.count }
    }
    @Published var activeDownloads: [Int: DownloadProgress] = [:]
    /// 未完了ダウンロード件数（バッジ表示用）
    @Published var activeDownloadCount: Int = 0
    /// 最後にインポートされたギャラリーのgid（ハイライト表示用）
    @Published var lastImportedGid: Int?

    struct DownloadProgress {
        var current: Int
        var total: Int
        var isCancelled: Bool = false
        var phase: Phase = .preparing
        nonisolated var fraction: Double { total > 0 ? Double(current) / Double(total) : 0 }

        /// DL フェーズ: UI 側で「準備中」「通常DL」「リトライ中」を区別するため
        enum Phase: Sendable {
            case preparing   // URL 取得中など、progress 0/0 で見える期間
            case active      // 1stpass 通常 DL 中
            case retrying    // 2ndpass に入った (低速 mirror 再試行中)
        }
    }

    private let client = EhClient.shared
    private let fileManager = FileManager.default
    private let requestDelay: UInt64 = 2_000_000_000
    /// URL解決フェーズの直列化（複数DLが同時にページURL取得→ネットワーク飽和防止）
    private let urlResolveSemaphore = AsyncSemaphore(limit: 1)

    /// リーダー表示中のギャラリーID（DL速度を落としてリーダー優先）
    @MainActor static var readerActiveGids: Set<Int> = []
    @MainActor static func setReaderActive(gid: Int, active: Bool) {
        if active { readerActiveGids.insert(gid) } else { readerActiveGids.remove(gid) }
    }
    nonisolated static func isReaderActive(gid: Int) async -> Bool {
        await MainActor.run { readerActiveGids.contains(gid) }
    }

    /// Live Activity管理
    private var liveActivities: [Int: String] = [:] // gid → activityID

    /// 双方向DL用の共有状態（gid単位）
    private var biDirStates: [Int: BiDirectionalState] = [:]

    /// 双方向ダウンロード共有状態
    class BiDirectionalState {
        var downloadedSet: Set<Int> = []
        var allPageURLs: [URL] = []
        var totalPages: Int = 0
        var backwardCancelled = false
        // nhentai用: CDNフォールバックに必要な情報
        var nhGalleryId: Int = 0
        var nhMediaId: String?
        var nhPages: [NhentaiClient.NhPage]?
        var backwardRunning = false             // 後方DLが実行中か
        var failedPages: [(index: Int, pageURL: URL)] = []
    }

    private init() {
        loadAllMetadata()
        repairBrokenDownloads()
        cleanupTrashDownloads()
        // Live Activityクリーンアップ→ダウンロード再開を順序保証
        Task {
            await cleanupStaleLiveActivities()
            await resumeIncompleteDownloads()
        }
        // 速度サンプラー撤去: activeDownloads mutation→DownloadsView全再レンダー
        // で 150ms/秒 のメインスレッドハング。speed 表示は per-row TimelineView で取得。
    }

    /// 前回の強制終了等で残った古いLive Activityを全て終了
    private func cleanupStaleLiveActivities() async {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let staleActivities = Activity<DownloadActivityAttributes>.activities
        if !staleActivities.isEmpty {
            LogManager.shared.log("LiveActivity", "cleaning up \(staleActivities.count) stale activities")
        }
        for activity in staleActivities {
            LogManager.shared.log("LiveActivity", "cleanup stale: gid=\(activity.attributes.gid) id=\(activity.id)")
            let state = DownloadActivityAttributes.ContentState(
                currentPage: 0, progress: 0, isComplete: false, isFailed: true
            )
            await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        liveActivities.removeAll()
        #endif
    }

    /// 未完了ダウンロードを自動再開（キャンセル済みはスキップ）
    private func resumeIncompleteDownloads() async {
        let incompleteItems = downloads.filter {
            !$0.value.isComplete && !$0.value.token.isEmpty && $0.value.isCancelled != true
        }
        if incompleteItems.isEmpty { return }
        LogManager.shared.log("Download", "found \(incompleteItems.count) incomplete downloads to resume")

        for (gid, meta) in incompleteItems {
            guard activeDownloads[gid] == nil else { continue }
            let total = max(meta.pageCount, 1)
            let current = meta.downloadedPages.count
            LogManager.shared.log("Download", "auto-resume: gid=\(gid) \(current)/\(total) source=\(meta.source ?? "ehentai") title=\(meta.title)")

            // nhentaiのDLはAPI経由で再開（E-Hentaiと別処理）
            if meta.isNhentai {
                guard let nhId = meta.nhentaiId else { continue }
                activeDownloads[gid] = DownloadProgress(current: current, total: total)
                startLiveActivity(gid: gid, title: meta.title, totalPages: total, initialPage: current)
                Task(priority: .utility) {
                    await ExtremeMode.shared.delay(nanoseconds: 3_000_000_000)
                    if let nhGallery = try? await NhentaiClient.fetchGallery(id: nhId) {
                        await performNhentaiDownload(nhGallery: nhGallery)
                    } else {
                        LogManager.shared.log("Download", "nhentai resume failed: could not fetch gallery \(nhId)")
                        activeDownloads.removeValue(forKey: gid)
                        endLiveActivity(gid: gid, success: false)
                    }
                }
            } else {
                activeDownloads[gid] = DownloadProgress(current: current, total: total)
                startLiveActivity(gid: gid, title: meta.title, totalPages: total, initialPage: current)
                Task(priority: .utility) {
                    await ExtremeMode.shared.delay(nanoseconds: 3_000_000_000)
                    await performDownload(
                        gid: gid, token: meta.token, title: meta.title,
                        coverURL: nil, pageCount: meta.pageCount,
                        galleryURLStr: "https://exhentai.org/g/\(gid)/\(meta.token)/",
                        host: .exhentai
                    )
                }
            }
        }
    }

    // MARK: - ディレクトリ

    private var baseDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("EhViewer/downloads", isDirectory: true)
    }

    func galleryDirectory(gid: Int) -> URL {
        baseDirectory.appendingPathComponent("\(gid)", isDirectory: true)
    }

    func ensureDirectory(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - メタデータ

    private func metadataURL(gid: Int) -> URL {
        galleryDirectory(gid: gid).appendingPathComponent("metadata.json")
    }

    func saveMetadata(_ meta: DownloadedGallery) {
        let url = metadataURL(gid: meta.gid)
        ensureDirectory(galleryDirectory(gid: meta.gid))
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: url)
        }
        downloads[meta.gid] = meta
    }

    private func loadMetadata(gid: Int) -> DownloadedGallery? {
        let url = metadataURL(gid: gid)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DownloadedGallery.self, from: data)
    }

    private func loadAllMetadata() {
        ensureDirectory(baseDirectory)
        guard let contents = try? fileManager.contentsOfDirectory(atPath: baseDirectory.path) else { return }
        for dir in contents {
            if let gid = Int(dir), let meta = loadMetadata(gid: gid) {
                downloads[gid] = meta
            }
        }
    }

    // MARK: - 画像ファイルパス

    func imageFilePath(gid: Int, page: Int) -> URL {
        galleryDirectory(gid: gid).appendingPathComponent("page_\(String(format: "%04d", page)).jpg")
    }

    func coverFilePath(gid: Int) -> URL {
        galleryDirectory(gid: gid).appendingPathComponent("cover.jpg")
    }

    func loadLocalImage(gid: Int, page: Int) -> PlatformImage? {
        let path = imageFilePath(gid: gid, page: page)
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        return PlatformImage(contentsOfFile: path.path)
    }

    /// ローカル画像のData（アニメGIF/WebP判定用）
    func loadLocalImageData(gid: Int, page: Int) -> Data? {
        let path = imageFilePath(gid: gid, page: page)
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        return try? Data(contentsOf: path)
    }

    func loadCoverImage(gid: Int) -> PlatformImage? {
        let key = NSNumber(value: gid)
        if let cached = coverCache.object(forKey: key) {
            return cached
        }
        let path = coverFilePath(gid: gid)
        if fileManager.fileExists(atPath: path.path),
           let image = PlatformImage(contentsOfFile: path.path) {
            coverCache.setObject(image, forKey: key)
            return image
        }
        // カバーが存在しない場合は1枚目をリサイズして代用 + cover.jpgに保存
        if let img = generateCoverFromFirstPage(gid: gid) {
            coverCache.setObject(img, forKey: key)
            return img
        }
        return nil
    }

    /// 1枚目の画像をリサイズしてcover.jpgとして保存、結果を返す
    /// 動画WebPで UIImage(contentsOfFile:) が全フレーム展開→OOM するため
    /// CGImageSource の mmap + サムネイルデコード（先頭フレームのみ）で読む
    private func generateCoverFromFirstPage(gid: Int) -> PlatformImage? {
        #if canImport(UIKit)
        var srcFileURL: URL?
        for page in 0..<5 {
            let p = imageFilePath(gid: gid, page: page)
            if fileManager.fileExists(atPath: p.path) {
                srcFileURL = p
                break
            }
        }
        guard let fileURL = srcFileURL,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        let img = UIImage(cgImage: cg)
        if let data = img.jpegData(compressionQuality: 0.85) {
            try? data.write(to: coverFilePath(gid: gid))
            LogManager.shared.log("Download", "generated cover from page 0 for gid=\(gid)")
        }
        return img
        #else
        return nil
        #endif
    }

    // MARK: - 自動保存（オンライン閲覧時）

    /// オンライン閲覧中の画像データをDLフォルダに保存（バックグラウンド）
    func autoSavePage(gid: Int, token: String, title: String, pageCount: Int, page: Int, imageData: Data) {
        guard UserDefaults.standard.bool(forKey: "autoSaveOnRead") else { return }

        let dir = galleryDirectory(gid: gid)
        ensureDirectory(dir)

        let filePath = imageFilePath(gid: gid, page: page)
        guard !fileManager.fileExists(atPath: filePath.path) else { return }

        LogManager.shared.log("AutoSave", "gid=\(gid) page \(page + 1)/\(pageCount) size=\(imageData.count) bytes")

        let coverPath = coverFilePath(gid: gid)
        let needsCover = page == 0 && !fileManager.fileExists(atPath: coverPath.path)

        Task.detached(priority: .utility) {
            try? imageData.write(to: filePath)

            // 最初のページをカバー画像としてもコピー
            if needsCover {
                try? imageData.write(to: coverPath)
            }

            await MainActor.run {
                // メタデータ更新
                var meta = self.downloads[gid] ?? DownloadedGallery(
                    gid: gid, token: token, title: title,
                    coverFileName: "cover.jpg", pageCount: pageCount,
                    downloadDate: Date(), isComplete: false, downloadedPages: []
                )
                if !meta.downloadedPages.contains(page) {
                    meta.downloadedPages.append(page)
                }
                meta.isComplete = meta.downloadedPages.count >= pageCount
                self.saveMetadata(meta)
            }
        }
    }

    /// カバー画像の自動保存
    func autoSaveCover(gid: Int, imageData: Data) {
        guard UserDefaults.standard.bool(forKey: "autoSaveOnRead") else { return }
        let coverPath = coverFilePath(gid: gid)
        guard !fileManager.fileExists(atPath: coverPath.path) else { return }
        Task.detached(priority: .utility) {
            try? imageData.write(to: coverPath)
        }
    }

    /// リーダーを閉じる時の自動保存完了チェック
    func checkAutoSaveCompletion(gid: Int, pageCount: Int) -> (saved: Int, total: Int) {
        guard let meta = downloads[gid] else { return (0, pageCount) }
        return (meta.downloadedPages.count, pageCount)
    }

    // MARK: - 状態確認

    func isDownloaded(gid: Int) -> Bool {
        guard let meta = downloads[gid] else { return false }
        return meta.isComplete && meta.downloadedPages.count > 0
    }

    /// 壊れたメタデータ（0ページでisComplete=true）を修復
    func repairBrokenDownloads() {
        for (gid, meta) in downloads {
            if meta.isComplete && meta.downloadedPages.isEmpty {
                LogManager.shared.log("Download", "repairing broken metadata: gid=\(gid) title=\(meta.title)")
                var fixed = meta
                fixed.isComplete = false
                saveMetadata(fixed)
            }
        }
    }

    /// 0/0 ゴミダウンロード（pageCount=0 または token空）を自動削除
    /// notLoggedIn 等で allPageURLs.isEmpty → ABORT 前に作られていた残骸を掃除する
    func cleanupTrashDownloads() {
        let trash = downloads.filter { (_, meta) in
            guard !meta.isComplete else { return false }
            // pageCount=0 or 空token = 再開しても再取得不可 = ゴミ
            return meta.pageCount == 0 || meta.token.isEmpty
        }
        if trash.isEmpty { return }
        LogManager.shared.log("Download", "cleanupTrashDownloads: removing \(trash.count) trash entries")
        for (gid, meta) in trash {
            LogManager.shared.log("Download", "  trash: gid=\(gid) pageCount=\(meta.pageCount) token='\(meta.token)' title=\(meta.title)")
            deleteDownload(gid: gid)
        }
    }

    func isDownloading(gid: Int) -> Bool {
        activeDownloads[gid] != nil
    }

    // MARK: - Live Activity

    private func startLiveActivity(gid: Int, title: String, totalPages: Int, initialPage: Int = 0) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            LogManager.shared.log("LiveActivity", "activities not enabled")
            return
        }

        let attributes = DownloadActivityAttributes(
            galleryTitle: title,
            totalPages: totalPages,
            gid: gid
        )
        let initialProgress = totalPages > 0 ? Double(initialPage) / Double(totalPages) : 0
        let state = DownloadActivityAttributes.ContentState(
            currentPage: initialPage,
            progress: initialProgress,
            isComplete: false,
            isFailed: false
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            liveActivities[gid] = activity.id
            LogManager.shared.log("LiveActivity", "started: gid=\(gid) id=\(activity.id) title=\(title) total=\(totalPages)")
        } catch {
            LogManager.shared.log("LiveActivity", "failed to start: \(error)")
        }
        #endif
    }

    private func updateLiveActivity(gid: Int, current: Int, total: Int) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard let activityID = liveActivities[gid] else { return }
        let progress = total > 0 ? Double(current) / Double(total) : 0
        LogManager.shared.log("LiveActivity", "update: gid=\(gid) page=\(current)/\(total) progress=\(Int(progress * 100))%")

        let state = DownloadActivityAttributes.ContentState(
            currentPage: current,
            progress: progress,
            isComplete: false,
            isFailed: false
        )

        Task {
            for activity in Activity<DownloadActivityAttributes>.activities where activity.id == activityID {
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
        #endif
    }

    private func endLiveActivity(gid: Int, success: Bool) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard let activityID = liveActivities.removeValue(forKey: gid) else { return }
        let state = DownloadActivityAttributes.ContentState(
            currentPage: 0,
            progress: success ? 1 : 0,
            isComplete: success,
            isFailed: !success
        )

        Task {
            for activity in Activity<DownloadActivityAttributes>.activities where activity.id == activityID {
                await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 5))
                LogManager.shared.log("LiveActivity", "ended: gid=\(gid) success=\(success)")
            }
        }
        #endif
    }

    // MARK: - ダウンロード操作

    func startDownload(gallery: Gallery, host: GalleryHost) {
        guard activeDownloads[gallery.gid] == nil else {
            LogManager.shared.log("Download", "already downloading gid=\(gallery.gid)")
            return
        }

        let gid = gallery.gid
        let token = gallery.token
        let title = gallery.title
        let coverURL = gallery.coverURL
        let pageCount = gallery.pageCount
        let galleryURLStr = gallery.galleryURL(host: host)

        LogManager.shared.log("Download", "startDownload: gid=\(gid) token=\(token) pageCount=\(pageCount)")
        LogManager.shared.log("Download", "  title=\(title)")
        LogManager.shared.log("Download", "  galleryURL=\(galleryURLStr)")
        LogManager.shared.log("Download", "  coverURL=\(coverURL?.absoluteString ?? "nil")")

        // メタデータを即座に保存（既存ありならキャンセルフラグのみリセット）
        if var existing = downloads[gid] {
            if existing.isCancelled == true {
                existing.isCancelled = false
                saveMetadata(existing)
            }
        } else {
            let meta = DownloadedGallery(
                gid: gid, token: token, title: title,
                coverFileName: "cover.jpg", pageCount: pageCount,
                downloadDate: Date(), isComplete: false, downloadedPages: []
            )
            saveMetadata(meta)
        }

        activeDownloads[gid] = DownloadProgress(current: 0, total: max(pageCount, 1))
        startLiveActivity(gid: gid, title: title, totalPages: max(pageCount, 1))

        Task(priority: .high) {
            await performDownload(
                gid: gid, token: token, title: title,
                coverURL: coverURL, pageCount: pageCount,
                galleryURLStr: galleryURLStr, host: host
            )
        }
    }

    // MARK: - nhentaiダウンロード

    func startNhentaiDownload(gallery: NhentaiClient.NhGallery) {
        let gid = -gallery.id  // 負数で区別
        guard activeDownloads[gid] == nil else {
            LogManager.shared.log("Download", "already downloading nhentai gid=\(gallery.id)")
            return
        }
        // 既にDL完了済みならスキップ
        if let existing = downloads[gid], existing.isComplete {
            LogManager.shared.log("Download", "already complete nhentai gid=\(gallery.id)")
            return
        }

        LogManager.shared.log("Download", "startNhentaiDownload: id=\(gallery.id) pages=\(gallery.num_pages) title=\(gallery.displayTitle)")

        if var existing = downloads[gid] {
            if existing.isCancelled == true {
                existing.isCancelled = false
                saveMetadata(existing)
            }
        } else {
            let meta = DownloadedGallery(
                gid: gid, token: "nh_\(gallery.media_id)", title: gallery.displayTitle,
                coverFileName: "cover.jpg", pageCount: gallery.num_pages,
                downloadDate: Date(), isComplete: false, downloadedPages: [],
                source: "nhentai"
            )
            saveMetadata(meta)
        }

        activeDownloads[gid] = DownloadProgress(current: 0, total: gallery.num_pages)
        startLiveActivity(gid: gid, title: gallery.displayTitle, totalPages: gallery.num_pages)

        let capturedGallery = gallery
        Task(priority: .high) {
            await performNhentaiDownload(nhGallery: capturedGallery)
        }
    }

    private func performNhentaiDownload(nhGallery: NhentaiClient.NhGallery) async {
        let gid = -nhGallery.id
        let totalPages = nhGallery.num_pages

        LogManager.shared.log("Download", "nhentai download START: id=\(nhGallery.id) pages=\(totalPages)")

        // 残り容量推定用バイト累計を初期化
        initializeBytesCounter(gid: gid)

        #if canImport(UIKit)
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "NhDL-\(nhGallery.id)") {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
        defer {
            if bgTaskID != .invalid { UIApplication.shared.endBackgroundTask(bgTaskID) }
        }
        #endif

        let dir = galleryDirectory(gid: gid)
        ensureDirectory(dir)

        var meta = downloads[gid] ?? DownloadedGallery(
            gid: gid, token: "nh_\(nhGallery.media_id)", title: nhGallery.displayTitle,
            coverFileName: "cover.jpg", pageCount: totalPages,
            downloadDate: Date(), isComplete: false, downloadedPages: [],
            source: "nhentai"
        )

        // カバー保存
        if let cover = nhGallery.images?.cover {
            let coverPath = coverFilePath(gid: gid)
            if !fileManager.fileExists(atPath: coverPath.path) {
                if let data = try? await NhentaiClient.fetchCoverImage(galleryId: nhGallery.id, mediaId: nhGallery.media_id, ext: cover.ext) {
                    try? data.write(to: coverPath)
                }
            }
        }

        // 全ページURLを生成
        let nhPages = nhGallery.images?.pages ?? []
        let allPageURLs: [URL] = (0..<totalPages).map { index in
            let page = index < nhPages.count ? nhPages[index] : NhentaiClient.NhPage(t: "j", w: 0, h: 0)
            return NhentaiClient.imageURL(mediaId: nhGallery.media_id, page: index + 1, ext: page.ext)
        }

        // 双方向DL用共有状態
        let state = BiDirectionalState()
        state.allPageURLs = allPageURLs
        state.totalPages = totalPages
        state.downloadedSet = Set(meta.downloadedPages)
        state.nhGalleryId = nhGallery.id
        state.nhMediaId = nhGallery.media_id
        state.nhPages = nhGallery.images?.pages ?? []
        biDirStates[gid] = state

        updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)

        // Batch enqueue方式: 全ページを background URLSession に一括投入
        // → アプリsuspend中もiOSが処理継続
        // → 各完了は AsyncStream で受領してprogress更新
        let stream = BackgroundDownloadManager.shared.makeStream(for: gid)
        // ページごとの候補URL配列（retry用）
        var candidates: [Int: [URL]] = [:]
        let session = BackgroundDownloadManager.shared.nhSession
        let nhHeaders = ["Referer": "https://nhentai.net/"]

        // 既存ファイル + 未DL分の候補URL準備（事前に全部計算）
        for index in 0..<totalPages {
            if state.downloadedSet.contains(index) { continue }
            let filePath = imageFilePath(gid: gid, page: index)
            if fileManager.fileExists(atPath: filePath.path) {
                state.downloadedSet.insert(index)
                continue
            }
            let nhPage = state.nhPages?[index]
            let urls = await NhentaiClient.candidateImageURLs(
                galleryId: state.nhGalleryId,
                mediaId: state.nhMediaId ?? "",
                page: index + 1,
                ext: nhPage?.ext ?? "jpg"
            )
            candidates[index] = urls
        }

        updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
        LogManager.shared.log("Download", "nhentai batch enqueue: gid=\(gid) pending=\(candidates.count)")

        // 最初の候補URLをすべて一括enqueue（suspend耐性）
        for (index, urls) in candidates {
            guard let firstURL = urls.first else { continue }
            let filePath = imageFilePath(gid: gid, page: index)
            BackgroundDownloadManager.shared.enqueue(
                url: firstURL, gid: gid, pageIndex: index, finalPath: filePath,
                session: session, headers: nhHeaders
            )
        }

        // 完了ストリームから順次進捗更新
        // ページごとに試行した候補インデックス
        var candidateTriedCount: [Int: Int] = [:]  // index → 試した候補数
        for index in candidates.keys { candidateTriedCount[index] = 1 }  // 既に1回enqueue済み
        var pendingCount = candidates.count

        for await completion in stream {
            if activeDownloads[gid]?.isCancelled == true {
                BackgroundDownloadManager.shared.cancelAllTasks(for: gid, session: session)
                break
            }

            let index = completion.pageIndex
            if completion.success {
                state.downloadedSet.insert(index)
                addDownloadedBytes(gid: gid, page: index)
                updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
                pendingCount -= 1
            } else {
                // 次の候補URLでretry
                let tried = candidateTriedCount[index] ?? 0
                let urls = candidates[index] ?? []
                if tried < urls.count {
                    let nextURL = urls[tried]
                    candidateTriedCount[index] = tried + 1
                    let filePath = imageFilePath(gid: gid, page: index)
                    BackgroundDownloadManager.shared.enqueue(
                        url: nextURL, gid: gid, pageIndex: index, finalPath: filePath,
                        session: session, headers: nhHeaders
                    )
                } else {
                    // 全候補失敗
                    state.failedPages.append((index: index, pageURL: urls.first ?? URL(string: "about:blank")!))
                    pendingCount -= 1
                }
            }
            if pendingCount <= 0 { break }
        }

        meta.downloadedPages = Array(state.downloadedSet)
        meta.isComplete = totalPages > 0 && state.downloadedSet.count >= totalPages
        meta.downloadDate = Date()
        let finalMeta = meta
        let completed = meta.isComplete
        await MainActor.run {
            saveMetadata(finalMeta)
            var updatedActive = activeDownloads
            updatedActive.removeValue(forKey: gid)
            activeDownloads = updatedActive
            biDirStates.removeValue(forKey: gid)
            endLiveActivity(gid: gid, success: completed)
        }
        LogManager.shared.log("Download", "nhentai finished: \(state.downloadedSet.count)/\(totalPages) isComplete=\(completed)")

        if completed {
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            sendDownloadCompleteNotification(title: finalMeta.title)
        }
    }

    /// nhentai後方DL
    private func performNhBackward(gid: Int, nhGallery: NhentaiClient.NhGallery) async {
        guard let state = biDirStates[gid] else { return }
        let totalPages = state.totalPages

        for index in stride(from: totalPages - 1, through: 0, by: -1) {
            if state.backwardCancelled || activeDownloads[gid]?.isCancelled == true { break }
            if state.downloadedSet.contains(index) { continue }
            let filePath = imageFilePath(gid: gid, page: index)
            if fileManager.fileExists(atPath: filePath.path) {
                state.downloadedSet.insert(index)
                continue
            }
            let nhPage3 = state.nhPages?[index]
            let success = await downloadNhPage(gid: gid, galleryId: state.nhGalleryId, index: index, mediaId: state.nhMediaId ?? "", pageNum: index + 1, ext: nhPage3?.ext ?? "jpg", filePath: filePath, maxRetries: 3)
            if success {
                state.downloadedSet.insert(index)
                addDownloadedBytes(gid: gid, page: index)
                updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
            } else {
                state.failedPages.append((index: index, pageURL: state.allPageURLs[index]))
            }
            if state.downloadedSet.count >= totalPages { break }
        }
        state.backwardRunning = false
    }

    /// nhentai単一ページDL（CDN動的解決付きリトライ）
    private func downloadNhPage(gid: Int, galleryId: Int, index: Int, mediaId: String, pageNum: Int, ext: String, filePath: URL, maxRetries: Int) async -> Bool {
        // Background URLSessionを使用 → アプリsuspend中もDL継続
        let urls = await NhentaiClient.candidateImageURLs(galleryId: galleryId, mediaId: mediaId, page: pageNum, ext: ext)
        for attempt in 1...maxRetries {
            for url in urls {
                let ok = await BackgroundDownloadManager.shared.downloadToFile(
                    url: url,
                    session: BackgroundDownloadManager.shared.nhSession,
                    finalPath: filePath,
                    headers: ["Referer": "https://nhentai.net/"]
                )
                if ok, BackgroundDownloadManager.isValidImageFile(at: filePath) {
                    return true
                }
                // 無効ファイル（HTMLなど）は削除して次のCDN試行
                try? FileManager.default.removeItem(at: filePath)
            }
            if attempt < maxRetries {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
            }
        }
        LogManager.shared.log("Download", "nhentai page \(index + 1) all CDNs failed after \(maxRetries) attempts")
        return false
    }

    func cancelDownload(gid: Int) {
        activeDownloads[gid]?.isCancelled = true
        // 永続化: 起動時autoResumeをスキップさせる
        if var meta = downloads[gid] {
            meta.isCancelled = true
            saveMetadata(meta)
        }
    }

    /// 未完了ダウンロードをすべて手動再開（キャンセル済みも含めてリセット）
    /// nhentai と E-Hentai で再開経路が違うので分岐する
    func resumeAllIncomplete() {
        // ゴミ（0/0 や token空）は先に掃除して対象から外す
        cleanupTrashDownloads()
        let incomplete = downloads.filter {
            !$0.value.isComplete && !$0.value.token.isEmpty && activeDownloads[$0.key] == nil
        }
        LogManager.shared.log("Download", "resumeAllIncomplete: \(incomplete.count) items")
        if incomplete.isEmpty {
            LogManager.shared.log("Download", "resumeAllIncomplete: no resumable items (check: not complete, has token, not already active)")
            return
        }
        for (gid, var meta) in incomplete {
            if meta.isCancelled == true {
                meta.isCancelled = false
                saveMetadata(meta)
            }
            if meta.isNhentai {
                guard let nhId = meta.nhentaiId else {
                    LogManager.shared.log("Download", "resumeAllIncomplete: skip nhentai gid=\(gid) (no nhentaiId)")
                    continue
                }
                let total = max(meta.pageCount, 1)
                let current = meta.downloadedPages.count
                LogManager.shared.log("Download", "resumeAllIncomplete: nhentai gid=\(gid) nhId=\(nhId) \(current)/\(total)")
                activeDownloads[gid] = DownloadProgress(current: current, total: total)
                startLiveActivity(gid: gid, title: meta.title, totalPages: total, initialPage: current)
                Task(priority: .high) {
                    if let nhGallery = try? await NhentaiClient.fetchGallery(id: nhId) {
                        await performNhentaiDownload(nhGallery: nhGallery)
                    } else {
                        LogManager.shared.log("Download", "nhentai resume failed: fetchGallery(\(nhId))")
                        await MainActor.run {
                            self.activeDownloads.removeValue(forKey: gid)
                            self.endLiveActivity(gid: gid, success: false)
                        }
                    }
                }
            } else {
                LogManager.shared.log("Download", "resumeAllIncomplete: ehentai gid=\(gid) token=\(meta.token)")
                let gallery = Gallery(
                    gid: gid, token: meta.token,
                    title: meta.title, category: nil, coverURL: nil,
                    rating: 0, pageCount: meta.pageCount,
                    postedDate: "", uploader: nil, tags: []
                )
                startDownload(gallery: gallery, host: .exhentai)
            }
        }
    }

    /// サーバー側の問題で永久 DL 失敗するページがある場合の救済:
    /// 現在の downloadedPages だけで "完了" とマークし、auto-resume を停止
    func markAsCompleteIgnoringMissing(gid: Int) {
        guard var meta = downloads[gid] else { return }
        meta.isComplete = true
        meta.downloadDate = Date()
        saveMetadata(meta)
        if activeDownloads[gid] != nil {
            activeDownloads[gid]?.isCancelled = true
            activeDownloads.removeValue(forKey: gid)
        }
        endLiveActivity(gid: gid, success: true)
        LogManager.shared.log("Download", "gid=\(gid) manually marked complete (missing \(meta.pageCount - meta.downloadedPages.count) pages)")
    }

    func deleteDownload(gid: Int) {
        // 進行中タスクキャンセル + isCancelled 永続化（saveMetadata 経由で復活しない）
        if activeDownloads[gid] != nil {
            activeDownloads[gid]?.isCancelled = true
        }
        // LiveActivity 終了（通知センター/Dynamic Islandから消す）
        endLiveActivity(gid: gid, success: false)
        let dir = galleryDirectory(gid: gid)
        try? fileManager.removeItem(at: dir)
        downloads.removeValue(forKey: gid)
        activeDownloads.removeValue(forKey: gid)
        coverCache.removeObject(forKey: NSNumber(value: gid))
    }

    /// @Published辞書のin-place mutationはSwiftUIに通知されないため、辞書を再代入して通知する
    /// スロットルは cover cache 導入で再レンダーが安くなったので撤去（リアルタイム表示）
    /// phase は既存値を保持、別途 updatePhase() で変更する
    private func updateProgress(gid: Int, current: Int, total: Int) {
        var updated = activeDownloads
        let prevPhase = updated[gid]?.phase ?? .preparing
        let prevCancelled = updated[gid]?.isCancelled ?? false
        updated[gid] = DownloadProgress(current: current, total: total, isCancelled: prevCancelled, phase: prevPhase)
        activeDownloads = updated
        updateLiveActivity(gid: gid, current: current, total: total)
    }

    /// DL phase のみを更新 (UI 表示切替用)
    /// preparing → active → retrying の遷移に対応
    private func updatePhase(gid: Int, phase: DownloadProgress.Phase) {
        guard var entry = activeDownloads[gid] else { return }
        guard entry.phase != phase else { return }
        entry.phase = phase
        var updated = activeDownloads
        updated[gid] = entry
        activeDownloads = updated
    }

    /// ギャラリーディレクトリ内の画像ファイル合計サイズをスキャンして初期化
    /// auto-resume 時や performDownload 開始時に呼ぶ
    func initializeBytesCounter(gid: Int) {
        let dir = galleryDirectory(gid: gid)
        guard let contents = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            downloadedBytes[gid] = 0
            initialOnDiskBytes[gid] = 0
            BackgroundDownloadManager.shared.resetCumulativeBytes(for: gid)
            return
        }
        var total: Int64 = 0
        for name in contents where name != "meta.json" && name != "cover.jpg" {
            let path = dir.appendingPathComponent(name).path
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        downloadedBytes[gid] = total
        initialOnDiskBytes[gid] = total
        BackgroundDownloadManager.shared.resetCumulativeBytes(for: gid)
    }

    /// リアルタイム表示用: 現在までに DL 済みのバイト総量
    /// = 開始時点の on-disk 量 + 今セッション中に受信したバイト累計
    func liveDownloadedBytes(gid: Int) -> Int64 {
        let initial = initialOnDiskBytes[gid, default: 0]
        let received = BackgroundDownloadManager.shared.totalBytesReceivedThisSession(for: gid)
        return initial + received
    }

    /// 推定総容量: 完了ページの平均サイズ × 総ページ数
    func estimatedTotalBytes(gid: Int, totalPages: Int, currentPages: Int) -> Int64? {
        guard currentPages > 0 else { return nil }
        let soFar = downloadedBytes[gid, default: 0]
        guard soFar > 0 else { return nil }
        let avg = soFar / Int64(currentPages)
        return avg * Int64(totalPages)
    }

    /// ページ1枚DL完了時にバイト数加算
    func addDownloadedBytes(gid: Int, page: Int) {
        let path = imageFilePath(gid: gid, page: page)
        if let attrs = try? fileManager.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int64 {
            downloadedBytes[gid, default: 0] += size
        }
    }

    /// 残り容量推定（DL 済み平均サイズ × 残りページ数）
    func estimatedRemainingBytes(gid: Int, totalPages: Int, currentPages: Int) -> Int64? {
        guard currentPages > 0, currentPages < totalPages else { return nil }
        let soFar = downloadedBytes[gid, default: 0]
        guard soFar > 0 else { return nil }
        let avg = soFar / Int64(currentPages)
        let remaining = Int64(totalPages - currentPages)
        return avg * remaining
    }

    // MARK: - ダウンロード実行

    private func performDownload(
        gid: Int, token: String, title: String,
        coverURL: URL?, pageCount: Int,
        galleryURLStr: String, host: GalleryHost
    ) async {
        LogManager.shared.log("Download", "performDownload START: gid=\(gid) pageCount=\(pageCount) url=\(galleryURLStr)")

        // 残り容量推定用にバイト累計を初期化（既存ファイル込み）
        initializeBytesCounter(gid: gid)

        // バックグラウンドタスクでアプリがバックグラウンドでも継続
        #if canImport(UIKit)
        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "Download-\(gid)") {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
        defer {
            if bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(bgTaskID)
            }
        }
        #endif

        let dir = galleryDirectory(gid: gid)
        ensureDirectory(dir)

        var meta = downloads[gid] ?? DownloadedGallery(
            gid: gid, token: token, title: title,
            coverFileName: "cover.jpg", pageCount: pageCount,
            downloadDate: Date(), isComplete: false, downloadedPages: []
        )

        // カバー画像
        if let coverURL {
            let coverPath = coverFilePath(gid: gid)
            if !fileManager.fileExists(atPath: coverPath.path) {
                do {
                    let data = try await client.fetchImageData(url: coverURL, host: host)
                    try data.write(to: coverPath)
                } catch {
                    LogManager.shared.log("Download", "cover failed: \(error)")
                }
            }
        }

        // 画像ページURL一覧を取得（1件ずつ直列化でネットワーク飽和防止）
        var allPageURLs: [URL] = []
        var page = 0

        // tokenが空の場合はURLが不正なのでスキップ
        guard !token.isEmpty, !galleryURLStr.contains("//") || galleryURLStr.contains("/g/") else {
            LogManager.shared.log("Download", "ERROR: invalid galleryURL=\(galleryURLStr) token=\(token)")
            activeDownloads.removeValue(forKey: gid)
            return
        }

        await urlResolveSemaphore.wait()
        // URL 解決完了したら即 release する。performDownload 全体を保持すると
        // 2ndpass (低速 mirror 再試行中) で他 gallery の URL 解決がブロックされる。
        // 以降 (batch enqueue / stream 待機 / 2ndpass) は semaphore 不要で並行可。
        var urlResolveReleased = false
        defer { if !urlResolveReleased { urlResolveSemaphore.signal() } }

        while true {
            do {
                let urlString = page > 0 ? galleryURLStr + "?p=\(page)" : galleryURLStr
                LogManager.shared.log("Download", "fetching page URLs: \(urlString)")
                let html = try await client.fetchHTML(urlString: urlString, host: host)
                let urls = HTMLParser.parseImagePageURLs(html: html)
                LogManager.shared.log("Download", "  got \(urls.count) URLs from page \(page), total so far: \(allPageURLs.count + urls.count)")

                if urls.isEmpty {
                    LogManager.shared.log("Download", "  empty response, stopping")
                    break
                }

                allPageURLs.append(contentsOf: urls)
                page += 1

                if pageCount > 0 && allPageURLs.count >= pageCount {
                    LogManager.shared.log("Download", "  reached expected pageCount=\(pageCount), stopping")
                    break
                }
                if page > 200 {
                    LogManager.shared.log("Download", "  safety limit reached")
                    break
                }

                await ExtremeMode.shared.delay(nanoseconds: requestDelay)
            } catch {
                LogManager.shared.log("Download", "page URL fetch failed: \(error)")
                break
            }
        }

        LogManager.shared.log("Download", "gid=\(gid) fetched \(allPageURLs.count) page URLs (expected: \(pageCount))")

        // 【フォールバック】exhentai で 0件 = 未ログイン可能性。e-hentai (public) で再試行
        // user の cookie が URLSession に共有されてない/未ログインでも public gallery なら
        // e-hentai 側で DL できる。まず exhentai → 失敗 → e-hentai の順で試す
        var usedHost = host
        if allPageURLs.isEmpty && host == .exhentai {
            let fallbackURL = galleryURLStr.replacingOccurrences(of: "exhentai.org", with: "e-hentai.org")
            LogManager.shared.log("Download", "gid=\(gid) exhentai empty → fallback e-hentai: \(fallbackURL)")
            var page = 0
            while true {
                do {
                    let urlString = page > 0 ? fallbackURL + "?p=\(page)" : fallbackURL
                    let html = try await client.fetchHTML(urlString: urlString, host: .ehentai)
                    let urls = HTMLParser.parseImagePageURLs(html: html)
                    LogManager.shared.log("Download", "  fallback page \(page): \(urls.count) URLs (total \(allPageURLs.count + urls.count))")
                    if urls.isEmpty { break }
                    allPageURLs.append(contentsOf: urls)
                    page += 1
                    if pageCount > 0 && allPageURLs.count >= pageCount { break }
                    if page > 200 { break }
                    await ExtremeMode.shared.delay(nanoseconds: requestDelay)
                } catch {
                    LogManager.shared.log("Download", "fallback page URL fetch failed: \(error)")
                    break
                }
            }
            if !allPageURLs.isEmpty {
                usedHost = .ehentai
                LogManager.shared.log("Download", "gid=\(gid) fallback SUCCESS: \(allPageURLs.count) URLs via e-hentai")
            }
        }

        // URL取得0件 = notLoggedIn/banned/ネットワーク不通 等の致命的エラー
        // 画像/メタを絶対に削除しない: meta.downloadedPages は実ファイルに lag する
        // ことがあり「meta=0 だから trash」は安全でない。真のゴミは cleanupTrashDownloads
        // が init 時に pageCount=0 / token空 で別途判定する。
        if allPageURLs.isEmpty {
            LogManager.shared.log("Download", "gid=\(gid) ABORT: zero URLs fetched - stopping task (data preserved for retry)")
            await MainActor.run {
                self.activeDownloads.removeValue(forKey: gid)
                self.endLiveActivity(gid: gid, success: false)
            }
            return
        }

        // URL 解決完了、他 gallery の URL 解決をブロックしないため semaphore 解放
        urlResolveSemaphore.signal()
        urlResolveReleased = true

        let totalPages = allPageURLs.count
        meta.pageCount = totalPages
        saveMetadata(meta)

        // 双方向DL用共有状態を初期化
        let state = BiDirectionalState()
        state.allPageURLs = allPageURLs
        state.totalPages = totalPages
        state.downloadedSet = Set(meta.downloadedPages)
        biDirStates[gid] = state

        // 既存ページ数を反映
        updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)

        // エクストリームモードなら後方DLを同時起動（ECOモード時は無効）
        if ExtremeMode.shared.isEnabled && !EcoMode.shared.isEnabled {
            state.backwardRunning = true
            state.backwardCancelled = false
            LogManager.shared.log("Download", "gid=\(gid) EXTREME: starting backward download")
            Task(priority: .high) {
                await self.performBackwardDownload(gid: gid, host: host)
            }
        }

        // URL 取得完了、実 DL フェーズに遷移 (UI で「準備中」→ 通常 DL 表示)
        updatePhase(gid: gid, phase: .active)

        // Batch enqueue方式: URL解決は並列5で、解決次第BG sessionに投入
        // → 一度enqueueされたDLはアプリsuspend中もiOSが継続
        let stream = BackgroundDownloadManager.shared.makeStream(for: gid)
        let session = BackgroundDownloadManager.shared.ehSession
        let ehHeaders: [String: String] = [
            "Referer": host == .exhentai ? "https://exhentai.org/" : "https://e-hentai.org/",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        ]

        // 既存ファイルをマーク
        var pendingIndices: [Int] = []
        for index in 0..<totalPages {
            if state.downloadedSet.contains(index) { continue }
            let filePath = imageFilePath(gid: gid, page: index)
            if fileManager.fileExists(atPath: filePath.path) {
                state.downloadedSet.insert(index)
                continue
            }
            pendingIndices.append(index)
        }
        updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
        LogManager.shared.log("Download", "gid=\(gid) EH batch enqueue: pending=\(pendingIndices.count)")

        // URL解決 → enqueue を並列5で実行（解決の遅延を隠蔽）
        let urlResolveSem = AsyncSemaphore(limit: 5)
        let weakSelf = self
        let resolveClient = self.client
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for index in pendingIndices {
                    if weakSelf.activeDownloads[gid]?.isCancelled == true { break }
                    let pageURL = allPageURLs[index]
                    let filePath = weakSelf.imageFilePath(gid: gid, page: index)
                    group.addTask {
                        await urlResolveSem.wait()
                        defer { urlResolveSem.signal() }
                        do {
                            let imageURL = try await resolveClient.fetchImageURL(pageURL: pageURL)
                            BackgroundDownloadManager.shared.enqueue(
                                url: imageURL, gid: gid, pageIndex: index, finalPath: filePath,
                                session: session, headers: ehHeaders
                            )
                            // 末尾 5 ページは stuck 検知用にログ
                            if index >= totalPages - 5 {
                                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) enqueue OK url=\(imageURL.absoluteString.suffix(80))")
                            }
                        } catch {
                            LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) URL解決失敗: \(error.localizedDescription)")
                            // 失敗もstream経由で通知（mirror再試行はsecondpassで）
                            BackgroundDownloadManager.shared.enqueue(
                                url: pageURL,  // ダミー（HTMLを画像扱いで失敗する）
                                gid: gid, pageIndex: index, finalPath: filePath,
                                session: session, headers: ehHeaders
                            )
                        }
                    }
                }
            }
        }

        // 完了stream消費（stall watchdog付き: 20秒completion無ければsecondpassにフォールバック）
        // 元は45s だったが「突っかかり時間」を短縮してユーザー体感を改善
        var pendingCount = pendingIndices.count
        let stallThreshold: Double = 20.0
        let lastProgressBox = StallBox()
        lastProgressBox.update()

        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5秒毎チェック (元 10秒)
                if Task.isCancelled { break }
                let elapsed = CFAbsoluteTimeGetCurrent() - lastProgressBox.value
                if elapsed > stallThreshold {
                    LogManager.shared.log("Download", "gid=\(gid) BG stream stall \(Int(elapsed))s - forcing finish (threshold=\(Int(stallThreshold))s)")
                    BackgroundDownloadManager.shared.finishStream(for: gid)
                    break
                }
            }
        }

        for await completion in stream {
            lastProgressBox.update()
            if activeDownloads[gid]?.isCancelled == true {
                BackgroundDownloadManager.shared.cancelAllTasks(for: gid, session: session)
                break
            }

            let index = completion.pageIndex
            if completion.success {
                state.downloadedSet.insert(index)
                addDownloadedBytes(gid: gid, page: index)
                updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
            } else {
                state.failedPages.append((index: index, pageURL: allPageURLs[index]))
                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) 1stpass FAIL (retriable=\(completion.retriable))")
            }
            pendingCount -= 1
            // 残り5枚以下になったら詳細ログ（stuck 検知用）
            if pendingCount > 0 && pendingCount <= 5 {
                let missing = pendingIndices.filter { idx in
                    !state.downloadedSet.contains(idx) &&
                    !state.failedPages.contains(where: { $0.index == idx })
                }
                LogManager.shared.log("Download", "gid=\(gid) pending=\(pendingCount) stillMissing=\(missing.map { $0 + 1 })")
            }
            if pendingCount <= 0 { break }
        }
        watchdog.cancel()
        // stall で残ったURLSessionタスクを明示的 cancel（ghost completion 防止）
        BackgroundDownloadManager.shared.cancelAllTasks(for: gid, session: session)
        LogManager.shared.log("Download", "gid=\(gid) 1stpass exit: done=\(state.downloadedSet.count)/\(totalPages) failedPages=\(state.failedPages.map { $0.index + 1 })")

        // stall で強制finishした場合、未完了のpendingIndicesをfailedとしてsecondpassに回す
        for idx in pendingIndices where !state.downloadedSet.contains(idx) {
            if !state.failedPages.contains(where: { $0.index == idx }) {
                state.failedPages.append((index: idx, pageURL: allPageURLs[idx]))
            }
        }

        // セカンドパス: 失敗ページを再試行
        let allFailed = state.failedPages.filter { !state.downloadedSet.contains($0.index) }
        if !allFailed.isEmpty {
            let failedPageNums = allFailed.map { $0.index + 1 }
            LogManager.shared.log("Download", "gid=\(gid) 2ndpass START retry=\(failedPageNums) (5s wait)")
            // UI: 「別ミラーから再試行中」に切替 (info マーク表示用)
            updatePhase(gid: gid, phase: .retrying)
            await ExtremeMode.shared.delay(nanoseconds: 5_000_000_000)

            for (index, pageURL) in allFailed {
                if activeDownloads[gid]?.isCancelled == true { break }
                if state.downloadedSet.contains(index) { continue }

                let filePath = imageFilePath(gid: gid, page: index)
                LogManager.shared.log("Download", "gid=\(gid) 2ndpass page \(index + 1) start url=\(pageURL.absoluteString.suffix(60))")
                // 2ndpass は 1stpass で死んだ mirror が判明済み → 最初から別 mirror 要求
                // attempt 1 の 120秒 timeout × 全ページ分を回避（32ページ × 2分 = 64分削減）
                let success = await downloadSinglePage(
                    gid: gid, index: index, pageURL: pageURL,
                    filePath: filePath, host: host, maxRetries: 3,
                    forceMirror: true
                )
                if success {
                    state.downloadedSet.insert(index)
                    addDownloadedBytes(gid: gid, page: index)
                    updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
                    LogManager.shared.log("Download", "gid=\(gid) 2ndpass page \(index + 1) OK")
                } else {
                    LogManager.shared.log("Download", "gid=\(gid) page \(index + 1)/\(totalPages) PERMANENTLY FAILED")
                }
                await ExtremeMode.shared.delay(nanoseconds: requestDelay)
            }
            LogManager.shared.log("Download", "gid=\(gid) 2ndpass END: done=\(state.downloadedSet.count)/\(totalPages)")
        }

        // 完了処理: @Published dict は subscript mutation だとSwiftUI更新が不確実
        // → MainActor + 再代入パターンで確実に通知発火させる
        meta.downloadedPages = Array(state.downloadedSet)
        meta.isComplete = totalPages > 0 && state.downloadedSet.count >= totalPages
        meta.downloadDate = Date()
        let finalMeta = meta
        let completed = meta.isComplete
        await MainActor.run {
            saveMetadata(finalMeta)
            // 再代入で @Published 通知を確実発火
            var updatedActive = activeDownloads
            updatedActive.removeValue(forKey: gid)
            activeDownloads = updatedActive
            biDirStates.removeValue(forKey: gid)
            endLiveActivity(gid: gid, success: completed)
        }
        LogManager.shared.log("Download", "gid=\(gid) finished: \(state.downloadedSet.count)/\(totalPages) isComplete=\(completed)")

        if completed {
            #if canImport(UIKit)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            #endif
            sendDownloadCompleteNotification(title: title)
        }
    }

    // MARK: - 後方ダウンロード（エクストリームモード専用）

    /// 末尾から前方に向かってダウンロード
    private func performBackwardDownload(gid: Int, host: GalleryHost) async {
        guard let state = biDirStates[gid] else { return }
        let totalPages = state.totalPages

        LogManager.shared.log("Download", "gid=\(gid) backward START from page \(totalPages)")

        for index in stride(from: totalPages - 1, through: 0, by: -1) {
            // 停止チェック
            if state.backwardCancelled || activeDownloads[gid]?.isCancelled == true {
                LogManager.shared.log("Download", "gid=\(gid) backward STOPPED at page \(index + 1)")
                break
            }

            // 前方DLまたは既存ファイルでDL済みならスキップ（更新なし）
            if state.downloadedSet.contains(index) { continue }
            let filePath = imageFilePath(gid: gid, page: index)
            if fileManager.fileExists(atPath: filePath.path) {
                state.downloadedSet.insert(index)
                continue
            }

            let pageURL = state.allPageURLs[index]
            let success = await downloadSinglePage(
                gid: gid, index: index, pageURL: pageURL,
                filePath: filePath, host: host, maxRetries: 3
            )
            if success {
                state.downloadedSet.insert(index)
                addDownloadedBytes(gid: gid, page: index)
                updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
            } else {
                state.failedPages.append((index: index, pageURL: pageURL))
            }

            // エクストリームモードではディレイなし（delay内部でスキップ）
            await ExtremeMode.shared.delay(nanoseconds: requestDelay)

            // 全ページ完了チェック
            if state.downloadedSet.count >= totalPages { break }
        }

        state.backwardRunning = false
        LogManager.shared.log("Download", "gid=\(gid) backward END (downloaded=\(state.downloadedSet.count)/\(totalPages))")
    }

    // MARK: - 単一ページダウンロード（リトライ付き）

    /// 1ページをダウンロード。最大maxRetries回リトライ。成功でtrue。
    /// - forceMirror: true なら attempt 1 から `?nl=` mirror request を使う
    ///   (1stpass で既に死んだ mirror が判明してる 2ndpass 用。毎回 2分 timeout を回避)
    private func downloadSinglePage(
        gid: Int, index: Int, pageURL: URL,
        filePath: URL, host: GalleryHost, maxRetries: Int,
        forceMirror: Bool = false
    ) async -> Bool {
        var usedMirror = forceMirror

        for attempt in 1...maxRetries {
            do {
                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) attempt \(attempt): resolving URL")
                // SSLエラーで失敗済みなら別ミラーを試す
                let imageURL: URL
                if usedMirror || attempt > 1 {
                    imageURL = try await client.fetchImageURLWithMirror(pageURL: pageURL)
                    usedMirror = true
                } else {
                    imageURL = try await client.fetchImageURL(pageURL: pageURL)
                }
                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) attempt \(attempt): resolved → \(imageURL.absoluteString.suffix(80))")

                await ExtremeMode.shared.delay(nanoseconds: requestDelay)

                // Background URLSession経由（アプリsuspend中もDL継続）
                let headers: [String: String] = [
                    "Referer": host == .exhentai ? "https://exhentai.org/" : "https://e-hentai.org/",
                    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
                ]
                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) attempt \(attempt): downloadTask start")
                let ok = await BackgroundDownloadManager.shared.downloadToFile(
                    url: imageURL,
                    session: BackgroundDownloadManager.shared.ehSession,
                    finalPath: filePath,
                    headers: headers
                )
                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) attempt \(attempt): downloadTask done ok=\(ok)")
                guard ok, BackgroundDownloadManager.isValidImageFile(at: filePath) else {
                    try? FileManager.default.removeItem(at: filePath)
                    LogManager.shared.log("Download", "gid=\(gid) page \(index + 1): invalid/empty (attempt \(attempt)/\(maxRetries))")
                    if attempt < maxRetries {
                        await ExtremeMode.shared.delay(nanoseconds: 3_000_000_000)
                    }
                    continue
                }
                return true

            } catch let error as NSError where error.code == -1200 {
                // SSLエラー → 次回ミラーを試す
                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1): SSL error, will try mirror (attempt \(attempt)/\(maxRetries))")
                usedMirror = true
                if attempt < maxRetries {
                    let backoff = UInt64(attempt) * 3_000_000_000
                    await ExtremeMode.shared.delay(nanoseconds: backoff)
                }
            } catch {
                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1): \(error) (attempt \(attempt)/\(maxRetries))")
                if attempt < maxRetries {
                    let backoff = UInt64(attempt) * 3_000_000_000
                    await ExtremeMode.shared.delay(nanoseconds: backoff)
                }
            }
        }
        return false
    }

    /// stream stall検出用の時刻ボックス（Task間で共有）
    private final class StallBox: @unchecked Sendable {
        var value: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
        func update() { value = CFAbsoluteTimeGetCurrent() }
    }

    /// 完了通知
    private func sendDownloadCompleteNotification(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "ダウンロード完了"
        content.body = "\(title) の保存が完了しました"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
