import Foundation
import Combine

/// 外部フォルダ参照型インポート (Phase E1, 2026-04-26) のフォルダ登録 / 永続化 manager。
/// SecurityScopedBookmark を使って User-chosen フォルダ URL を bookmark Data として
/// UserDefaults に保存し、再起動越しで access 可能にする。
///
/// 本 manager は **フォルダのリスト管理** だけを担当。フォルダ配下の作品 scan は
/// 後続の ExternalGalleryScanner.swift (Step 4) が担当。
///
/// Mac Catalyst での運用が前提 (`SettingsView` の Mac-only セクション or DownloadsView の
/// 外部参照 Section から add/remove)。Phase E2 で iPhone 対応検討時も同 API 流用可能。
@MainActor
final class ExternalFolderManager: ObservableObject {
    static let shared = ExternalFolderManager()

    /// 登録済みの外部フォルダリスト (UI が ForEach で表示する source of truth)。
    @Published private(set) var folders: [ExternalFolder] = []

    /// 全外部フォルダを scan した結果の作品リスト (DownloadedGallery 形式、source = "external")。
    /// 起動時 + folder 追加/削除時 + 明示 rescanAll() で更新。
    /// DownloadsView の「外部参照」Section が ForEach で表示する source of truth。
    @Published private(set) var externalGalleries: [DownloadedGallery] = []

    /// 最終 scan 日時 (UI で「最終更新」表示用、nil = 未 scan)。
    @Published private(set) var lastScanAt: Date?

    /// scan 失敗した (= bookmark resolve 失敗 or NAS 切断) folder ID 集合。
    /// DownloadsView の Section に「NAS 未接続」バナー表示用 (Q-C 確定)。
    @Published private(set) var disconnectedFolderIDs: Set<UUID> = []

    /// 田中要望 2026-04-26: rescan 後の cover 一括 pre-warm 中フラグ。
    /// DownloadsView の Library Section ヘッダで「読み込み中...」表示用。
    @Published private(set) var isWarmingCovers: Bool = false
    @Published private(set) var warmCoverCurrent: Int = 0
    @Published private(set) var warmCoverTotal: Int = 0

    /// 田中要望 2026-04-26: 「一覧から削除」した gid 集合 (NAS 実 .cortex は残す)。
    /// gid は zipPath の SHA256 hash で stable なので rescan 後も同 gid に解決される。
    /// UserDefaults 永続化。
    @Published private(set) var hiddenExternalGids: Set<Int> = []

    /// 田中要望 2026-04-26: 外部参照 section のソート方式。UserDefaults 永続化。
    enum ExternalSortOrder: String, Codable, CaseIterable {
        case dateAdded   // 追加日 (downloadDate) 降順
        case nameAsc     // 名前 (title) 昇順
        case nameDesc    // 名前 (title) 降順
    }
    @Published var externalSortOrder: ExternalSortOrder = .dateAdded {
        didSet { userDefaults.set(externalSortOrder.rawValue, forKey: sortOrderKey) }
    }

    /// Step 9 (Phase E1, 2026-04-26): Mac DL 保存先選択。
    /// nil = デフォルト (`<documents>/EhViewer/downloads`)、非 nil = ユーザ指定 NAS フォルダ等。
    /// 起動時 long-running startAccessingSecurityScopedResource() で URL を保持、
    /// app 終了まで access scope を維持 (DL 中の長期書込に対応)。
    @Published private(set) var activeDLSaveDestinationURL: URL?

    /// DL 保存先 bookmark の resolve に失敗した (NAS unmount 等)。UI で warning 表示用。
    @Published private(set) var dlSaveDestinationStale: Bool = false

    /// DL 保存先の表示用パス (UI で「現在のパス」表示用、bookmark 未設定時 nil)。
    @Published private(set) var dlSaveDestinationDisplayPath: String?

    private let storageKey = "com.kanayayuutou.cortex.externalFolders"
    private let dlSaveDestKey = "com.kanayayuutou.cortex.dlSaveDestination"
    private let hiddenGidsKey = "com.kanayayuutou.cortex.hiddenExternalGids"
    private let sortOrderKey = "com.kanayayuutou.cortex.externalSortOrder"
    private let userDefaults: UserDefaults

