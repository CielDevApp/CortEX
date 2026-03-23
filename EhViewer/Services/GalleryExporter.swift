import Foundation
import Compression
#if canImport(UIKit)
import UIKit
#endif
import zlib

/// ダウンロード済みギャラリーのエクスポート/インポート
enum GalleryExporter {

    // MARK: - エクスポート（フォルダ→ZIP→ShareSheet）

    /// ギャラリーフォルダをZIPにしてURLを返す
    static func exportAsZip(gid: Int) -> URL? {
        let dm = DownloadManager.shared
        let galleryDir = galleryDirectory(gid: gid)

        guard FileManager.default.fileExists(atPath: galleryDir.path) else {
            LogManager.shared.log("Export", "gallery \(gid) not found")
            return nil
        }

        // NSFileCoordinatorでフォルダをZIP化
        var zipURL: URL?
        var coordError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: galleryDir, options: .forUploading, error: &coordError) { tempZipURL in
            // 一時ZIPを永続的な場所にコピー
            let exportDir = FileManager.default.temporaryDirectory
            let title = dm.downloads[gid]?.title ?? "\(gid)"
            let safeName = title.replacingOccurrences(of: "/", with: "_").prefix(50)
            let destURL = exportDir.appendingPathComponent("\(safeName).cortex")
            try? FileManager.default.removeItem(at: destURL)
            try? FileManager.default.copyItem(at: tempZipURL, to: destURL)
            zipURL = destURL
        }

        if let error = coordError {
            LogManager.shared.log("Export", "zip failed: \(error)")
        }

