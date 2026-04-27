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
    /// 田中要望 2026-04-26: 外部参照 .cortex の original E-Hentai/nhentai gid を保持。
    /// scanCortexZip で gid が Int.max - hash(zipPath) に namespace 分離されるため、
    /// 元 server 詳細 fetch (GalleryDetailView) には original gid が必要。
    /// nil = 旧 .cortex (export 時 metadata 未保存) or non-external、source server 詳細表示不可。
    var originalGid: Int? = nil

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

    /// 田中要望 2026-04-26: reader close 時に coverCache を flush する API。
    func flushCoverMemoryCache() {
        coverCache.removeAllObjects()
    }
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
    /// staging → NAS 転送中の進捗 (nil = 転送なし)。SMB 大量書込中は UI が固まりがちなので
    /// ダイアログ + プログレスバー表示用に MainActor で公開 (2026-04-27 田中)。
    @Published var currentTransfer: TransferProgress?

    struct TransferProgress: Equatable {
        let gid: Int
        let title: String
        let totalBytes: UInt64
        var doneBytes: UInt64
    }

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
        cleanupOrphanNasSubdirs()  // 田中報告 2026-04-26: 復活防止、resumeIncompleteDownloads より先に実行
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
        // 田中 emergency fix 2026-04-26: NAS に対応 .cortex がある gid は phantom resume 阻止
        let cortexBaseNames: Set<String> = {
            #if targetEnvironment(macCatalyst)
            guard ExternalFolderManager.shared.activeDLSaveDestinationURL != nil else { return [] }
            guard let entries = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else { return [] }
            return Set(entries.filter { $0.pathExtension.lowercased() == "cortex" }
                              .map { $0.deletingPathExtension().lastPathComponent })
            #else
            return []
            #endif
        }()
        let incompleteItems = downloads.filter {
            guard !$0.value.isComplete && !$0.value.token.isEmpty && $0.value.isCancelled != true else { return false }
            // .cortex 名 = title.prefix(50) (GalleryExporter と整合)
            let safeName = String($0.value.title.replacingOccurrences(of: "/", with: "_").prefix(50))
            if cortexBaseNames.contains(safeName) {
                LogManager.shared.log("Download", "skip phantom resume gid=\($0.key) title='\(safeName)' (matching .cortex on NAS)")
                // downloads dict からも除去 (UI からも消す)
                downloads.removeValue(forKey: $0.key)
                return false
            }
            return true
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
        // Step 9 (Phase E1, 2026-04-26): Mac Catalyst で user-selectable DL 保存先を hook。
        // ExternalFolderManager.activeDLSaveDestinationURL が non-nil ならそれを使う、
        // nil (未設定 or stale) なら default `<documents>/EhViewer/downloads` に fallback。
        // 田中判断 Q-2: 既存 DL は旧パスに残る、新規 DL のみ新パスへ。
        // 切替後は app 再起動で反映 (DL 中の path 切替は safety のため非対応)。
        #if targetEnvironment(macCatalyst)
        if let custom = ExternalFolderManager.shared.activeDLSaveDestinationURL {
            return custom
        }
        #endif
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("EhViewer/downloads", isDirectory: true)
    }

    func galleryDirectory(gid: Int) -> URL {
        // Phase E1.B (2026-04-26 田中要望): NAS DL save dest 設定時の per-page SMB roundtrip
        // 削減のため、DL 中は local SSD staging に書込 → 完了で bulk move。
        // staging gid 集合で判定、DL 完了後は通常 baseDirectory に解決される。
        if isStaging(gid: gid) {
            return dlStagingBase.appendingPathComponent("\(gid)", isDirectory: true)
        }
        return baseDirectory.appendingPathComponent("\(gid)", isDirectory: true)
    }

    func ensureDirectory(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Staging-based DL (Phase E1.B 田中要望 2026-04-26)
    //
    // NAS DL save dest 設定時に DL 中は local SSD staging へ書込、完了で bulk move。
    // per-page SMB metadata roundtrip を撲滅、推定 2-3x DL 高速化。

    private var stagingGids: Set<Int> = []
    private let stagingLock = NSLock()

    /// staging directory (常に local SSD)。
    private var dlStagingBase: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("EhViewer/dl_staging", isDirectory: true)
    }

    func isStaging(gid: Int) -> Bool {
        stagingLock.lock(); defer { stagingLock.unlock() }
        return stagingGids.contains(gid)
    }

    /// DL 開始時に呼ぶ (NAS DL save dest 設定時のみ)。staging set に追加。
    func addStaging(gid: Int) {
        stagingLock.lock(); stagingGids.insert(gid); stagingLock.unlock()
        LogManager.shared.log("DLStaging", "added gid=\(gid)")
    }

    private func removeStaging(gid: Int) {
        stagingLock.lock(); stagingGids.remove(gid); stagingLock.unlock()
    }

    /// staging/<gid> を ZIP 圧縮 (.cortex) → NAS に **直接 stream write** (tmp 経由しない)。
    /// 田中要望 2026-04-27: 旧フロー (staging → tmp/.cortex → NAS) は SSD ピーク使用量が
    /// staging × 2 ≈ 20GB+ となり大容量作品で ENOSPC 発生 → 直接 NAS stream に修正。
    /// 完了後 staging 削除 + downloads[gid] 解除 (外部参照 .cortex として scan 拾上げ)。
    func moveStagingToFinalDest(gid: Int) async {
        let sourceDir = dlStagingBase.appendingPathComponent("\(gid)")
        guard fileManager.fileExists(atPath: sourceDir.path) else {
            LogManager.shared.log("DLStaging", "no staging dir for gid=\(gid), skip move")
            removeStaging(gid: gid)
            return
        }

        // 出力先 .cortex (NAS final URL)。タイトルから safeName 生成 (existing logic と整合)
        let title = downloads[gid]?.title ?? "\(gid)"
        let safeName = title.replacingOccurrences(of: "/", with: "_").prefix(50)
        let destURL = baseDirectory.appendingPathComponent("\(safeName).cortex")

        // 既存 .cortex が同名であれば上書き
        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }

        // 進捗 UI: ZIP 化 stream は事前総量不明なので staging dir size を推定値に使う
        let stagingSize = Self.dirSize(sourceDir)
        let transferTitle = String(safeName)
        await MainActor.run {
            currentTransfer = TransferProgress(gid: gid, title: transferTitle, totalBytes: stagingSize, doneBytes: 0)
        }

        // staging → NAS/<title>.cortex を 1 段で stream ZIP write (SSD 倍取り解消)
        do {
            _ = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                try GalleryExporter.exportAsZipStreaming(
                    gid: gid,
                    progress: { completed, total in
                        Task { @MainActor in
                            // page count progress を doneBytes に近似変換 (UI 進捗のみ)
                            let estDone = total > 0 ? UInt64(stagingSize) * UInt64(completed) / UInt64(total) : 0
                            DownloadManager.shared.currentTransfer?.doneBytes = estDone
                        }
                    },
                    destOverride: destURL
                )
            }.value
            let size = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? UInt64) ?? 0
            LogManager.shared.log("DLStaging", "moved gid=\(gid) → NAS:\(destURL.lastPathComponent) (size=\(size)) [direct stream]")
        } catch {
            LogManager.shared.log("DLStaging", "direct NAS stream failed gid=\(gid): \(error)")
            // 失敗時は中途半端な NAS file を片付ける (再試行のクリーン状態に)
            try? fileManager.removeItem(at: destURL)
            await MainActor.run { currentTransfer = nil }
            removeStaging(gid: gid)
            return
        }
        await MainActor.run { currentTransfer = nil }

        // staging dir 削除 (DL 中の各 page file を local SSD から完全消去)
        try? fileManager.removeItem(at: sourceDir)

        // removeStaging (galleryDirectory が baseDirectory に解決される、ただし NAS に
        // folder 形式では存在しない、.cortex 形式なので external scan 経由でアクセス)
        removeStaging(gid: gid)

        // downloads[gid] 削除 (gallery は外部参照 .cortex として再認識される)
        await MainActor.run {
            downloads[gid] = nil
        }

        // NAS の旧 subdir 形式残骸を削除 (next launch で auto-resume されるのを防ぐ)
        let oldNasSubdir = baseDirectory.appendingPathComponent("\(gid)", isDirectory: true)
        if fileManager.fileExists(atPath: oldNasSubdir.path) {
            try? fileManager.removeItem(at: oldNasSubdir)
            LogManager.shared.log("DLStaging", "removed old NAS subdir gid=\(gid) (orphan after .cortex move)")
        }

        // 外部参照 rescan で新 .cortex を Library に表示
        await ExternalFolderManager.shared.rescanAll()
    }

    /// dirSize: ファイル列挙で総サイズを計算 (進捗 UI 用)
    private static func dirSize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let f as URL in it {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += UInt64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// SSD 残量チェック: staging に必要な領域が確保できるかを推定して bool で返す。
    /// 田中要望 2026-04-27: 「キャッシュがストレージ超えそうなら警告出せ」対応。
    /// 推定総 DL size が SSD 残量の `safetyRatio` (default 70%) を超えるなら false。
    func hasSufficientSSDSpaceForDownload(estimatedBytes: UInt64, safetyRatio: Double = 0.7) -> Bool {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let attrs = try? fileManager.attributesOfFileSystem(forPath: docs.path),
              let free = attrs[.systemFreeSize] as? UInt64 else {
            return true  // 取得失敗時は通す (false で全 DL ブロックは厳しすぎ)
        }
        let limit = UInt64(Double(free) * safetyRatio)
        return estimatedBytes < limit
    }

    /// SSD 残量取得 (CUI debug 用)
    func ssdFreeBytes() -> UInt64 {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let attrs = try? fileManager.attributesOfFileSystem(forPath: docs.path),
              let free = attrs[.systemFreeSize] as? UInt64 else { return 0 }
        return free
    }

    /// チャンク単位でファイルを copy しつつ進捗を通知する。FileManager.copyItem は
    /// 進捗 API を持たないので、SMB 大容量転送中の rainbow spinner 対策として
    /// FileHandle ベースの 8MB チャンク write に置換 (2026-04-27 田中)。
    private static func copyWithProgress(
        from src: URL,
        to dst: URL,
        chunkSize: Int = 8 * 1024 * 1024,
        progress: @escaping (UInt64) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let inFile = try FileHandle(forReadingFrom: src)
            defer { try? inFile.close() }
            FileManager.default.createFile(atPath: dst.path, contents: nil)
            let outFile = try FileHandle(forWritingTo: dst)
            defer { try? outFile.close() }

            var copied: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try inFile.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try outFile.write(contentsOf: chunk)
                copied += UInt64(chunk.count)
                progress(copied)
            }
        }.value
    }

    /// 田中報告 2026-04-26 fix: 起動時 NAS folder の orphan subdir cleanup。
    /// `<gid>/` subdir があり、対応する `<title>.cortex` が同 folder にあれば
    /// その subdir は staging→ZIP move 時の cleanup 漏れと判定して削除。
    /// resumeIncompleteDownloads より先に呼ぶ必要あり (= init 中に呼ぶ)。
    func cleanupOrphanNasSubdirs() {
        #if targetEnvironment(macCatalyst)
        guard ExternalFolderManager.shared.activeDLSaveDestinationURL != nil else { return }
        guard let entries = try? fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else { return }
        let cortexBaseNames = Set(entries
            .filter { $0.pathExtension.lowercased() == "cortex" }
            .map { $0.deletingPathExtension().lastPathComponent })
        guard !cortexBaseNames.isEmpty else { return }
        var cleaned = 0
        for entry in entries {
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard exists, isDir.boolValue, Int(entry.lastPathComponent) != nil else { continue }
            // この subdir の metadata.json から title 取得
            let metaURL = entry.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(DownloadedGallery.self, from: data) else { continue }
            let safeName = String(meta.title.replacingOccurrences(of: "/", with: "_").prefix(50))
            if cortexBaseNames.contains(safeName) {
                try? fileManager.removeItem(at: entry)
                cleaned += 1
                LogManager.shared.log("DLStaging", "startup cleanup: removed orphan NAS subdir \(entry.lastPathComponent) (matching .cortex=\(safeName))")
                // downloads dict からも除去 (loadAllMetadata で読み込まれてた場合)
                if let gid = Int(entry.lastPathComponent) {
                    downloads.removeValue(forKey: gid)
                }
            }
        }
        if cleaned > 0 {
            LogManager.shared.log("DLStaging", "startup cleanup done: \(cleaned) orphan subdirs removed")
        }
        #endif
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
        // Phase E1.B β-1 (2026-04-26 田中指示): 外部参照 ZIP gallery を non-blocking 経路で hook。
        // cachedOrTriggerBackground = cache hit URL を即返す or background materialize trigger 後
        // (存在しないかもしれない) URL を返す。main thread で SMB IO 同期実行は発生しない。
        // 完了で Notification.externalCortexImageReady 発火、Reader が再描画 trigger。
        if let extURL = ExternalCortexZipReader.shared.cachedOrTriggerBackground(gid: gid, page: page) {
            return extURL
        }
        return galleryDirectory(gid: gid).appendingPathComponent("page_\(String(format: "%04d", page)).jpg")
    }

    func coverFilePath(gid: Int) -> URL {
        // β-1: cover も non-blocking 化 (cover.* or page_0001 を background materialize)
        if ExternalCortexZipReader.shared.isExternalGallery(gid: gid) {
            // cover はまず cachedOrTriggerBackground(page: 0) で代用 (cover.* と page_0001 は同等視)
            if let extURL = ExternalCortexZipReader.shared.cachedOrTriggerBackground(gid: gid, page: 0) {
                return extURL
            }
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

        // 田中要望 2026-04-26: NAS DL save dest 設定時は staging に書込む
        #if targetEnvironment(macCatalyst)
        if ExternalFolderManager.shared.activeDLSaveDestinationURL != nil {
            addStaging(gid: gid)
        }
        #endif

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

        // 田中要望 2026-04-26: 完了後 staging → NAS bulk move (background)
        // 田中要望 2026-04-27: failed page が残っていても 1 枚以上 DL 済みなら partial finalize
        // 田中要望 2026-04-27 (2): cancel/delete された gid は finalize しない (zombie 防止)
        let hasAnyDownloadedNh = state.downloadedSet.count > 0
        let wasCancelledNh = activeDownloads[gid]?.isCancelled == true || (downloads[gid]?.isCancelled ?? false) || recentlyDeletedGids.contains(gid)
        if hasAnyDownloadedNh && isStaging(gid: gid) && !wasCancelledNh {
            if !completed {
                let missing = (0..<totalPages).filter { !state.downloadedSet.contains($0) }.map { $0 + 1 }
                LogManager.shared.log("Download", "nhentai gid=\(gid) partial finalize: \(state.downloadedSet.count)/\(totalPages) (missing=\(missing.prefix(20))\(missing.count > 20 ? "..." : ""))")
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.moveStagingToFinalDest(gid: gid)
            }
        } else if wasCancelledNh {
            LogManager.shared.log("Download", "nhentai gid=\(gid) finalize SKIPPED (cancelled/deleted)")
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
        // 田中要望 2026-04-27: cancel = staging も全消去 (partial finalize 防止 + SSD 即解放)
        // 中止 / 削除が動かない bug の root cause: cancel しても staging が残り、
        // performDownload 末端で partial finalize が走って .cortex 化されてしまう。
        let stagingDir = dlStagingBase.appendingPathComponent("\(gid)")
        if fileManager.fileExists(atPath: stagingDir.path) {
            try? fileManager.removeItem(at: stagingDir)
            LogManager.shared.log("Download", "cancelDownload: staging removed gid=\(gid)")
        }
        removeStaging(gid: gid)
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
        // 田中要望 2026-04-27: 削除も中止も動くようにする
        //   - galleryDirectory はファイル参照中の状態によっては staging or baseDirectory を返す
        //   - どちらにも残骸が出るので両方明示的に消す (partial finalize 防止)
        let mainDir = galleryDirectory(gid: gid)
        try? fileManager.removeItem(at: mainDir)
        let stagingDir = dlStagingBase.appendingPathComponent("\(gid)")
        if fileManager.fileExists(atPath: stagingDir.path) {
            try? fileManager.removeItem(at: stagingDir)
            LogManager.shared.log("Download", "deleteDownload: staging removed gid=\(gid)")
        }
        let baseDir = baseDirectory.appendingPathComponent("\(gid)", isDirectory: true)
        if fileManager.fileExists(atPath: baseDir.path) {
            try? fileManager.removeItem(at: baseDir)
            LogManager.shared.log("Download", "deleteDownload: base subdir removed gid=\(gid)")
        }
        removeStaging(gid: gid)
        downloads.removeValue(forKey: gid)
        coverCache.removeObject(forKey: NSNumber(value: gid))
        // metadata.json 自体は galleryDirectory 配下なので mainDir 削除で消えるが、
        // base path に残っている可能性 (isStaging 切替の race) を念のため
        let metaPath = baseDirectory.appendingPathComponent("\(gid)/metadata.json")
        try? fileManager.removeItem(at: metaPath)
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

        // 田中要望 2026-04-26: NAS DL save dest 設定時は staging に書込む (per-page SMB roundtrip 削減)
        #if targetEnvironment(macCatalyst)
        if ExternalFolderManager.shared.activeDLSaveDestinationURL != nil {
            addStaging(gid: gid)
        }
        #endif

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
                        // 田中提案 (2026-04-27): 1st pass にインライン retry を導入。
                        // 一時的な Cloudflare challenge / mirror URL stale で 1 回コケただけでも
                        // 即 2ndpass に push されると 2ndpass の URL 再 resolve コストが大きいので、
                        // BAN 以外のエラーは 1st pass 内で計 3 回まで再試行 (短い backoff 付き)。
                        var resolved: URL?
                        var lastError: Error?
                        let maxAttempts = 3
                        for attempt in 1...maxAttempts {
                            if BackgroundDownloadManager.shared.isRateLimited(gid: gid) { return }
                            do {
                                resolved = try await resolveClient.fetchImageURL(pageURL: pageURL)
                                break
                            } catch {
                                lastError = error
                                // BAN 検知時は即 trip: 他の並列 task も次回 check で halt + 2ndpass も skip
                                if case EhError.banned(let remaining) = error {
                                    BackgroundDownloadManager.shared.tripRateLimit(gid: gid)
                                    LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) BANNED (URL resolve), remaining=\(remaining ?? "unknown"), tripping rateLimit")
                                    return  // ダミー enqueue せず即抜ける
                                }
                                if attempt < maxAttempts {
                                    LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) URL解決 transient fail attempt=\(attempt)/\(maxAttempts): \(error.localizedDescription)")
                                    // 短い backoff: 0.5s, 1.0s
                                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                                }
                            }
                        }
                        if let imageURL = resolved {
                            if BackgroundDownloadManager.shared.isRateLimited(gid: gid) { return }
                            BackgroundDownloadManager.shared.enqueue(
                                url: imageURL, gid: gid, pageIndex: index, finalPath: filePath,
                                session: session, headers: ehHeaders
                            )
                            await enqueueStats.bump(gid: gid, page: index, urlTail: imageURL.absoluteString.suffix(60))
                        } else {
                            LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) URL解決失敗 (after \(maxAttempts) attempts): \(lastError?.localizedDescription ?? "?")")
                            // 全 retry 尽きたら 2ndpass に委譲 (ダミー enqueue で 1st pass stream に記録)
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
        // 田中要望 2026-04-27: 失敗してもやり直して .cortex 化 → 2nd→3rd→4thpass まで自動 retry
        if BackgroundDownloadManager.shared.isRateLimited(gid: gid) {
            LogManager.shared.log("Download", "gid=\(gid) 2ndpass SKIP: rate limited (BAN 中は再試行しない)")
        }
        let maxRetryPasses = 4  // 2nd / 3rd / 4thpass まで
        for passNum in 2...maxRetryPasses {
            // 直前 pass で残った失敗 + reconcile で取りこぼした未 DL を再構築
            for idx in 0..<totalPages where !state.downloadedSet.contains(idx) {
                if !state.failedPages.contains(where: { $0.index == idx }) {
                    state.failedPages.append((index: idx, pageURL: allPageURLs[idx]))
                }
            }
            let allFailed = state.failedPages.filter { !state.downloadedSet.contains($0.index) }
            if allFailed.isEmpty { break }
            if BackgroundDownloadManager.shared.isRateLimited(gid: gid) { break }
            if activeDownloads[gid]?.isCancelled == true { break }

            let failedPageNums = allFailed.map { $0.index + 1 }
            LogManager.shared.log("Download", "gid=\(gid) \(passNum)thpass START retry=\(failedPageNums) (5s wait)")
            // UI: 「別ミラーから再試行中」に切替 (info マーク表示用)
            updatePhase(gid: gid, phase: .retrying)
            // 5s 待機中に cancelDownload されたら即脱出（小刻みに分割してチェック）
            for _ in 0..<10 {
                if activeDownloads[gid]?.isCancelled == true { break }
                await SafetyMode.shared.delay(nanoseconds: 500_000_000)
            }

            // 並列度 5 で retry pass を回す (TaskGroup、常時 5 枚分の download を並走)
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
                            LogManager.shared.log("Download", "gid=\(gid) page \(index + 1) already on disk, skip pass \(passNum)")
                            continue
                        }
                        LogManager.shared.log("Download", "gid=\(gid) \(passNum)thpass page \(index + 1) start url=\(pageURL.absoluteString.suffix(60))")
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

                // 初期スロット埋め (最大 5)
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
                            // 速度表示用: retry pass は delegate 経由で bytes が届かないため
                            // ファイルサイズを直接累積へ加算する
                            let filePath = imageFilePath(gid: gid, page: index)
                            if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path),
                               let size = attrs[.size] as? Int64 {
                                BackgroundDownloadManager.shared.addCumulativeBytes(gid: gid, bytes: size)
                            }
                            updateProgress(gid: gid, current: state.downloadedSet.count, total: totalPages)
                            LogManager.shared.log("Download", "gid=\(gid) \(passNum)thpass page \(index + 1) OK")
                        } else {
                            LogManager.shared.log("Download", "gid=\(gid) \(passNum)thpass page \(index + 1)/\(totalPages) failed")
                        }
                    }
                    if activeDownloads[gid]?.isCancelled == true { continue }
                    _ = enqueueNext()
                }
            }
            LogManager.shared.log("Download", "gid=\(gid) \(passNum)thpass END: done=\(state.downloadedSet.count)/\(totalPages)")

            // この pass で 1 枚も進捗が無ければ次の pass を回しても無駄なので break
            let stillMissing = (0..<totalPages).filter { !state.downloadedSet.contains($0) }
            if stillMissing.isEmpty { break }
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

        // 田中要望 2026-04-26: 完了後 staging → NAS bulk move (background)
        // 田中要望 2026-04-27: retry を尽くしても failed page が残っても、
        //   1 枚以上 DL 済みなら partial finalize で .cortex 化する (途中状態でも救済)。
        // 田中要望 2026-04-27 (2): cancel/delete された gid は finalize しない (zombie 防止)
        let hasAnyDownloaded = state.downloadedSet.count > 0
        let wasCancelled = activeDownloads[gid]?.isCancelled == true || (downloads[gid]?.isCancelled ?? false) || recentlyDeletedGids.contains(gid)
        if hasAnyDownloaded && isStaging(gid: gid) && !wasCancelled {
            if !completed {
                let missing = (0..<totalPages).filter { !state.downloadedSet.contains($0) }.map { $0 + 1 }
                LogManager.shared.log("Download", "gid=\(gid) partial finalize: \(state.downloadedSet.count)/\(totalPages) (missing=\(missing.prefix(20))\(missing.count > 20 ? "..." : ""))")
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.moveStagingToFinalDest(gid: gid)
            }
        } else if wasCancelled {
            LogManager.shared.log("Download", "gid=\(gid) finalize SKIPPED (cancelled/deleted)")
        }

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
        // 田中要望 2026-04-27: scan が baseDirectory のみで staging 中の作品を見逃す bug 修正。
        //   post-DL finalize は staging dir に居る間に走るので、staging path にも fallback。
        //   staging で見つかったら true、無ければ baseDirectory も走査する。
        let stagingDir = dlStagingBase.appendingPathComponent("\(gid)", isDirectory: true)
        if FileManager.default.fileExists(atPath: stagingDir.path),
           WebPAnimationDetector.directoryContainsAnimated(stagingDir) {
            return true
        }
        let baseDir = baseDirectory.appendingPathComponent("\(gid)", isDirectory: true)
        return WebPAnimationDetector.directoryContainsAnimated(baseDir)
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