    /// テスト容易性のため UserDefaults を inject 可能。デフォルトは .standard。
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
        loadDLSaveDestination()
        loadHiddenGids()
        loadSortOrder()
        // 起動時自動 scan (background、main thread をブロックしない)
        Task.detached { [weak self] in await self?.rescanAll() }
    }

    private func loadHiddenGids() {
        guard let arr = userDefaults.array(forKey: hiddenGidsKey) as? [Int] else { return }
        hiddenExternalGids = Set(arr)
    }

    private func saveHiddenGids() {
        userDefaults.set(Array(hiddenExternalGids), forKey: hiddenGidsKey)
    }

    /// 一覧から削除 (NAS 実 .cortex は触らない、表示のみ非表示)。
    func hideExternal(gid: Int) {
        hiddenExternalGids.insert(gid)
        saveHiddenGids()
    }

    /// 表示復活 (将来の UI 用、今夜未使用)。
    func unhideExternal(gid: Int) {
        hiddenExternalGids.remove(gid)
        saveHiddenGids()
    }

    private func loadSortOrder() {
        if let raw = userDefaults.string(forKey: sortOrderKey),
           let val = ExternalSortOrder(rawValue: raw) {
            externalSortOrder = val
        }
    }

    // MARK: - 登録 / 削除

    /// User が fileImporter で選択した URL を bookmark 化して保存。
    /// displayName 省略時は URL.lastPathComponent を使用。
    /// SecurityScopedBookmark.create が throw する error はそのまま rethrow。
    func add(url: URL, displayName: String? = nil) throws {
        let data = try SecurityScopedBookmark.create(from: url)
        let folder = ExternalFolder(
            id: UUID(),
            displayName: displayName ?? url.lastPathComponent,
            bookmarkData: data,
            addedAt: Date()
        )
        folders.append(folder)
        save()
        // 追加 folder を即 scan して externalGalleries に反映
        Task { await rescanAll() }
    }

    /// 指定 ID の登録を削除。bookmark Data を捨てるだけで実フォルダには触らない。
    func remove(id: UUID) {
        folders.removeAll { $0.id == id }
        save()
        // 削除した folder の作品も externalGalleries から除外
        Task { await rescanAll() }
    }

    // MARK: - 全フォルダ scan

    /// 登録済みの全外部フォルダを scan して externalGalleries に flatten。
    /// SMB 越し IO で main thread が blocked しないよう、scan 本体は detached task で実行。
    /// @Published の代入のみ main actor に戻して行う。
    /// failure は個別 folder 単位で吸収 (1 folder の失敗で全体停止しない)。
    func rescanAll() async {
        // main actor で folders snapshot 取得 (Sendable な ExternalFolder は detached に渡せる)
        let snapshot = folders
        // 前回登録分を一度全クリア (rescan で消えた gallery が残らないように)
        ExternalCortexZipReader.shared.unregisterAll()

        let result: (galleries: [DownloadedGallery], disconnected: Set<UUID>) = await Task.detached {
            var galleries: [DownloadedGallery] = []
            var disconnected: Set<UUID> = []
            for folder in snapshot {
                do {
                    let scanned: [DownloadedGallery] = try SecurityScopedBookmark.access(folder.bookmarkData) { url in
                        return ExternalGalleryScanner.scan(rootURL: url, bookmarkID: folder.id, bookmarkData: folder.bookmarkData)
                    }
                    galleries.append(contentsOf: scanned)
                } catch {
                    LogManager.shared.log("ExternalScan", "folder \(folder.displayName) scan failed: \(error)")
                    disconnected.insert(folder.id)
                }
            }
            return (galleries, disconnected)
        }.value
        // @Published 更新は main actor で
        externalGalleries = result.galleries
        disconnectedFolderIDs = result.disconnected
        lastScanAt = Date()
        LogManager.shared.log("ExternalScan", "rescanAll done, total \(result.galleries.count) galleries (disconnected=\(result.disconnected.count))")

        // 田中要望 2026-04-26: scan 後に cover (page 0) を background sequential pre-warm。
        // Library tab を初回開く時の thumb cell トリガ storm を回避、UI freeze 防止。
        await warmCovers(galleries: result.galleries)
    }

    /// rescan 後の cover 一括 pre-warm。各 gallery の page 0 を sequential materialize。
    /// 既に cache hit なら no-op で速い、miss なら SMB IO + ZIP extract。
    /// 進捗は @Published で UI に通知、Library Section に loading indicator 表示。
    private func warmCovers(galleries: [DownloadedGallery]) async {
        let externalOnly = galleries.filter { $0.source == "external_zip" }
        guard !externalOnly.isEmpty else { return }
        isWarmingCovers = true
        warmCoverCurrent = 0
        warmCoverTotal = externalOnly.count

        let snapshot = externalOnly
        await Task.detached {
            for (i, meta) in snapshot.enumerated() {
                _ = ExternalCortexZipReader.shared.materializedImageURL(gid: meta.gid, page: 0)
                await MainActor.run { ExternalFolderManager.shared.warmCoverCurrent = i + 1 }
            }
        }.value
        isWarmingCovers = false
        LogManager.shared.log("ExternalScan", "cover warm done: \(externalOnly.count) galleries")
    }

    // MARK: - access (短命)

    /// 指定 ID のフォルダに access して block を実行 (RAII)。
    /// SecurityScopedBookmark.access で startAccessing → block → stopAccessing を guarantee。
    /// stale bookmark 等の error はそのまま throw、UI 側で alert 表示推奨。
    @discardableResult
    func accessFolder<T>(id: UUID, _ block: (URL) throws -> T) throws -> T {
        guard let folder = folders.first(where: { $0.id == id }) else {
            throw FolderError.notFound(id: id)
        }
        return try SecurityScopedBookmark.access(folder.bookmarkData, block)
    }

    // MARK: - 永続化

    private func save() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }
        guard let decoded = try? JSONDecoder().decode([ExternalFolder].self, from: data) else { return }
        folders = decoded
    }

    // MARK: - DL 保存先選択 (Step 9, Mac Catalyst のみで実機能)

    /// User-chosen folder URL を DL 保存先として永続化 + 即時 access 開始。
    /// 既存 long-running access があれば stop してから新 URL を start。
    /// 失敗時は throw、UI で alert + 旧設定維持。
    /// 田中判断 2026-04-26 Q-2: 既存 DL は旧パスに残る (移動しない)。
    /// アプリ再起動で DownloadManager.baseDirectory に反映される (DL 中の path 切替は安全に出来ないため)。
    func setDLSaveDestination(url: URL) throws {
        // 既存 access を stop
        if let existing = activeDLSaveDestinationURL {
            existing.stopAccessingSecurityScopedResource()
        }
        // 新 URL を bookmark 化 + 即 long-running access
        let data = try SecurityScopedBookmark.create(from: url)
        userDefaults.set(data, forKey: dlSaveDestKey)
        // resolve + start
        let resolved = try SecurityScopedBookmark.resolve(data)
        if resolved.startAccessingSecurityScopedResource() {
            activeDLSaveDestinationURL = resolved
            dlSaveDestinationDisplayPath = resolved.path
            dlSaveDestinationStale = false
        } else {
            activeDLSaveDestinationURL = nil
            dlSaveDestinationStale = true
            throw SecurityScopedBookmark.BookmarkError.startAccessFailed
        }
        LogManager.shared.log("DLSaveDest", "set: \(resolved.path)")
    }

    /// DL 保存先設定をクリア (デフォルト `<documents>/EhViewer/downloads` に戻す)。
    func clearDLSaveDestination() {
        if let existing = activeDLSaveDestinationURL {
            existing.stopAccessingSecurityScopedResource()
        }
        activeDLSaveDestinationURL = nil
        dlSaveDestinationDisplayPath = nil
        dlSaveDestinationStale = false
        userDefaults.removeObject(forKey: dlSaveDestKey)
        LogManager.shared.log("DLSaveDest", "cleared (default に復帰)")
    }

    /// 起動時 / 設定変更時の DL 保存先 bookmark 読み込み + long-running access 開始。
    /// 失敗 (stale 等) 時は activeDLSaveDestinationURL = nil + stale flag set、
    /// DownloadManager は default にfallback。
    private func loadDLSaveDestination() {
        guard let data = userDefaults.data(forKey: dlSaveDestKey) else {
            return  // 未設定 = デフォルト使用
        }
        do {
            let url = try SecurityScopedBookmark.resolve(data)
            if url.startAccessingSecurityScopedResource() {
                activeDLSaveDestinationURL = url
                dlSaveDestinationDisplayPath = url.path
                dlSaveDestinationStale = false
                LogManager.shared.log("DLSaveDest", "loaded: \(url.path)")
            } else {
                dlSaveDestinationStale = true
                dlSaveDestinationDisplayPath = "(NAS 未接続)"
                LogManager.shared.log("DLSaveDest", "startAccessing failed, fallback to default")
            }
        } catch {
            dlSaveDestinationStale = true
            dlSaveDestinationDisplayPath = "(bookmark 解決失敗)"
            LogManager.shared.log("DLSaveDest", "resolve failed: \(error), fallback to default")
        }
    }

    // MARK: - エラー

    enum FolderError: Error {
        case notFound(id: UUID)
    }
}

// MARK: - Model

/// 外部参照フォルダ 1 件のメタデータ。Codable で UserDefaults に JSON 保存。
struct ExternalFolder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
    var addedAt: Date
}
