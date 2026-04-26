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

/// リーダー表示方向。静止画ギャラリーは全体設定 readerDirection に従うが、
/// 動画 WebP 含みで横開き不可のギャラリーのみ per-gallery の override を保持する。
enum GalleryReaderMode: String, Codable, Sendable {
    case horizontal
    case vertical
}

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
    /// VP8X ANIM flag 走査結果。nil = 未走査（初回 Reader 起動時に migration で埋める）
    var hasAnimatedWebp: Bool? = nil
    /// ダイアログで選択された per-gallery モード上書き。nil = 未選択
    var readerModeOverride: GalleryReaderMode? = nil
    /// E-Hentai タグ (DL 開始時の Gallery.tags をスナップ)。nil = 旧 DL データで未保存。
    /// "other:animated" 等を含めば動画作品として確定判定 (実バイト scan 不要 = 二重判定排除)。
    var tags: [String]? = nil

    var id: Int { gid }
    nonisolated var directoryName: String { "\(gid)" }
    var isNhentai: Bool { source == "nhentai" || token.hasPrefix("nh") }
    /// 動画作品判定: 優先順 (1) 実 scan 結果 → (2) タグ → (3) タイトル絵文字 heuristic。
    /// scan 完了済なら絵文字/タグ無関係に確定判定。タグがあれば即マーク表示で
    /// onAppear scan 起動も不要 (田中指示 2026-04-25 二重判定排除)。
    var isAnimatedGallery: Bool {
        if hasAnimatedWebp == true { return true }
        if hasAnimatedWebp == false { return false }
        // 未 scan (nil): タグ判定 → タイトル heuristic
        if hasAnimatedTag { return true }
        let t = title
        return t.contains("Animated") || t.contains("GIF") || t.contains("gif") || t.contains("🎥")
    }
    /// タグに "animated" を含むか (E-Hentai の "other:animated" 等を拾う)。case insensitive。
    var hasAnimatedTag: Bool {
        guard let tags else { return false }
        return tags.contains { $0.lowercased().contains("animated") }
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
    /// deleteDownload 後に autoSavePage の in-flight Task が metadata を復活させる
    /// ゾンビ問題対策。リーダー再オープン or startDownload 時にクリア。
    private var recentlyDeletedGids: Set<Int> = []

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
        /// cooling phase のとき、cooldown 終了予定時刻 (UI カウントダウン用)
        var coolingUntil: Date? = nil
        nonisolated var fraction: Double { total > 0 ? Double(current) / Double(total) : 0 }

        /// DL フェーズ: UI 側で「準備中」「通常DL」「リトライ中」「cooldown」を区別するため
        enum Phase: Sendable {
            case preparing   // URL 取得中など、progress 0/0 で見える期間
            case cooling     // URL 解決中の BAN 予防 cooldown (safetyMode ON 時 50 画面毎に 60s)
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

    /// Foreground 復帰時の「爆速復帰」実装
    /// 田中要望:「URL解決をし直す、DL 済みはスキップ」= アプリ再起動時と同じ挙動。
    /// ただし URL 解決中 (preparing phase) は cancel しない: 頭から再解決の後退を避ける。
    /// - active (batch DL 中): cancel → resumeIncompleteDownloads で爆速 batch 再起動
    /// - preparing (URL 解決中) / cooling / retrying (2ndpass): reconcile のみ、継続させる
    func resumeActiveDownloadsOnForeground() {
        let activeGids = activeDownloads.keys.filter { gid in
            activeDownloads[gid]?.isCancelled != true
        }
        guard !activeGids.isEmpty else { return }
        var gidsToRestart: [Int] = []
        for gid in activeGids {
            // disk scan → meta.downloadedPages 更新 (全 phase 共通)
            reconcileGallery(gid: gid)
            let phase = activeDownloads[gid]?.phase ?? .preparing
            if phase == .active {
                gidsToRestart.append(gid)
            }
        }
        guard !gidsToRestart.isEmpty else {
            LogManager.shared.log("Download", "foreground resume: reconcile only, \(activeGids.count) DLs not in active phase (continue as-is)")
            return
        }
        LogManager.shared.log("Download", "foreground resume: restart \(gidsToRestart.count) DLs in active phase (URL resolve 再実行, disk skip)")
        let bg = BackgroundDownloadManager.shared
        for gid in gidsToRestart {
            activeDownloads[gid]?.isCancelled = true
            bg.cancelAllTasks(for: gid, session: bg.nhSession)
            bg.cancelAllTasks(for: gid, session: bg.ehSession)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self = self else { return }
            for gid in gidsToRestart {
                self.activeDownloads.removeValue(forKey: gid)
            }
            await self.resumeIncompleteDownloads()
        }
    }

    /// Phase 2B: onGidProgressHint 用の per-gid trailing debounce timer
    /// consumer suspend 中の BG wakeup 毎にヒントが来るが、disk scan は高コストなので
    /// per-gid 1s trailing で coalesce → LA 更新頻度も ActivityKit rate limit 内に収める
    private var bgHintDebounce: [Int: DispatchSourceTimer] = [:]
    private let bgHintLock = NSLock()

    private init() {
        // BackgroundDownloadManager の復帰 hook を設定 (案 4)
        BackgroundDownloadManager.shared.onForegroundResume = { [weak self] in
            Task { @MainActor in
                self?.resumeActiveDownloadsOnForeground()
            }
        }
        // Phase 2B: BG delegate 完了毎のヒントを受けて disk scan → LA/progress 更新
        BackgroundDownloadManager.shared.onGidProgressHint = { [weak self] gid in
            self?.scheduleBGProgressHintFire(gid: gid)
        }
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

        // 起動時 reconcile: BG session DROPPED completion 救済
        // meta 上は未完でも実ディスクにファイルがあるケースを downloadedPages に反映
        for (gid, _) in incompleteItems {
            reconcileGallery(gid: gid)
        }

        // reconcile 後に meta を取り直す (reconcileGallery が downloads を更新してる)
        let refreshedItems = downloads.filter {
            !$0.value.isComplete && !$0.value.token.isEmpty && $0.value.isCancelled != true
        }
        for (gid, meta) in refreshedItems {
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
                    await SafetyMode.shared.delay(nanoseconds: 3_000_000_000)
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
                    await SafetyMode.shared.delay(nanoseconds: 3_000_000_000)
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
        // Phase E1.B (2026-04-26): 外部参照 ZIP gallery 経路を最優先で check。
        // ExternalCortexZipReader が登録 gid なら ZIP entry を SSD cache に materialize
        // して URL を返す (cache hit なら即返却、miss なら SMB IO + 展開 → cache 書込)。
        if let extURL = ExternalCortexZipReader.shared.materializedImageURL(gid: gid, page: page) {
            return extURL
        }
        return galleryDirectory(gid: gid).appendingPathComponent("page_\(String(format: "%04d", page)).jpg")
    }

    func coverFilePath(gid: Int) -> URL {
        if let extURL = ExternalCortexZipReader.shared.materializedCoverURL(gid: gid) {
            return extURL
        }
        return galleryDirectory(gid: gid).appendingPathComponent("cover.jpg")
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
        // 「このまま閉じる」で deleteDownload 直後、in-flight Task がゾンビ復活させる経路をブロック
        guard !recentlyDeletedGids.contains(gid) else { return }

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
                // Task.detached 中に deleteDownload が走ったら write したファイル含めて破棄
                guard !self.recentlyDeletedGids.contains(gid) else {
                    try? self.fileManager.removeItem(at: filePath)
                    if needsCover { try? self.fileManager.removeItem(at: coverPath) }
                    return
                }
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
        guard !recentlyDeletedGids.contains(gid) else { return }
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
        // 明示 DL 開始なので、以前の「このまま閉じる」ブロックを解除
        recentlyDeletedGids.remove(gallery.gid)

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
            var meta = DownloadedGallery(
                gid: gid, token: token, title: title,
                coverFileName: "cover.jpg", pageCount: pageCount,
                downloadDate: Date(), isComplete: false, downloadedPages: []
            )
            // タグを保存しておけば、未 scan 状態でも動画マークが即時表示される。
            // "other:animated" 等を含む作品は実バイト scan 不要 (二重判定排除)。
            meta.tags = gallery.tags
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
        if meta.isComplete {
            meta.hasAnimatedWebp = scanHasAnimatedWebp(gid: gid)
            LogManager.shared.log("Anim", "post-DL scan gid=\(gid) hasAnimatedWebp=\(meta.hasAnimatedWebp ?? false)")
        }
        let finalMeta = meta
        let completed = meta.isComplete
        await MainActor.run {
            // 途中で deleteDownload された場合、downloads から entry が消えている。
            // そのまま saveMetadata すると ensureDirectory + 再挿入で蘇生してしまう。
            let wasDeleted = downloads[gid] == nil
            if !wasDeleted {
                saveMetadata(finalMeta)
            }
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
        // enqueue 済み URLSessionTask も即キャンセル（両 session 横断）
        let bg = BackgroundDownloadManager.shared
        bg.cancelAllTasks(for: gid, session: bg.nhSession)
        bg.cancelAllTasks(for: gid, session: bg.ehSession)
    }

    /// 未完了ダウンロードをすべて手動再開（キャンセル済みも含めてリセット）
    /// nhentai と E-Hentai で再開経路が違うので分岐する
    /// 未完了 gallery の downloadedPages を実ディスクと照合。
    /// BG session で DROPPED completion が発生した結果「ファイルはあるが meta 上は未完」
    /// になったケースを救済する。page_NNNN.jpg が存在 + マジックバイト valid なら
    /// downloadedPages に追加、全部揃ったら isComplete=true に昇格。
    /// 呼び出し: resumeAllIncomplete の前、or 起動時 1 回。
    func reconcileGallery(gid: Int) {
        guard var meta = downloads[gid] else { return }
        var detected: Set<Int> = Set(meta.downloadedPages)
        let before = detected.count
        for page in 0..<meta.pageCount {
            if detected.contains(page) { continue }
            let path = imageFilePath(gid: gid, page: page)
            guard fileManager.fileExists(atPath: path.path) else { continue }
            if BackgroundDownloadManager.isValidImageFile(at: path) {
                detected.insert(page)
            }
        }
        let added = detected.count - before
        guard added > 0 else { return }
        meta.downloadedPages = Array(detected).sorted()
        meta.isComplete = meta.pageCount > 0 && detected.count >= meta.pageCount
        saveMetadata(meta)
        LogManager.shared.log("Download", "reconcileGallery gid=\(gid) +\(added) pages → \(detected.count)/\(meta.pageCount) isComplete=\(meta.isComplete)")
    }

    func resumeAllIncomplete() {
        // ゴミ（0/0 や token空）は先に掃除して対象から外す
        cleanupTrashDownloads()
        // resume 前に全未完 gallery を reconcile (BG session DROPPED completion 救済)
        let incompleteForReconcile = downloads.filter { !$0.value.isComplete }.map { $0.key }
        for gid in incompleteForReconcile {
            reconcileGallery(gid: gid)
        }
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
        // 注意: activeDownloads[gid] は削除しない。削除すると isCancelled チェックが
        // nil == true で false 扱いされ、URL 解決/stream/2ndpass がゾンビ化する。
        // performDownload 終端で self-cleanup される (activeDownloads.removeValue)。
        if activeDownloads[gid] != nil {
            activeDownloads[gid]?.isCancelled = true
        }
        // enqueue 済み URLSessionTask も即キャンセル（両 session 横断）
        let bg = BackgroundDownloadManager.shared
        bg.cancelAllTasks(for: gid, session: bg.nhSession)
        bg.cancelAllTasks(for: gid, session: bg.ehSession)
        // LiveActivity 終了（通知センター/Dynamic Islandから消す）
        endLiveActivity(gid: gid, success: false)
        // in-flight autoSavePage Task が saveMetadata で復活させないようブロック
        recentlyDeletedGids.insert(gid)
        let dir = galleryDirectory(gid: gid)
        try? fileManager.removeItem(at: dir)
        downloads.removeValue(forKey: gid)
        coverCache.removeObject(forKey: NSNumber(value: gid))
    }

    /// リーダー再オープン時等、autoSave を再有効化したい場面で呼ぶ
    func clearRecentlyDeleted(gid: Int) {
        recentlyDeletedGids.remove(gid)
    }

    /// @Published辞書のin-place mutationはSwiftUIに通知されないため、辞書を再代入して通知する
    /// スロットルは cover cache 導入で再レンダーが安くなったので撤去（リアルタイム表示）
    /// phase は既存値を保持、別途 updatePhase() で変更する
    private func updateProgress(gid: Int, current: Int, total: Int) {
        var updated = activeDownloads
        let prevPhase = updated[gid]?.phase ?? .preparing
        let prevCancelled = updated[gid]?.isCancelled ?? false
        let prevCoolingUntil = updated[gid]?.coolingUntil
        updated[gid] = DownloadProgress(current: current, total: total, isCancelled: prevCancelled, phase: prevPhase, coolingUntil: prevCoolingUntil)
        activeDownloads = updated
        updateLiveActivity(gid: gid, current: current, total: total)
    }

    /// Phase 2B: BG delegate 完了毎のヒント受信 → per-gid 1s trailing debounce
    /// 既に timer 起動中なら何もしない (trailing edge で最新 disk 状態が反映される)
    private nonisolated func scheduleBGProgressHintFire(gid: Int) {
        bgHintLock.lock()
        if bgHintDebounce[gid] != nil {
            bgHintLock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.fireBGProgressHint(gid: gid)
            }
        }
        bgHintDebounce[gid] = timer
        bgHintLock.unlock()
        timer.resume()
    }

    /// Phase 2B: disk を scan して LA / progress を現在値に同期
    /// - consumer が suspend 中でも BG wakeup 毎に LA が追従する
    /// - 退行防止: 既存 activeDownloads.current を下回る場合は更新しない
    @MainActor
    private func fireBGProgressHint(gid: Int) {
        bgHintLock.lock()
        bgHintDebounce.removeValue(forKey: gid)
        bgHintLock.unlock()

        guard let entry = activeDownloads[gid] else { return }
        // DL が active phase でない (preparing / cooling) 時はスキップ
        guard entry.phase == .active || entry.phase == .retrying else { return }
        let total = entry.total
        guard total > 0 else { return }

        let dir = galleryDirectory(gid: gid)
        guard let contents = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        // page_NNNN.jpg の件数を数える (meta.json / cover.jpg 除外)
        var diskCount = 0
        for name in contents where name.hasPrefix("page_") { diskCount += 1 }

        if diskCount > entry.current {
            let dropped = BackgroundDownloadManager.shared.droppedCount(gid: gid)
            LogManager.shared.log("bgdl", "BGProgressHint fired: gid=\(gid) disk=\(diskCount)/\(total) prev=\(entry.current) dropped=\(dropped)")
            updateProgress(gid: gid, current: diskCount, total: total)
        }
    }

    /// DL phase のみを更新 (UI 表示切替用)
    /// preparing → cooling → preparing → active → retrying の遷移に対応
    private func updatePhase(gid: Int, phase: DownloadProgress.Phase, coolingUntil: Date? = nil) {
        guard var entry = activeDownloads[gid] else { return }
        entry.phase = phase
        entry.coolingUntil = coolingUntil
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

        // レート制限計測フラグを前回 DL のぶんクリア（新規 DL 開始につき解除）
        BackgroundDownloadManager.shared.clearRateLimit(gid: gid)

        // DL 開始時に /home.php を叩いてアカウント状態を観測ログに落とす（失敗しても続行）
        Task.detached(priority: .utility) { [client, host] in
            if let html = await client.getHomePage(host: host) {
                let snippet = Self.extractHomePageSnippet(html: html)
                LogManager.shared.log("eh-rate", "home.php BEFORE gid=\(gid): \(snippet)")
            } else {
                LogManager.shared.log("eh-rate", "home.php BEFORE gid=\(gid): fetch failed")
            }
        }

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
                    if case EhError.banned(let remaining) = error {
                        LogManager.shared.log("Download", "gid=\(gid) BANNED (cover DL), remaining=\(remaining ?? "unknown")")
                        BackgroundDownloadManager.shared.tripRateLimit(gid: gid)
                    } else {
                        LogManager.shared.log("Download", "cover failed: \(error)")
                    }
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

        // URL 解決も disk 実体を見て必要分だけに限定:
        // ehentai の ?p=N は 1 ページ 20 thumbnail。N*20..(N+1)*20 の range が
        // 全部 disk にあれば URL fetch 自体 skip して placeholder URL を入れる。
        // meta 依存ではなく fileManager 直接で判定 (reconcile 未完でも正しく skip)。
        let urlFetchPageSize = 20
        let placeholderURL = URL(string: "about:blank")!
        let fm = self.fileManager
        let imagePathForIndex: (Int) -> URL = { [weak self] idx in
            guard let self = self else { return URL(fileURLWithPath: "/dev/null") }
            return self.imageFilePath(gid: gid, page: idx)
        }
        // 事前 disk scan: 先頭から連続する disk 済み URL fetch page は一括 skip、
        // かつ disk 済み総数を集計して LiveActivity 表示の初期値に使う。
        // (prefix skip が効かなくても 0 から表示しない = 「ダメや」対策)
        var diskDoneCount = 0
        if pageCount > 0 {
            // 1) 全 index を scan して disk 済み件数カウント (表示初期化用)
            for idx in 0..<pageCount {
                let path = imagePathForIndex(idx)
                if fm.fileExists(atPath: path.path)
                    && BackgroundDownloadManager.isValidImageFile(at: path) {
                    diskDoneCount += 1
                }
            }
            // 2) prefix skip: 先頭の URL fetch page 単位で全 disk なら placeholder 投入
            var preStart = 0
            while true {
                let rangeStart = preStart * urlFetchPageSize
                let rangeEnd = min(rangeStart + urlFetchPageSize, pageCount)
                if rangeStart >= pageCount { break }
                let rangeAllOnDisk = (rangeStart..<rangeEnd).allSatisfy { idx in
                    let path = imagePathForIndex(idx)
                    return fm.fileExists(atPath: path.path)
                        && BackgroundDownloadManager.isValidImageFile(at: path)
                }
                if !rangeAllOnDisk { break }
                for _ in rangeStart..<rangeEnd {
                    allPageURLs.append(placeholderURL)
                }
                preStart += 1
            }
            if preStart > 0 {
                page = preStart
                LogManager.shared.log("Download", "URL 解決 prefix skip: 先頭 \(preStart) pages (\(allPageURLs.count) images) already on disk, start from page=\(preStart)")
            }
            // 3) 表示初期化: disk 済み件数で LiveActivity 進捗を更新 (allPageURLs より多ければ多い方)
            let displayCurrent = max(allPageURLs.count, diskDoneCount)
            if displayCurrent > 0 {
                LogManager.shared.log("Download", "URL 解決 開始表示: \(displayCurrent)/\(pageCount) (disk 済み \(diskDoneCount), prefix skip \(allPageURLs.count))")
                updateProgress(gid: gid, current: displayCurrent, total: pageCount)
            }
        }
        // URL 解決中にロック復帰で一時失敗があっても、頭から再実行にならないよう
        // 失敗は連続 10 回までは同じ page を retry (break せず続行)。
        var consecutiveFail = 0
        while true {
            // この URL fetch page が覆う image index の range
            let rangeStart = page * urlFetchPageSize
            let rangeEnd = pageCount > 0 ? min(rangeStart + urlFetchPageSize, pageCount) : rangeStart + urlFetchPageSize
            // 範囲内の全ページが disk にあるなら URL fetch skip (fileManager 直接判定)
            if pageCount > 0 && rangeStart < pageCount && rangeEnd > rangeStart {
                let rangeAllOnDisk = (rangeStart..<rangeEnd).allSatisfy { idx in
                    let path = imagePathForIndex(idx)
                    return fm.fileExists(atPath: path.path)
                        && BackgroundDownloadManager.isValidImageFile(at: path)
                }
                if rangeAllOnDisk {
                    LogManager.shared.log("Download", "URL 解決 skip page=\(page) (pages \(rangeStart + 1)-\(rangeEnd) already on disk)")
                    for _ in rangeStart..<rangeEnd {
                        allPageURLs.append(placeholderURL)
                    }
                    page += 1
                    let metaDoneSkip = downloads[gid]?.downloadedPages.count ?? 0
                    updateProgress(gid: gid, current: max(allPageURLs.count, max(diskDoneCount, metaDoneSkip)), total: pageCount > 0 ? pageCount : max(pageCount, allPageURLs.count))
                    if allPageURLs.count >= pageCount { break }
                    continue
                }
            }
            do {
                let urlString = page > 0 ? galleryURLStr + "?p=\(page)" : galleryURLStr
                LogManager.shared.log("Download", "fetching page URLs: \(urlString)")
                // BG session 経由 (suspend 中も継続) で gallery page HTML 取得
                let html = try await client.fetchHTMLViaBGOrFallback(urlString: urlString, host: host)
                let urls = HTMLParser.parseImagePageURLs(html: html)
                LogManager.shared.log("Download", "  got \(urls.count) URLs from page \(page), total so far: \(allPageURLs.count + urls.count)")

                if urls.isEmpty {
                    LogManager.shared.log("Download", "  empty response, stopping")
                    break
                }

                allPageURLs.append(contentsOf: urls)
                page += 1
                consecutiveFail = 0

                // preparing 期の進捗として URL 解決数を current/total に反映
                // (UI: 「URL解決中 got/expected」表示、バーも出す)
                // LiveActivity 表示後退防止: disk 済み数 (meta 直参照) と max を取る
                let metaDoneForUpdate = downloads[gid]?.downloadedPages.count ?? 0
                updateProgress(gid: gid, current: max(allPageURLs.count, max(diskDoneCount, metaDoneForUpdate)), total: pageCount > 0 ? pageCount : max(pageCount, allPageURLs.count))

                if pageCount > 0 && allPageURLs.count >= pageCount {
                    LogManager.shared.log("Download", "  reached expected pageCount=\(pageCount), stopping")
                    break
                }
                if page > 200 {
                    LogManager.shared.log("Download", "  safety limit reached")
                    break
                }

                // === BAN 予防 cooldown: 50 画面毎に 60s sleep (safetyMode ON 時のみ) ===
                // 閾値は ehentai-ban-criteria SKILL.md 実測データ由来 (60 画面安全 / 100 画面 BAN)
                // 残り 10 画面以下なら終了間近なので cooldown 省略 (冗長回避)
                let expectedScreens = pageCount > 0 ? (pageCount + 19) / 20 : Int.max
                let remainingScreens = max(expectedScreens - page, 0)
                if SafetyMode.shared.isEnabled && page > 0 && page % 50 == 0 && remainingScreens >= 10 {
                    let cooldownEnd = Date().addingTimeInterval(60)
                    LogManager.shared.log("eh-rate", "cooldown start after \(page) screens, 60s sleep")
                    updatePhase(gid: gid, phase: .cooling, coolingUntil: cooldownEnd)
                    // 500ms x 120 回分割: cancel 即反映
                    for _ in 0..<120 {
                        if activeDownloads[gid]?.isCancelled == true { break }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    updatePhase(gid: gid, phase: .preparing, coolingUntil: nil)
                    LogManager.shared.log("eh-rate", "cooldown end, resuming URL resolve")
                } else {
                    await SafetyMode.shared.delay(nanoseconds: requestDelay)
                }
            } catch {
                // BAN 検知時は即停止 (retry で BAN 時間延長を防ぐ)
                if case EhError.banned(let remaining) = error {
                    LogManager.shared.log("Download", "gid=\(gid) BANNED (URL resolve), remaining=\(remaining ?? "unknown"), halt 1stpass")
                    BackgroundDownloadManager.shared.tripRateLimit(gid: gid)
                    break
                }
                consecutiveFail += 1
                LogManager.shared.log("Download", "page URL fetch fail \(consecutiveFail)/10 page=\(page): \(error)")
                if consecutiveFail >= 10 {
                    LogManager.shared.log("Download", "page URL fetch give up after 10 consecutive fails page=\(page)")
                    break
                }
                // 短 sleep で同じ page を再試行 (break せず続行)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
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
                    await SafetyMode.shared.delay(nanoseconds: requestDelay)
                } catch {
                    if case EhError.banned(let remaining) = error {
                        LogManager.shared.log("Download", "gid=\(gid) BANNED (fallback URL resolve), remaining=\(remaining ?? "unknown"), halt")
                        BackgroundDownloadManager.shared.tripRateLimit(gid: gid)
                    } else {
                        LogManager.shared.log("Download", "fallback page URL fetch failed: \(error)")
                    }
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

        // セーフティ OFF (旧エクストリーム) なら後方DLを同時起動（ECOモード時は無効）
        if !SafetyMode.shared.isEnabled && !EcoMode.shared.isEnabled {
            state.backwardRunning = true
            state.backwardCancelled = false
            LogManager.shared.log("Download", "gid=\(gid) SAFETY-OFF: starting backward download")
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
        // enqueue 計測: counter をスレッド安全に扱うため actor で包む
        let enqueueStats = EnqueueStatsCounter(total: pendingIndices.count)
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for index in pendingIndices {
                    if weakSelf.activeDownloads[gid]?.isCancelled == true { break }
                    // 509/HTML 検知で halted gid はこれ以上 enqueue しない
                    if BackgroundDownloadManager.shared.isRateLimited(gid: gid) {
                        LogManager.shared.log("bgdl", "gid=\(gid) enqueue loop halted (rateLimited)")
                        break
                    }
                    let pageURL = allPageURLs[index]
                    let filePath = weakSelf.imageFilePath(gid: gid, page: index)
                    group.addTask {
                        await urlResolveSem.wait()
                        defer { urlResolveSem.signal() }
                        // wait で待機している間に trip した可能性あるので再チェック
                        if BackgroundDownloadManager.shared.isRateLimited(gid: gid) { return }
                        do {
                            let imageURL = try await resolveClient.fetchImageURL(pageURL: pageURL)
                            if BackgroundDownloadManager.shared.isRateLimited(gid: gid) { return }
                            BackgroundDownloadManager.shared.enqueue(
                                url: imageURL, gid: gid, pageIndex: index, finalPath: filePath,
                                session: session, headers: ehHeaders
                            )
                            await enqueueStats.bump(gid: gid, page: index, urlTail: imageURL.absoluteString.suffix(60))
                        } catch {
                            // BAN 検知時は即 trip: 他の並列 task も次回 check で halt + 2ndpass も skip
                            if case EhError.banned(let remaining) = error {
                                BackgroundDownloadManager.shared.tripRateLimit(gid: gid)
                                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) BANNED (URL resolve), remaining=\(remaining ?? "unknown"), tripping rateLimit")
                                return  // ダミー enqueue せず即抜ける
                            }
                            LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) URL解決失敗: \(error.localizedDescription)")
                            // 失敗もstream経由で通知（mirror再試行はsecondpassで）
                            BackgroundDownloadManager.shared.enqueue(
                                url: pageURL,  // ダミー（HTMLを画像扱いで失敗する）
                                gid: gid, pageIndex: index, finalPath: filePath,
                                session: session, headers: ehHeaders
                            )
                            await enqueueStats.bump(gid: gid, page: index, urlTail: "(resolve-failed)")
                        }
                    }
                }
            }
        }

        // 完了stream消費（stall watchdog付き）
        // scenePhase に応じて閾値可変:
        //   FG 中: 20s (「突っかかり」を短時間で切って 2ndpass へ)
        //   BG 中 (preferBGSession=true): 300s (iOS throttling 下でも stream を保持)
        var pendingCount = pendingIndices.count
        let fgStallThreshold: Double = 20.0
        let bgStallThreshold: Double = 300.0
        let lastProgressBox = StallBox()
        lastProgressBox.update()

        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5秒毎チェック
                if Task.isCancelled { break }
                let elapsed = CFAbsoluteTimeGetCurrent() - lastProgressBox.value
                let threshold = BackgroundDownloadManager.shared.isPreferringBGSession ? bgStallThreshold : fgStallThreshold
                if elapsed > threshold {
                    LogManager.shared.log("Download", "gid=\(gid) BG stream stall \(Int(elapsed))s - forcing finish (threshold=\(Int(threshold))s, bg=\(BackgroundDownloadManager.shared.isPreferringBGSession))")
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

        // セカンドパス: 失敗ページを再試行 (BAN 中は skip、BAN 期間延長を防ぐ)
        if BackgroundDownloadManager.shared.isRateLimited(gid: gid) {
            LogManager.shared.log("Download", "gid=\(gid) 2ndpass SKIP: rate limited (BAN 中は再試行しない)")
        }
        let allFailed = state.failedPages.filter { !state.downloadedSet.contains($0.index) }
        if !allFailed.isEmpty && !BackgroundDownloadManager.shared.isRateLimited(gid: gid) {
            let failedPageNums = allFailed.map { $0.index + 1 }
            LogManager.shared.log("Download", "gid=\(gid) 2ndpass START retry=\(failedPageNums) (5s wait)")
            // UI: 「別ミラーから再試行中」に切替 (info マーク表示用)
            updatePhase(gid: gid, phase: .retrying)
            // 5s 待機中に cancelDownload されたら即脱出（小刻みに分割してチェック）
            for _ in 0..<10 {
                if activeDownloads[gid]?.isCancelled == true { break }
                await SafetyMode.shared.delay(nanoseconds: 500_000_000)
            }

            // 並列度 5 で 2ndpass を回す (TaskGroup、常時 5 枚分の download を並走)
            // - 各 task 内で isCancelled check、SafetyMode.delay は維持
            // - state.downloadedSet / progress の write は主 task 側 (await group.next() 受信点) で集約 → race 回避
            // - 動画 WebP 用途: mirror DL 数が多く、並列化の効果大
            let maxConcurrent = 5
            var iterator = allFailed.makeIterator()
            await withTaskGroup(of: (Int, Bool?).self) { group in
                // ファイル既存 skip を先に全件捌いて、本当に DL 必要なものだけ task 化
                func enqueueNext() -> Bool {
                    while let (index, pageURL) = iterator.next() {
                        if activeDownloads[gid]?.isCancelled == true { return false }
                        if state.downloadedSet.contains(index) { continue }

                        let filePath = imageFilePath(gid: gid, page: index)
                        if fileManager.fileExists(atPath: filePath.path),
                           BackgroundDownloadManager.isValidImageFile(at: filePath) {
                            state.downloadedSet.insert(index)
                            addDownloadedBytes(gid: gid, page: index)
                            updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
                            LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) already on disk, skip 2ndpass")
                            continue
                        }
                        LogManager.shared.log("Download", "gid=\(gid) 2ndpass page \(index + 1) start url=\(pageURL.absoluteString.suffix(60))")
                        group.addTask { [self] in
                            let ok = await downloadSinglePage(
                                gid: gid, index: index, pageURL: pageURL,
                                filePath: filePath, host: host, maxRetries: 3,
                                forceMirror: true
                            )
                            await SafetyMode.shared.delay(nanoseconds: requestDelay)
                            return (index, ok)
                        }
                        return true
                    }
                    return false
                }

                // 初期スロット埋め (最大 3)
                for _ in 0..<maxConcurrent {
                    if activeDownloads[gid]?.isCancelled == true { break }
                    _ = enqueueNext()
                }

                // 完了次第、次の task を投入
                while let (index, okOpt) = await group.next() {
                    if let ok = okOpt {
                        if ok {
                            state.downloadedSet.insert(index)
                            addDownloadedBytes(gid: gid, page: index)
                            // 速度表示用: 2ndpass は delegate 経由で bytes が届かないため
                            // ファイルサイズを直接累積へ加算する
                            let filePath = imageFilePath(gid: gid, page: index)
                            if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path),
                               let size = attrs[.size] as? Int64 {
                                BackgroundDownloadManager.shared.addCumulativeBytes(gid: gid, bytes: size)
                            }
                            updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
                            LogManager.shared.log("Download", "gid=\(gid) 2ndpass page \(index + 1) OK")
                        } else {
                            LogManager.shared.log("Download", "gid=\(gid) page \(index + 1)/\(totalPages) PERMANENTLY FAILED")
                        }
                    }
                    if activeDownloads[gid]?.isCancelled == true { continue }
                    _ = enqueueNext()
                }
            }
            LogManager.shared.log("Download", "gid=\(gid) 2ndpass END: done=\(state.downloadedSet.count)/\(totalPages)")
        }

        // BG session DROPPED completion 救済: meta 保存前にディスク上の実ファイルを scan して
        // downloadedSet に追加 (完了通知取りこぼしても実体は保存済みのケース)
        var reconciledAdded = 0
        for idx in 0..<totalPages where !state.downloadedSet.contains(idx) {
            let p = imageFilePath(gid: gid, page: idx)
            if fileManager.fileExists(atPath: p.path),
               BackgroundDownloadManager.isValidImageFile(at: p) {
                state.downloadedSet.insert(idx)
                addDownloadedBytes(gid: gid, page: idx)
                reconciledAdded += 1
            }
        }
        if reconciledAdded > 0 {
            LogManager.shared.log("Download", "gid=\(gid) reconcile before save: +\(reconciledAdded) pages → \(state.downloadedSet.count)/\(totalPages)")
            updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
        }

        // 完了処理: @Published dict は subscript mutation だとSwiftUI更新が不確実
        // → MainActor + 再代入パターンで確実に通知発火させる
        meta.downloadedPages = Array(state.downloadedSet)
        meta.isComplete = totalPages > 0 && state.downloadedSet.count >= totalPages
        meta.downloadDate = Date()
        if meta.isComplete {
            meta.hasAnimatedWebp = scanHasAnimatedWebp(gid: gid)
            LogManager.shared.log("Anim", "post-DL scan gid=\(gid) hasAnimatedWebp=\(meta.hasAnimatedWebp ?? false)")
        }
        let finalMeta = meta
        let completed = meta.isComplete
        await MainActor.run {
            // 途中で deleteDownload された場合、downloads から entry が消えている。
            // そのまま saveMetadata すると ensureDirectory + 再挿入で蘇生してしまう。
            let wasDeleted = downloads[gid] == nil
            if !wasDeleted {
                saveMetadata(finalMeta)
            }
            // 再代入で @Published 通知を確実発火
            var updatedActive = activeDownloads
            updatedActive.removeValue(forKey: gid)
            activeDownloads = updatedActive
            biDirStates.removeValue(forKey: gid)
            endLiveActivity(gid: gid, success: completed)
        }
        LogManager.shared.log("Download", "gid=\(gid) finished: \(state.downloadedSet.count)/\(totalPages) isComplete=\(completed)")

        // DL 完了 / 中断後に /home.php を叩いてアカウント状態の前後比較ログ（失敗しても無視）
        Task.detached(priority: .utility) { [client, host] in
            if let html = await client.getHomePage(host: host) {
                let snippet = Self.extractHomePageSnippet(html: html)
                LogManager.shared.log("eh-rate", "home.php AFTER gid=\(gid): \(snippet)")
            } else {
                LogManager.shared.log("eh-rate", "home.php AFTER gid=\(gid): fetch failed")
            }
        }

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
            await SafetyMode.shared.delay(nanoseconds: requestDelay)

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
            // 各 attempt 冒頭でキャンセル反映（fetchImageURL の途中で cancel された後の次 attempt を即脱出）
            if activeDownloads[gid]?.isCancelled == true { return false }
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
                if activeDownloads[gid]?.isCancelled == true { return false }
                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) attempt \(attempt): resolved → \(imageURL.absoluteString.suffix(80))")

                await SafetyMode.shared.delay(nanoseconds: requestDelay)
                if activeDownloads[gid]?.isCancelled == true { return false }

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
                if activeDownloads[gid]?.isCancelled == true { return false }
                guard ok, BackgroundDownloadManager.isValidImageFile(at: filePath) else {
                    try? FileManager.default.removeItem(at: filePath)
                    LogManager.shared.log("Download", "gid=\(gid) page \(index + 1): invalid/empty (attempt \(attempt)/\(maxRetries))")
                    if attempt < maxRetries {
                        await SafetyMode.shared.delay(nanoseconds: 3_000_000_000)
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
                    await SafetyMode.shared.delay(nanoseconds: backoff)
                }
            } catch {
                // BAN 検知時は即 trip + 全 retry 中断 (BAN 期間延長を防ぐ)
                if case EhError.banned(let remaining) = error {
                    LogManager.shared.log("Download", "gid=\(gid) page \(index + 1): BANNED, remaining=\(remaining ?? "unknown"), halt 2ndpass")
                    BackgroundDownloadManager.shared.tripRateLimit(gid: gid)
                    return false
                }
                LogManager.shared.log("Download", "gid=\(gid) page \(index + 1): \(error) (attempt \(attempt)/\(maxRetries))")
                if attempt < maxRetries {
                    let backoff = UInt64(attempt) * 3_000_000_000
                    await SafetyMode.shared.delay(nanoseconds: backoff)
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

    /// /home.php HTML から観測ポイントの該当行を抜き出す（50文字前後）
    nonisolated static func extractHomePageSnippet(html: String) -> String {
        let patterns = ["IP-based limits", "restriction in effect", "Image Limits", "Image Restrictions", "Hath Perks"]
        var hits: [String] = []
        for p in patterns {
            guard let range = html.range(of: p) else { continue }
            let start = html.index(range.lowerBound, offsetBy: -30, limitedBy: html.startIndex) ?? html.startIndex
            let end = html.index(range.upperBound, offsetBy: 120, limitedBy: html.endIndex) ?? html.endIndex
            let raw = String(html[start..<end])
            let cleaned = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            hits.append("…\(cleaned)…")
        }
        if hits.isEmpty { return "len=\(html.count), no quota keyword" }
        return hits.joined(separator: " | ")
    }

    /// 並列 enqueue のカウント + 10 枚ごとの進捗サマリ出力
    fileprivate actor EnqueueStatsCounter {
        let total: Int
        let startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
        private var count: Int = 0

        init(total: Int) {
            self.total = total
        }

        func bump(gid: Int, page: Int, urlTail: Substring) {
            count += 1
            let n = count
            LogManager.shared.log("bgdl", "enqueued \(n)/\(total) gid=\(gid) page=\(page + 1) url=...\(urlTail)")
            if n % 10 == 0 || n == total {
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let avgMs = elapsed / Double(n) * 1000
                LogManager.shared.log("bgdl", "progress \(n)/\(total) elapsed=\(String(format: "%.2f", elapsed))s avg=\(String(format: "%.1f", avgMs))ms/img")
            }
        }
    }

    // MARK: - 動画 WebP 判定 + リーダーモード上書き

    /// ギャラリーディレクトリ内のページを走査しアニメ WebP が 1 枚でもあれば true。
    /// ページファイルの拡張子は保存時に .jpg 固定だが中身は WebP / JPEG 混在しうるので
    /// 先頭 32 バイトのマジックで判定。
    nonisolated func scanHasAnimatedWebp(gid: Int) -> Bool {
        let dir = baseDirectory.appendingPathComponent("\(gid)", isDirectory: true)
        return WebPAnimationDetector.directoryContainsAnimated(dir)
    }

    /// 初回 Reader 起動時の migration。hasAnimatedWebp が nil の場合に走査 + 保存。
    /// すでに判定済み or meta 未登録なら no-op。
    @MainActor
    func ensureAnimatedWebpScanned(gid: Int) async {
        guard var meta = downloads[gid], meta.hasAnimatedWebp == nil else { return }
        let flag = await Task.detached(priority: .utility) { [gid, self] in
            self.scanHasAnimatedWebp(gid: gid)
        }.value
        // 走査中に削除された場合は書き戻さない
        guard downloads[gid] != nil else { return }
        meta.hasAnimatedWebp = flag
        saveMetadata(meta)
        LogManager.shared.log("Anim", "migration scan gid=\(gid) hasAnimatedWebp=\(flag)")
    }

    /// ダイアログ選択結果を per-gallery 保存。
    @MainActor
    func setReaderModeOverride(gid: Int, mode: GalleryReaderMode?) {
        guard var meta = downloads[gid] else { return }
        meta.readerModeOverride = mode
        saveMetadata(meta)
    }

    /// 設定画面「モード選択をリセット」で全 override を nil に戻す。
    @MainActor
    func resetAllReaderModeOverrides() {
        var count = 0
        for (_, var meta) in downloads where meta.readerModeOverride != nil {
            meta.readerModeOverride = nil
            saveMetadata(meta)
            count += 1
        }
        LogManager.shared.log("Anim", "resetAllReaderModeOverrides: cleared \(count)")
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
