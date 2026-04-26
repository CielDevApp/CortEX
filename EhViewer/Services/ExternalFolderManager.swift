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

    private let storageKey = "com.kanayayuutou.cortex.externalFolders"
    private let userDefaults: UserDefaults

    /// テスト容易性のため UserDefaults を inject 可能。デフォルトは .standard。
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
        // 起動時自動 scan (background、main thread をブロックしない)
        Task.detached { [weak self] in await self?.rescanAll() }
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
