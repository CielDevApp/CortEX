import Foundation
import Combine
import UserNotifications
import ActivityKit
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

    var id: Int { gid }
    nonisolated var directoryName: String { "\(gid)" }
    var isNhentai: Bool { source == "nhentai" || token.hasPrefix("nh") }
    /// nhentai用: 実際のnhentai IDを返す（gidは-nhIdで保存）
    var nhentaiId: Int? {
        guard isNhentai else { return nil }
        if gid < 0 { return -gid }
        return gid // 旧データ（正数gid）
    }
}

class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

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
        nonisolated var fraction: Double { total > 0 ? Double(current) / Double(total) : 0 }
    }

    private let client = EhClient.shared
    private let fileManager = FileManager.default
    private let requestDelay: UInt64 = 2_000_000_000
    /// URL解決フェーズの直列化（複数DLが同時にページURL取得→ネットワーク飽和防止）
    private let urlResolveSemaphore = AsyncSemaphore(limit: 1)

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
        // Live Activityクリーンアップ→ダウンロード再開を順序保証
        Task {
            await cleanupStaleLiveActivities()
            await resumeIncompleteDownloads()
        }
    }

    /// 前回の強制終了等で残った古いLive Activityを全て終了
    private func cleanupStaleLiveActivities() async {
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
    }

    /// 未完了ダウンロードを自動再開
    private func resumeIncompleteDownloads() async {
        let incompleteItems = downloads.filter { !$0.value.isComplete && !$0.value.token.isEmpty }
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

    func loadCoverImage(gid: Int) -> PlatformImage? {
        let path = coverFilePath(gid: gid)
        if fileManager.fileExists(atPath: path.path),
           let image = PlatformImage(contentsOfFile: path.path) {
            return image
        }
        // カバーが存在しない場合は1枚目をリサイズして代用 + cover.jpgに保存
        return generateCoverFromFirstPage(gid: gid)
    }

    /// 1枚目の画像をリサイズしてcover.jpgとして保存、結果を返す
    private func generateCoverFromFirstPage(gid: Int) -> PlatformImage? {
        // 1枚目(page 0)を探す。見つからなければ最初に存在するページを使う
        var sourceImage: PlatformImage?
        for page in 0..<5 {
            if let img = loadLocalImage(gid: gid, page: page) {
                sourceImage = img
                break
            }
        }
        guard let source = sourceImage else { return nil }

        #if canImport(UIKit)
        let maxEdge: CGFloat = 400
        let srcW = CGFloat(source.pixelWidth)
        let srcH = CGFloat(source.pixelHeight)
        let scale = min(maxEdge / max(srcW, srcH), 1.0)
        let newSize = CGSize(width: srcW * scale, height: srcH * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: newSize))
        }
        // cover.jpgに保存（次回以降高速化）
        if let data = resized.jpegData(compressionQuality: 0.85) {
            let path = coverFilePath(gid: gid)
            try? data.write(to: path)
            LogManager.shared.log("Download", "generated cover from page 0 for gid=\(gid)")
        }
        return resized
        #else
        return source
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

    func isDownloading(gid: Int) -> Bool {
        activeDownloads[gid] != nil
    }

    // MARK: - Live Activity

    private func startLiveActivity(gid: Int, title: String, totalPages: Int, initialPage: Int = 0) {
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
    }

    private func updateLiveActivity(gid: Int, current: Int, total: Int) {
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
    }

    private func endLiveActivity(gid: Int, success: Bool) {
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

        // メタデータを即座に保存
        if downloads[gid] == nil {
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

        if downloads[gid] == nil {
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

        // エクストリーム時は後方DL
        if ExtremeMode.shared.isEnabled && !EcoMode.shared.isEnabled {
            state.backwardRunning = true
            state.backwardCancelled = false
            Task(priority: .high) {
                await self.performNhBackward(gid: gid, nhGallery: nhGallery)
            }
        }

        // 前方DL
        for index in 0..<totalPages {
            if activeDownloads[gid]?.isCancelled == true {
                state.backwardCancelled = true
                activeDownloads.removeValue(forKey: gid)
                meta.downloadedPages = Array(state.downloadedSet)
                saveMetadata(meta)
                biDirStates.removeValue(forKey: gid)
                return
            }

            if state.downloadedSet.contains(index) { continue }
            let filePath = imageFilePath(gid: gid, page: index)
            if fileManager.fileExists(atPath: filePath.path) {
                state.downloadedSet.insert(index)
                continue
            }

            while NetworkMonitor.shared.shouldPauseDownload {
                if activeDownloads[gid]?.isCancelled == true { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            let nhPage = state.nhPages?[index]
            let success = await downloadNhPage(gid: gid, galleryId: state.nhGalleryId, index: index, mediaId: state.nhMediaId ?? "", pageNum: index + 1, ext: nhPage?.ext ?? "jpg", filePath: filePath, maxRetries: 3)
            if success {
                state.downloadedSet.insert(index)
                updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
            } else {
                state.failedPages.append((index: index, pageURL: allPageURLs[index]))
            }

            if state.downloadedSet.count >= totalPages { break }
        }

        // 後方DL待ち
        while state.backwardRunning {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // セカンドパス
        let allFailed = state.failedPages.filter { !state.downloadedSet.contains($0.index) }
        if !allFailed.isEmpty {
            LogManager.shared.log("Download", "nhentai retrying \(allFailed.count) failed pages")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            for (index, url) in allFailed {
                if activeDownloads[gid]?.isCancelled == true { break }
                if state.downloadedSet.contains(index) { continue }
                let filePath = imageFilePath(gid: gid, page: index)
                let nhPage2 = state.nhPages?[index]
                let success = await downloadNhPage(gid: gid, galleryId: state.nhGalleryId, index: index, mediaId: state.nhMediaId ?? "", pageNum: index + 1, ext: nhPage2?.ext ?? "jpg", filePath: filePath, maxRetries: 3)
                if success {
                    state.downloadedSet.insert(index)
                    updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
                }
                // セカンドパスも即座にリトライ
            }
        }

        meta.downloadedPages = Array(state.downloadedSet)
        meta.isComplete = totalPages > 0 && state.downloadedSet.count >= totalPages
        meta.downloadDate = Date()
        saveMetadata(meta)
        activeDownloads.removeValue(forKey: gid)
        biDirStates.removeValue(forKey: gid)
        endLiveActivity(gid: gid, success: meta.isComplete)
        LogManager.shared.log("Download", "nhentai finished: \(state.downloadedSet.count)/\(totalPages) isComplete=\(meta.isComplete)")

        if meta.isComplete {
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            sendDownloadCompleteNotification(title: meta.title)
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
        for attempt in 1...maxRetries {
            do {
                let data = try await NhentaiClient.fetchPageImage(galleryId: galleryId, mediaId: mediaId, page: pageNum, ext: ext)
                try data.write(to: filePath)
                return true
            } catch {
                LogManager.shared.log("Download", "nhentai page \(index + 1): \(error.localizedDescription) (attempt \(attempt)/\(maxRetries))")
                if attempt < maxRetries { try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000) }
            }
        }
        return false
    }

    func cancelDownload(gid: Int) {
        activeDownloads[gid]?.isCancelled = true
    }

    /// 未完了ダウンロードをすべて手動再開
    func resumeAllIncomplete() {
        let incomplete = downloads.filter { !$0.value.isComplete && !$0.value.token.isEmpty && activeDownloads[$0.key] == nil }
        LogManager.shared.log("Download", "resumeAllIncomplete: \(incomplete.count) items")
        for (gid, meta) in incomplete {
            let gallery = Gallery(
                gid: gid, token: meta.token,
                title: meta.title, category: nil, coverURL: nil,
                rating: 0, pageCount: meta.pageCount,
                postedDate: "", uploader: nil, tags: []
            )
            startDownload(gallery: gallery, host: .exhentai)
        }
    }

    func deleteDownload(gid: Int) {
        let dir = galleryDirectory(gid: gid)
        try? fileManager.removeItem(at: dir)
        downloads.removeValue(forKey: gid)
        activeDownloads.removeValue(forKey: gid)
    }

    /// @Published辞書のin-place mutationはSwiftUIに通知されないため、辞書を再代入して通知する
    private func updateProgress(gid: Int, current: Int, total: Int) {
        var updated = activeDownloads
        updated[gid] = DownloadProgress(current: current, total: total)
        activeDownloads = updated
        updateLiveActivity(gid: gid, current: current, total: total)
    }

    // MARK: - ダウンロード実行

    private func performDownload(
        gid: Int, token: String, title: String,
        coverURL: URL?, pageCount: Int,
        galleryURLStr: String, host: GalleryHost
    ) async {
        LogManager.shared.log("Download", "performDownload START: gid=\(gid) pageCount=\(pageCount) url=\(galleryURLStr)")

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
        defer { urlResolveSemaphore.signal() }

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

        // 前方ダウンロード（0→末尾）
        for index in 0..<totalPages {
            if activeDownloads[gid]?.isCancelled == true {
                LogManager.shared.log("Download", "cancelled: gid=\(gid)")
                state.backwardCancelled = true
                activeDownloads.removeValue(forKey: gid)
                meta.downloadedPages = Array(state.downloadedSet)
                saveMetadata(meta)
                biDirStates.removeValue(forKey: gid)
                return
            }

            // 後方DLまたは既存ファイルでDL済みならスキップ（更新なし）
            if state.downloadedSet.contains(index) { continue }
            let filePath = imageFilePath(gid: gid, page: index)
            if fileManager.fileExists(atPath: filePath.path) {
                state.downloadedSet.insert(index)
                continue
            }

            // ネットワーク断時は復帰まで待機
            while NetworkMonitor.shared.shouldPauseDownload {
                if activeDownloads[gid]?.isCancelled == true { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            let pageURL = allPageURLs[index]
            let success = await downloadSinglePage(
                gid: gid, index: index, pageURL: pageURL,
                filePath: filePath, host: host, maxRetries: 3
            )
            if success {
                state.downloadedSet.insert(index)
                updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
            } else {
                state.failedPages.append((index: index, pageURL: pageURL))
            }

            await ExtremeMode.shared.delay(nanoseconds: requestDelay)

            // エクストリームモード途中ON → 後方DL起動
            if ExtremeMode.shared.isEnabled && !EcoMode.shared.isEnabled && !state.backwardRunning {
                state.backwardRunning = true
                state.backwardCancelled = false
                LogManager.shared.log("Download", "gid=\(gid) EXTREME ON mid-download: starting backward")
                Task(priority: .high) {
                    await self.performBackwardDownload(gid: gid, host: host)
                }
            }
            // エクストリームモード途中OFF → 後方DLを停止
            if !ExtremeMode.shared.isEnabled && state.backwardRunning {
                LogManager.shared.log("Download", "gid=\(gid) EXTREME OFF: stopping backward")
                state.backwardCancelled = true
            }

            // 全ページ完了チェック（後方DLとの合流）
            if state.downloadedSet.count >= totalPages { break }
        }

        // 後方DLの完了を待つ
        while state.backwardRunning {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // セカンドパス: 失敗ページを再試行
        let allFailed = state.failedPages.filter { !state.downloadedSet.contains($0.index) }
        if !allFailed.isEmpty {
            LogManager.shared.log("Download", "gid=\(gid) retrying \(allFailed.count) failed pages (2nd pass)")
            await ExtremeMode.shared.delay(nanoseconds: 5_000_000_000)

            for (index, pageURL) in allFailed {
                if activeDownloads[gid]?.isCancelled == true { break }
                if state.downloadedSet.contains(index) { continue }

                let filePath = imageFilePath(gid: gid, page: index)
                let success = await downloadSinglePage(
                    gid: gid, index: index, pageURL: pageURL,
                    filePath: filePath, host: host, maxRetries: 3
                )
                if success {
                    state.downloadedSet.insert(index)
                    updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
                } else {
                    LogManager.shared.log("Download", "gid=\(gid) page \(index + 1)/\(totalPages) PERMANENTLY FAILED")
                }
                await ExtremeMode.shared.delay(nanoseconds: requestDelay)
            }
        }

        // 完了処理
        meta.downloadedPages = Array(state.downloadedSet)
        meta.isComplete = totalPages > 0 && state.downloadedSet.count >= totalPages
        meta.downloadDate = Date()
        saveMetadata(meta)
        activeDownloads.removeValue(forKey: gid)
        biDirStates.removeValue(forKey: gid)
        endLiveActivity(gid: gid, success: meta.isComplete)
        LogManager.shared.log("Download", "gid=\(gid) finished: \(state.downloadedSet.count)/\(totalPages) isComplete=\(meta.isComplete)")

        if meta.isComplete {
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
    private func downloadSinglePage(
        gid: Int, index: Int, pageURL: URL,
        filePath: URL, host: GalleryHost, maxRetries: Int
    ) async -> Bool {
        var usedMirror = false

        for attempt in 1...maxRetries {
            do {
                // SSLエラーで失敗済みなら別ミラーを試す
                let imageURL: URL
                if usedMirror || attempt > 1 {
                    imageURL = try await client.fetchImageURLWithMirror(pageURL: pageURL)
                    usedMirror = true
                } else {
                    imageURL = try await client.fetchImageURL(pageURL: pageURL)
                }

                await ExtremeMode.shared.delay(nanoseconds: requestDelay)
                let imageData = try await client.fetchImageData(url: imageURL, host: host)

                guard !imageData.isEmpty else {
                    LogManager.shared.log("Download", "gid=\(gid) page \(index + 1): empty data (attempt \(attempt)/\(maxRetries))")
                    if attempt < maxRetries {
                        await ExtremeMode.shared.delay(nanoseconds: 3_000_000_000)
                    }
                    continue
                }

                try imageData.write(to: filePath)
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