        if let url = zipURL {
            LogManager.shared.log("Export", "exported gid=\(gid) → \(url.lastPathComponent)")
        }
        return zipURL
    }

    // MARK: - インポート（ZIP→フォルダ→DownloadManager登録）

    /// ZIPファイルからギャラリーをインポート。成功したらgidを返す
    static func importFromZip(url: URL) -> Int? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // ZIPを一時フォルダに展開
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(UUID().uuidString)", isDirectory: true)

        var success = false
        var coordError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { accessedURL in
            // ZIPを展開先にコピーしてから展開
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                // NSFileCoordinatorでZIPを展開
                var innerError: NSError?
                let innerCoord = NSFileCoordinator()
                innerCoord.coordinate(readingItemAt: accessedURL, options: .forUploading, error: &innerError) { _ in }
                // forUploadingは圧縮用なので展開には使えない

                // 代替: ZIPデータを読んで手動展開
                if let zipData = try? Data(contentsOf: accessedURL) {
                    success = extractZipManually(zipData: zipData, to: tempDir)
                }
            } catch {
                LogManager.shared.log("Export", "import failed: \(error)")
            }
        }

        guard success else {
            try? FileManager.default.removeItem(at: tempDir)
            return nil
        }

        // metadata.jsonを探してDownloadManagerに登録
        return registerImportedGallery(from: tempDir)
    }

    // MARK: - ZIP手動展開（zlib使用）

    private static func extractZipManually(zipData: Data, to destDir: URL) -> Bool {
        // ZIP End of Central Directory を探す
        let bytes = [UInt8](zipData)
        guard bytes.count > 22 else { return false }

        // EOCDシグネチャ 0x06054b50 を末尾から探す
        var eocdOffset = -1
        for i in stride(from: bytes.count - 22, through: max(0, bytes.count - 65536), by: -1) {
            if bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x05 && bytes[i+3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0 else { return false }

        let centralDirOffset = Int(readUInt32(bytes, at: eocdOffset + 16))
        let totalEntries = Int(readUInt16(bytes, at: eocdOffset + 10))

        var offset = centralDirOffset
        var extractedCount = 0

        for _ in 0..<totalEntries {
            guard offset + 46 <= bytes.count else { break }
            // Central Directory Header: 0x02014b50
            guard bytes[offset] == 0x50 && bytes[offset+1] == 0x4b && bytes[offset+2] == 0x01 && bytes[offset+3] == 0x02 else { break }

            let compMethod = Int(readUInt16(bytes, at: offset + 10))
            let compSize = Int(readUInt32(bytes, at: offset + 20))
            let uncompSize = Int(readUInt32(bytes, at: offset + 24))
            let nameLen = Int(readUInt16(bytes, at: offset + 28))
            let extraLen = Int(readUInt16(bytes, at: offset + 30))
            let commentLen = Int(readUInt16(bytes, at: offset + 32))
            let localHeaderOffset = Int(readUInt32(bytes, at: offset + 42))

            let nameBytes = Array(bytes[(offset+46)..<(offset+46+nameLen)])
            let fileName = String(bytes: nameBytes, encoding: .utf8) ?? ""

            offset += 46 + nameLen + extraLen + commentLen

            // ディレクトリはスキップ
            if fileName.hasSuffix("/") { continue }

            // Local File Headerからデータを読む
            let localOffset = localHeaderOffset
            guard localOffset + 30 <= bytes.count else { continue }
            let localNameLen = Int(readUInt16(bytes, at: localOffset + 26))
            let localExtraLen = Int(readUInt16(bytes, at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            guard dataStart + compSize <= bytes.count else { continue }

            let compData = Data(bytes[dataStart..<(dataStart + compSize)])

            let fileData: Data
            if compMethod == 0 {
                // Stored (無圧縮)
                fileData = compData
            } else if compMethod == 8 {
                // Deflate
                guard let decompressed = decompressDeflate(compData, expectedSize: uncompSize) else { continue }
                fileData = decompressed
            } else {
                continue // 未サポートの圧縮方式
            }

            // ファイルを書き出し
            let filePath = destDir.appendingPathComponent(fileName)
            let fileDir = filePath.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
            try? fileData.write(to: filePath)
            extractedCount += 1
        }

        LogManager.shared.log("Export", "extracted \(extractedCount) files from zip")
        return extractedCount > 0
    }

    private static func decompressDeflate(_ data: Data, expectedSize: Int) -> Data? {
        // zlib raw deflate decompression
        var destBuffer = [UInt8](repeating: 0, count: expectedSize)
        var sourceBuffer = [UInt8](data)
        var destLen = UInt(expectedSize)
        var sourceLen = UInt(data.count)

        // -15 = raw deflate (no header)
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer(mutating: sourceBuffer)
        stream.avail_in = UInt32(sourceLen)
        stream.next_out = UnsafeMutablePointer(mutating: &destBuffer)
        stream.avail_out = UInt32(destLen)

        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let result = inflate(&stream, Z_FINISH)
        guard result == Z_STREAM_END || result == Z_OK else { return nil }

        return Data(destBuffer.prefix(Int(stream.total_out)))
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset+1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset+1]) << 8) | (UInt32(bytes[offset+2]) << 16) | (UInt32(bytes[offset+3]) << 24)
    }

    // MARK: - 展開済みフォルダ登録

    private static func registerImportedGallery(from tempDir: URL) -> Int? {
        let fm = FileManager.default

        // metadata.jsonを探す（直下 or サブフォルダ内）
        var metadataURL: URL?
        var gallerySourceDir: URL?

        let metaDirect = tempDir.appendingPathComponent("metadata.json")
        if fm.fileExists(atPath: metaDirect.path) {
            metadataURL = metaDirect
            gallerySourceDir = tempDir
        } else {
            // サブフォルダを探す
            if let contents = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
                for item in contents {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                        let subMeta = item.appendingPathComponent("metadata.json")
                        if fm.fileExists(atPath: subMeta.path) {
                            metadataURL = subMeta
                            gallerySourceDir = item
                            break
                        }
                    }
                }
            }
        }

        guard let metaURL = metadataURL,
              let sourceDir = gallerySourceDir,
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(DownloadedGallery.self, from: metaData) else {
            LogManager.shared.log("Export", "import: no valid metadata.json found")
            try? fm.removeItem(at: tempDir)
            return nil
        }

        // DownloadManagerのダウンロードディレクトリにコピー
        let destDir = galleryDirectory(gid: meta.gid)
        try? fm.removeItem(at: destDir) // 既存があれば上書き
        try? fm.createDirectory(at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: sourceDir, to: destDir)
        } catch {
            LogManager.shared.log("Export", "import: copy failed: \(error)")
            try? fm.removeItem(at: tempDir)
            return nil
        }

        // DownloadManagerに登録
        let dm = DownloadManager.shared
        dm.downloads[meta.gid] = meta
        dm.lastImportedGid = meta.gid
        try? fm.removeItem(at: tempDir)

        LogManager.shared.log("Export", "imported gid=\(meta.gid) title=\(meta.title) pages=\(meta.downloadedPages.count)")
        return meta.gid
    }

    // MARK: - ヘルパー

    private static func galleryDirectory(gid: Int) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("EhViewer/downloads/\(gid)", isDirectory: true)
    }
}
