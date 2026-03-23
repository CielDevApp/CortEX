import Foundation

/// お気に入りバックアップ（エクスポート/インポート）
enum FavoritesBackup {

    struct BackupEntry: Codable {
        let gid: Int
        let token: String
        let title: String
        let category: String?
        let uploader: String?
        let pageCount: Int
        let rating: Double
        let coverURL: String?
        let galleryURL: String
        let source: String?  // "ehentai" or "nhentai"（nilは旧データ=ehentai）
    }

    struct BackupFile: Codable {
        let exportDate: String
        let count: Int
        let entries: [BackupEntry]
        let nhentaiEntries: [NhBackupEntry]?  // nhentaiお気に入り（オプショナルで旧データ互換）
    }

    /// nhentai用バックアップエントリ
    struct NhBackupEntry: Codable {
        let id: Int
        let mediaId: String
        let titleEnglish: String?
        let titleJapanese: String?
        let titlePretty: String?
        let numPages: Int
        let tags: [String]?  // タグ名のリスト
    }

    // MARK: - エクスポート

    /// お気に入り全件をJSONファイルにエクスポートし、ファイルURLを返す
    static func export() -> URL? {
        let galleries = FavoritesCache.shared.load()
        let nhGalleries = NhentaiFavoritesCache.shared.load()

        guard !galleries.isEmpty || !nhGalleries.isEmpty else { return nil }

        // E-Hentaiエントリ
        let entries = galleries.map { g in
            BackupEntry(
                gid: g.gid,
                token: g.token,
                title: g.title,
                category: g.category?.rawValue,
                uploader: g.uploader,
                pageCount: g.pageCount,
                rating: g.rating,
                coverURL: g.coverURL?.absoluteString,
                galleryURL: "https://exhentai.org/g/\(g.gid)/\(g.token)/",
                source: "ehentai"
            )
        }

        // nhentaiエントリ
        let nhEntries = nhGalleries.map { g in
            NhBackupEntry(
                id: g.id,
                mediaId: g.media_id,
                titleEnglish: g.title.english,
                titleJapanese: g.title.japanese,
                titlePretty: g.title.pretty,
                numPages: g.num_pages,
                tags: g.tags?.map(\.name)
            )
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())

        let backup = BackupFile(
            exportDate: dateStr,
            count: entries.count + nhEntries.count,
            entries: entries,
            nhentaiEntries: nhEntries.isEmpty ? nil : nhEntries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(backup) else { return nil }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CortEX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileName = "favorites_backup_\(dateStr).json"
        let fileURL = dir.appendingPathComponent(fileName)
        try? data.write(to: fileURL)

        UserDefaults.standard.set(true, forKey: "phoenixBackupDone")
        LogManager.shared.log("App", "phoenix export: \(entries.count) E-H + \(nhEntries.count) nhentai → \(fileName)")
        return fileURL
    }

    /// バックアップ済みかどうか
    static var hasBackup: Bool {
        UserDefaults.standard.bool(forKey: "phoenixBackupDone")
    }

    // MARK: - インポート

    /// バックアップJSONからお気に入りキャッシュにマージ。追加件数を返す
    static func importBackup(from url: URL) -> Int {
        // セキュリティスコープアクセス
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let backup = try? JSONDecoder().decode(BackupFile.self, from: data) else {
            LogManager.shared.log("App", "phoenix import: failed to read/decode file")
            return 0
        }

        var totalAdded = 0

        // E-Hentaiお気に入り復元
        var existing = FavoritesCache.shared.load()
        let existingGids = Set(existing.map(\.gid))
        var ehAdded = 0

        for entry in backup.entries {
            if existingGids.contains(entry.gid) { continue }

            let gallery = Gallery(
                gid: entry.gid,
                token: entry.token,
                title: entry.title,
                category: entry.category.flatMap { GalleryCategory(rawValue: $0) },
                coverURL: entry.coverURL.flatMap { URL(string: $0) },
                rating: entry.rating,
                pageCount: entry.pageCount,
                postedDate: "",
                uploader: entry.uploader,
                tags: []
            )
            existing.append(gallery)
            ehAdded += 1
        }

        if ehAdded > 0 {
            FavoritesCache.shared.save(existing)
        }
        totalAdded += ehAdded

        // nhentaiお気に入り復元
        if let nhEntries = backup.nhentaiEntries, !nhEntries.isEmpty {
            var nhExisting = NhentaiFavoritesCache.shared.load()
            let nhExistingIds = Set(nhExisting.map(\.id))
            var nhAdded = 0

            for entry in nhEntries {
                if nhExistingIds.contains(entry.id) { continue }

                let gallery = NhentaiClient.NhGallery(
                    id: entry.id,
                    media_id: entry.mediaId,
                    title: NhentaiClient.NhTitle(
                        english: entry.titleEnglish,
                        japanese: entry.titleJapanese,
                        pretty: entry.titlePretty
                    ),
                    images: NhentaiClient.NhImages(pages: [], cover: nil, thumbnail: nil),
                    num_pages: entry.numPages,
                    tags: nil
                )
                nhExisting.append(gallery)
                nhAdded += 1
            }

            if nhAdded > 0 {
                NhentaiFavoritesCache.shared.save(nhExisting)
            }
            totalAdded += nhAdded
            LogManager.shared.log("App", "phoenix import: E-H +\(ehAdded), nhentai +\(nhAdded) (total: \(existing.count) E-H, \(nhExisting.count) nh)")
        } else {
            LogManager.shared.log("App", "phoenix import: E-H +\(ehAdded) (total: \(existing.count), skipped: \(backup.entries.count - ehAdded) duplicates)")
        }

        return totalAdded
    }
}
