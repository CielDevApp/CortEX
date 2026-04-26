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

    private let storageKey = "com.kanayayuutou.cortex.externalFolders"
    private let userDefaults: UserDefaults

    /// テスト容易性のため UserDefaults を inject 可能。デフォルトは .standard。
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
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
    }

    /// 指定 ID の登録を削除。bookmark Data を捨てるだけで実フォルダには触らない。
    func remove(id: UUID) {
        folders.removeAll { $0.id == id }
        save()
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
