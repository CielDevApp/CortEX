import Foundation
import CryptoKit

/// 外部参照フォルダ配下のサブフォルダを scan し、各サブフォルダ = 1 作品として
/// DownloadedGallery 形式に変換する scanner (Phase E1, 2026-04-26)。
///
/// 設計書 docs/external_folder_import_design_20260425.md セクション 4 (案 C 確定) +
/// セクション 5 (metadata.json schema 流用 + 自動生成) + セクション 5-3 (.cortex_managed
/// 条件付き書込) に基づく。
///
/// gid namespace は Q-3 確定案 1: `Int.max - hash(folderPath)`。E-Hentai 正数 / nhentai 負数
/// と完全分離。`source = "external"` を明示してリーダー経路の分岐に使う (Step 8 で抽象化)。
///
/// 内部キャッシュ場所: `<documents>/EhViewer/external_meta_cache/<bookmark_id>.json` 配下に
/// folder ID 別 directory を作って各 gallery の metadata.json を保存。
enum ExternalGalleryScanner {

    // MARK: - Public API

    /// 1 つの外部フォルダ root URL を scan して中の作品リストを返す。
    /// access scope は caller 側 (ExternalFolderManager.accessFolder) で確保された前提。
    /// 失敗時は空配列を返し、ログのみ出力 (個別 gallery scan 失敗で全体停止しない方針)。
    ///
    /// 検出対象 (Phase E1.A 拡張):
    /// 1. サブフォルダ (= 1 作品、画像ファイル群を中に持つ前提)
    /// 2. `.cortex` ZIP ファイル (= 1 作品、ZIP 内 metadata.json を読む、Reader は ZIP streaming)
    ///
    /// - Parameters:
    ///   - rootURL: scan 対象のフォルダ (security-scoped access 中前提)
    ///   - bookmarkID: 内部キャッシュ用 ID (`.cortex_managed` 無し時の metadata 退避先)
    ///   - bookmarkData: Reader 経路から再 access するため ExternalCortexZipReader.register に渡す
    /// - Returns: 各サブフォルダ + .cortex から生成された DownloadedGallery 配列 (空可)
    static func scan(rootURL: URL, bookmarkID: UUID, bookmarkData: Data) -> [DownloadedGallery] {
        let fm = FileManager.default
        let isManaged = fm.fileExists(atPath: rootURL.appendingPathComponent(".cortex_managed").path)

        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            LogManager.shared.log("ExternalScan", "rootURL contentsOfDirectory failed: \(rootURL.path)")
            return []
        }

