import Foundation

/// User が fileImporter で選択したフォルダ URL を、再起動越しで access するための
/// security-scoped bookmark wrapper。Phase E1 (2026-04-26) で新設、外部フォルダ参照
/// インポート + Mac DL 保存先選択の共通基盤。
///
/// 既存の `startAccessingSecurityScopedResource` は in-flight 利用のみ
/// (SettingsView.swift:839, GalleryExporter.swift:137, FavoritesBackup.swift:113)、
/// `bookmarkData` / `resolvingBookmark` の永続化使用は本ファイル新設まで存在しなかった。
///
/// Mac Catalyst の `.withSecurityScope` option は実装時に動作検証必要 (Apple doc では
/// 利用可能とされるが Catalyst 経路の挙動は未確認)。
enum SecurityScopedBookmark {

    enum BookmarkError: Error {
        case createFailed(Error)
        case resolveFailed(Error)
        /// bookmark Data の resolved URL が stale (元 path 移動 / 削除等)。
        /// caller 側で fileImporter から再取得 + create() で再生成必要。
        case staleNeedsRefresh
        /// startAccessingSecurityScopedResource() が false を返した。
        case startAccessFailed
    }

    // MARK: - 生成 (永続化用 Data 取得)

    /// User-chosen URL から bookmark Data を生成。
    /// 呼び出し側で必要なら startAccessingSecurityScopedResource() 済み状態で渡す
    /// (UIDocumentPickerViewController 経由の URL は通常そのまま bookmarkData 化可能)。
    static func create(from url: URL) throws -> Data {
        do {
            #if targetEnvironment(macCatalyst)
            let opts: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
            let opts: URL.BookmarkCreationOptions = []
            #endif
            return try url.bookmarkData(
                options: opts,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkError.createFailed(error)
        }
    }

    // MARK: - 解決 (永続化された Data から URL 復元)

    /// 永続化された bookmark Data から URL を復元。stale なら staleNeedsRefresh を throw。
    /// 解決成功時、URL はまだ access 開始されていない状態で返る (caller 側で
    /// startAccessingSecurityScopedResource() を呼ぶ必要あり)。短命 access には access(_:_:) helper 推奨。
    static func resolve(_ data: Data) throws -> URL {
        var stale = false
        do {
            #if targetEnvironment(macCatalyst)
            let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let opts: URL.BookmarkResolutionOptions = []
            #endif
            let url = try URL(
                resolvingBookmarkData: data,
                options: opts,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                throw BookmarkError.staleNeedsRefresh
            }
            return url
        } catch let e as BookmarkError {
            throw e
        } catch {
            throw BookmarkError.resolveFailed(error)
        }
    }

    // MARK: - 短命 access helper (RAII)

    /// bookmark から URL 解決 → access 開始 → block 実行 → access 終了 を RAII で wrap。
    /// block 内で URL を escape (例: 非同期 Task 起動) する場合は本 helper では不適、
    /// caller 側で resolve() + startAccessingSecurityScopedResource() を別途管理。
    @discardableResult
    static func access<T>(_ data: Data, _ block: (URL) throws -> T) throws -> T {
        let url = try resolve(data)
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.startAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try block(url)
    }
}