        var galleries: [DownloadedGallery] = []
        var subfolderCount = 0
        var zipCount = 0
        for entry in entries {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard exists else { continue }
            if isDir.boolValue {
                if let g = scanGalleryFolder(folderURL: entry, isManagedRoot: isManaged, bookmarkID: bookmarkID) {
                    galleries.append(g)
                    subfolderCount += 1
                }
            } else if entry.pathExtension.lowercased() == "cortex" {
                if let g = scanCortexZip(zipURL: entry, bookmarkData: bookmarkData) {
                    galleries.append(g)
                    zipCount += 1
                }
            }
        }
        LogManager.shared.log("ExternalScan", "rootURL=\(rootURL.lastPathComponent) found \(galleries.count) galleries (subfolder=\(subfolderCount), .cortex=\(zipCount), managed=\(isManaged))")
        return galleries
    }

    // MARK: - .cortex ZIP scan (Phase E1.A)

    /// 1 つの .cortex ZIP を 1 作品として認識。ZIP TOC から metadata.json を抽出して
    /// DownloadedGallery を生成、ExternalCortexZipReader に TOC を登録 (Reader 経路から再利用)。
    private static func scanCortexZip(zipURL: URL, bookmarkData: Data) -> DownloadedGallery? {
        guard let toc = ExternalCortexZipReader.readTOC(zipPath: zipURL) else {
            LogManager.shared.log("ExternalScan", "TOC read failed: \(zipURL.lastPathComponent)")
            return nil
        }

        // metadata.json を ZIP から取得 (.cortex 形式は metadata.json + page_NNNN + cover が標準)
        var meta: DownloadedGallery?
        if let metaEntry = toc["metadata.json"], let metaData = ExternalCortexZipReader.extractEntry(zipPath: zipURL, entry: metaEntry) {
            meta = try? JSONDecoder().decode(DownloadedGallery.self, from: metaData)
        }

        // metadata.json 無し or 解読失敗時は ZIP file 名から自動生成
        if meta == nil {
            let title = (zipURL.lastPathComponent as NSString).deletingPathExtension
            let imageEntries = toc.keys.filter { ($0 as NSString).lastPathComponent.lowercased().hasPrefix("page_") }.sorted()
            guard !imageEntries.isEmpty else {
                LogManager.shared.log("ExternalScan", "no images in zip: \(zipURL.lastPathComponent)")
                return nil
            }
            let gid = gidFromPath(zipURL.path)
            meta = DownloadedGallery(
                gid: gid, token: "external_zip", title: title, coverFileName: nil,
                pageCount: imageEntries.count, downloadDate: Date(), isComplete: true,
                downloadedPages: Array(0..<imageEntries.count), source: "external_zip",
                isCancelled: nil, hasAnimatedWebp: nil, readerModeOverride: nil, tags: nil
            )
        } else {
            // metadata.json から得た gid は元の DL 時の gid (E-Hentai 正数 / nhentai 負数)。
            // 外部 ZIP として参照する場合、内部 DL gid と衝突する可能性があるため
            // namespace を分離 (Q-3 案 1: Int.max - hash(zipPath))
            let newGid = gidFromPath(zipURL.path)
            meta = DownloadedGallery(
                gid: newGid,
                token: meta!.token,
                title: meta!.title,
                coverFileName: meta!.coverFileName,
                pageCount: meta!.pageCount,
                downloadDate: meta!.downloadDate,
                isComplete: true,
                downloadedPages: meta!.downloadedPages,
                source: "external_zip",
                isCancelled: nil,
                hasAnimatedWebp: meta!.hasAnimatedWebp,
                readerModeOverride: nil,
                tags: meta!.tags
            )
        }

        guard let final = meta else { return nil }

        // Reader 経路用に TOC を ExternalCortexZipReader に登録
        ExternalCortexZipReader.shared.register(gid: final.gid, bookmarkData: bookmarkData, zipPath: zipURL, toc: toc)

        return final
    }

    // MARK: - 1 サブフォルダの scan

    /// 1 サブフォルダを 1 gallery として認識。metadata.json があれば優先、無ければ自動生成。
    /// 自動生成の保存先は isManagedRoot で分岐 (`.cortex_managed` なら同フォルダに書き、
    /// 無ければ内部キャッシュへ退避)。
    private static func scanGalleryFolder(folderURL: URL, isManagedRoot: Bool, bookmarkID: UUID) -> DownloadedGallery? {
        let fm = FileManager.default
        let metaURL = folderURL.appendingPathComponent("metadata.json")

        // 1. metadata.json が同フォルダ直下にあれば優先 (export 形式 = DownloadedGallery 互換)
        if fm.fileExists(atPath: metaURL.path),
           let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(DownloadedGallery.self, from: data) {
            return meta
        }

        // 2. 内部キャッシュをチェック (`.cortex_managed` 無いフォルダ用)
        let cacheURL = internalCacheURL(bookmarkID: bookmarkID, folderName: folderURL.lastPathComponent)
        if fm.fileExists(atPath: cacheURL.path),
           let data = try? Data(contentsOf: cacheURL),
           let meta = try? JSONDecoder().decode(DownloadedGallery.self, from: data),
           isCacheStillValid(folder: folderURL, cache: cacheURL) {
            return meta
        }

        // 3. 自動生成
        guard let generated = synthesizeMetadata(folderURL: folderURL) else {
            LogManager.shared.log("ExternalScan", "synthesize failed: \(folderURL.lastPathComponent)")
            return nil
        }

        // 4. 保存先決定 (`.cortex_managed` で同フォルダ書込 or 内部キャッシュ)
        if let data = try? JSONEncoder().encode(generated) {
            if isManagedRoot {
                try? data.write(to: metaURL, options: .atomic)
            } else {
                try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        }

        return generated
    }

    // MARK: - 自動生成

    /// フォルダ内の画像ファイルを数えて DownloadedGallery を合成。
    /// gid = Int.max - hash(folderPath)、source = "external"、isComplete = true 固定。
    private static func synthesizeMetadata(folderURL: URL) -> DownloadedGallery? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else {
            return nil
        }
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
        let images = files
            .filter { imageExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !images.isEmpty else { return nil }

        let title = folderURL.lastPathComponent
        let gid = gidFromPath(folderURL.path)
        let cover = images.first?.lastPathComponent

        let addedDate: Date = {
            if let attrs = try? fm.attributesOfItem(atPath: folderURL.path),
               let d = attrs[.creationDate] as? Date {
                return d
            }
            return Date()
        }()

        return DownloadedGallery(
            gid: gid,
            token: "external",
            title: title,
            coverFileName: cover,
            pageCount: images.count,
            downloadDate: addedDate,
            isComplete: true,
            downloadedPages: Array(0..<images.count),
            source: "external",
            isCancelled: nil,
            hasAnimatedWebp: nil,
            readerModeOverride: nil,
            tags: nil
        )
    }

    // MARK: - gid 生成 (Int.max - hash、Q-3 案 1)

    private static func gidFromPath(_ path: String) -> Int {
        let digest = SHA256.hash(data: Data(path.utf8))
        // 上位 8 byte を Int64 に詰める → 絶対値 → Int.max - hash で正数 namespace 確保
        var hash: UInt64 = 0
        for b in digest.prefix(8) {
            hash = (hash << 8) | UInt64(b)
        }
        // Int.max(=Int64.max) からの差分にして既存 E-Hentai (小さい正数) / nhentai (負数) と分離
        // hash のオーバーラップ確率は SHA256 64bit prefix → 低い (再衝突時はフォルダ名 suffix で再 hash 推奨)
        let positive = Int(truncatingIfNeeded: hash & 0x7FFF_FFFF_FFFF_FFFF)
        return Int.max - positive
    }

    // MARK: - 内部キャッシュ

    private static func internalCacheURL(bookmarkID: UUID, folderName: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("EhViewer/external_meta_cache/\(bookmarkID.uuidString)/\(folderName).json")
    }

    /// folder の最終更新日時 (mtime) と cache の mtime を比較。folder の方が新しければ stale。
    private static func isCacheStillValid(folder: URL, cache: URL) -> Bool {
        let fm = FileManager.default
        guard let folderAttrs = try? fm.attributesOfItem(atPath: folder.path),
              let cacheAttrs = try? fm.attributesOfItem(atPath: cache.path),
              let folderMod = folderAttrs[.modificationDate] as? Date,
              let cacheMod = cacheAttrs[.modificationDate] as? Date else {
            return false
        }
        return cacheMod >= folderMod
    }
}
