import Foundation
import Compression
#if canImport(UIKit)
import UIKit
#endif
import zlib

/// ダウンロード済みギャラリーのエクスポート/インポート
enum GalleryExporter {

    // MARK: - 古い .cortex の自動掃除

    /// tmp 配下の古い .cortex を削除する（起動時に呼ぶ）
    /// エクスポート→共有後は残す意味が無い大容量ファイルなので、前回以前のものは消す。
    /// import 用の tmp ファイルも (import_<UUID>) 対象に含む。
    static func cleanupOldExportFiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var totalFreed: Int64 = 0
        var removedCount = 0
        for url in items {
            let isCortex = url.pathExtension == "cortex"
            let isImportTmp = url.lastPathComponent.hasPrefix("import_")
            guard isCortex || isImportTmp else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? FileManager.default.removeItem(at: url)) != nil {
                totalFreed += Int64(size)
                removedCount += 1
            }
        }
        if removedCount > 0 {
            LogManager.shared.log("Export", "cleanupOldExportFiles: removed \(removedCount) files, freed \(totalFreed / 1024 / 1024)MB")
        }
    }

    // MARK: - エクスポート（フォルダ→ZIP→ShareSheet）

    /// ギャラリーフォルダをZIPにしてURLを返す
    static func exportAsZip(gid: Int) -> URL? {
        LogManager.shared.log("Export", "exportAsZip ENTER gid=\(gid) mainThread=\(Thread.isMainThread)")
        // 毎回エクスポート前に古いファイルを掃除（増殖を抑える）
        cleanupOldExportFiles()
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
        let coordStart = Date()
        LogManager.shared.log("Export", "coordinate START gid=\(gid) mainThread=\(Thread.isMainThread)")
        coordinator.coordinate(readingItemAt: galleryDir, options: .forUploading, error: &coordError) { tempZipURL in
            LogManager.shared.log("Export", "coordinate closure gid=\(gid) mainThread=\(Thread.isMainThread) elapsed=\(Int(Date().timeIntervalSince(coordStart) * 1000))ms")
            // 一時ZIPを永続的な場所にコピー
            let exportDir = FileManager.default.temporaryDirectory
            let title = dm.downloads[gid]?.title ?? "\(gid)"
            let safeName = title.replacingOccurrences(of: "/", with: "_").prefix(50)
            let destURL = exportDir.appendingPathComponent("\(safeName).cortex")
            try? FileManager.default.removeItem(at: destURL)
            let copyStart = Date()
            try? FileManager.default.copyItem(at: tempZipURL, to: destURL)
            LogManager.shared.log("Export", "copy done gid=\(gid) copyMs=\(Int(Date().timeIntervalSince(copyStart) * 1000))")
            zipURL = destURL
        }
        LogManager.shared.log("Export", "coordinate END gid=\(gid) totalMs=\(Int(Date().timeIntervalSince(coordStart) * 1000))")

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

                // FileHandle + streaming で展開 (4GB超えの .cortex にも対応)
                success = extractZipStreaming(from: accessedURL, to: tempDir)
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

    // MARK: - ZIP streaming 展開 (大容量対応、ZIP64 サポート)

    /// FileHandle でシークしながら展開。メモリピークは展開中の1ファイル分だけ。
    /// ZIP64 (>4GB) もサポート。従来の extractZipManually は使わず、こちらに統一。
    private static func extractZipStreaming(from zipURL: URL, to destDir: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: zipURL) else {
            LogManager.shared.log("Export", "FileHandle open failed")
            return false
        }
        defer { try? fh.close() }

        let fileSize: UInt64
        do { fileSize = try fh.seekToEnd() } catch {
            LogManager.shared.log("Export", "seekToEnd failed: \(error)")
            return false
        }

        // 末尾 64KB+22B を読んで EOCD (End of Central Directory) を探す
        let tailSize: UInt64 = min(65557, fileSize)
        let tailStart = fileSize - tailSize
        do { try fh.seek(toOffset: tailStart) } catch { return false }
        guard let tail = try? fh.read(upToCount: Int(tailSize)), tail.count >= 22 else {
            LogManager.shared.log("Export", "tail read failed")
            return false
        }

        var eocdRel: Int = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50 && tail[i+1] == 0x4b && tail[i+2] == 0x05 && tail[i+3] == 0x06 {
                eocdRel = i
                break
            }
            i -= 1
        }
        guard eocdRel >= 0 else {
            LogManager.shared.log("Export", "EOCD signature not found")
            return false
        }

        // EOCD fields (32bit 上限で capped の場合 ZIP64 を参照)
        var totalEntries = UInt64(readU16(tail, at: eocdRel + 10))
        var cdSize = UInt64(readU32(tail, at: eocdRel + 12))
        var cdOffset = UInt64(readU32(tail, at: eocdRel + 16))

        if cdOffset == 0xFFFFFFFF || totalEntries == 0xFFFF || cdSize == 0xFFFFFFFF {
            // ZIP64: EOCD の直前 (20B前) に Locator
            guard eocdRel >= 20 else { return false }
            let loc = eocdRel - 20
            guard tail[loc] == 0x50 && tail[loc+1] == 0x4b && tail[loc+2] == 0x06 && tail[loc+3] == 0x07 else {
                LogManager.shared.log("Export", "ZIP64 locator not found (EOCD says ZIP64 required)")
                return false
            }
            let z64EocdOff = readU64(tail, at: loc + 8)
            do { try fh.seek(toOffset: z64EocdOff) } catch { return false }
            guard let z64 = try? fh.read(upToCount: 56), z64.count >= 56 else { return false }
            guard z64[0] == 0x50 && z64[1] == 0x4b && z64[2] == 0x06 && z64[3] == 0x06 else {
                LogManager.shared.log("Export", "ZIP64 EOCD signature invalid")
                return false
            }
            totalEntries = readU64(z64, at: 32)
            cdSize = readU64(z64, at: 40)
            cdOffset = readU64(z64, at: 48)
        }

        LogManager.shared.log("Export", "ZIP size=\(fileSize) CD@\(cdOffset) size=\(cdSize) entries=\(totalEntries)")

        // Central Directory をまとめ読み (通常 MB単位に収まる)
        do { try fh.seek(toOffset: cdOffset) } catch { return false }
        guard let cd = try? fh.read(upToCount: Int(cdSize)), UInt64(cd.count) == cdSize else {
            LogManager.shared.log("Export", "CD read failed (got \(cdSize > 0 ? "partial" : "none"))")
            return false
        }

        var offset = 0
        var extractedCount = 0
        for _ in 0..<Int(totalEntries) {
            guard offset + 46 <= cd.count else { break }
            guard cd[offset] == 0x50 && cd[offset+1] == 0x4b && cd[offset+2] == 0x01 && cd[offset+3] == 0x02 else { break }

            let compMethod = Int(readU16(cd, at: offset + 10))
            var compSize: UInt64 = UInt64(readU32(cd, at: offset + 20))
            var uncompSize: UInt64 = UInt64(readU32(cd, at: offset + 24))
            let nameLen = Int(readU16(cd, at: offset + 28))
            let extraLen = Int(readU16(cd, at: offset + 30))
            let commentLen = Int(readU16(cd, at: offset + 32))
            var localHeaderOffset: UInt64 = UInt64(readU32(cd, at: offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLen <= cd.count else { break }
            let fileName = String(data: cd.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) ?? ""

            // ZIP64 extra field (tag 0x0001)
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                let extraStart = nameStart + nameLen
                var ePos = 0
                while ePos + 4 <= extraLen {
                    let tag = readU16(cd, at: extraStart + ePos)
                    let size = Int(readU16(cd, at: extraStart + ePos + 2))
                    if tag == 0x0001 {
                        var fp = extraStart + ePos + 4
                        if uncompSize == 0xFFFFFFFF { uncompSize = readU64(cd, at: fp); fp += 8 }
                        if compSize == 0xFFFFFFFF { compSize = readU64(cd, at: fp); fp += 8 }
                        if localHeaderOffset == 0xFFFFFFFF { localHeaderOffset = readU64(cd, at: fp); fp += 8 }
                        break
                    }
                    ePos += 4 + size
                }
            }

            offset = nameStart + nameLen + extraLen + commentLen

            if fileName.hasSuffix("/") { continue }

            // Local File Header を読んで実データの開始オフセット計算
            do { try fh.seek(toOffset: localHeaderOffset) } catch { continue }
            guard let localHdr = try? fh.read(upToCount: 30), localHdr.count >= 30 else { continue }
            let localNameLen = Int(readU16(localHdr, at: 26))
            let localExtraLen = Int(readU16(localHdr, at: 28))
            let dataStart = localHeaderOffset + 30 + UInt64(localNameLen) + UInt64(localExtraLen)

            autoreleasepool {
                // 圧縮データを chunk-wise に inflate しつつ destFH に直接書く
                // メモリピークは chunk サイズ (256KB) × 2 程度に抑える想定
                do { try fh.seek(toOffset: dataStart) } catch { return }

                let filePath = destDir.appendingPathComponent(fileName)
                let fileDir = filePath.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: filePath.path, contents: nil)
                guard let destFH = try? FileHandle(forWritingTo: filePath) else { return }
                defer { try? destFH.close() }

                let ok = streamInflateEntry(
                    sourceFH: fh,
                    destFH: destFH,
                    compSize: compSize,
                    uncompSize: uncompSize,
                    compMethod: compMethod
                )
                if !ok {
                    try? FileManager.default.removeItem(at: filePath)
                    LogManager.shared.log("Export", "inflate failed: \(fileName) comp=\(compSize) uncomp=\(uncompSize)")
                    return
                }
                extractedCount += 1
                if extractedCount % 50 == 0 {
                    LogManager.shared.log("Export", "progress \(extractedCount)/\(totalEntries)")
                }
            }
        }

        LogManager.shared.log("Export", "streaming extracted \(extractedCount)/\(totalEntries) files")
        return extractedCount > 0
    }

    // Data 版 (subdata/read 結果は 0-indexed 新規 Data)
    private static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        let s = data.startIndex
        return UInt16(data[s + offset]) | (UInt16(data[s + offset + 1]) << 8)
    }
    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        let s = data.startIndex
        return UInt32(data[s + offset]) | (UInt32(data[s + offset + 1]) << 8)
             | (UInt32(data[s + offset + 2]) << 16) | (UInt32(data[s + offset + 3]) << 24)
    }
    private static func readU64(_ data: Data, at offset: Int) -> UInt64 {
        var r: UInt64 = 0
        let s = data.startIndex
        for k in 0..<8 { r |= UInt64(data[s + offset + k]) << (k * 8) }
        return r
    }

    // MARK: - Chunk-wise inflate (1エントリ分、メモリピーク抑制)

    /// 圧縮済みエントリを sourceFH から chunk 単位で読み、destFH に chunk 単位で書き込む
    /// chunk サイズ 256KB、ピーク消費はそれ × 2 程度に抑える見込み
    private static func streamInflateEntry(
        sourceFH: FileHandle,
        destFH: FileHandle,
        compSize: UInt64,
        uncompSize: UInt64,
        compMethod: Int
    ) -> Bool {
        let chunkSize = 256 * 1024

        // STORED (無圧縮) はそのままコピー
        if compMethod == 0 {
            var remaining = compSize
            while remaining > 0 {
                let readLen = Int(min(UInt64(chunkSize), remaining))
                guard let chunk = try? sourceFH.read(upToCount: readLen),
                      chunk.count == readLen else { return false }
                do { try destFH.write(contentsOf: chunk) } catch { return false }
                remaining -= UInt64(readLen)
            }
            return true
        }
        guard compMethod == 8 else { return false }

        // deflate: compression_stream で chunk-wise inflate
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }

        var status = compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else { return false }
        defer { compression_stream_destroy(streamPtr) }

        let outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { outBuf.deallocate() }

        streamPtr.pointee.dst_ptr = outBuf
        streamPtr.pointee.dst_size = chunkSize
        streamPtr.pointee.src_size = 0

        var compRemaining = compSize
        var totalWritten: UInt64 = 0

        while true {
            // src 空なら次 chunk を読む
            if streamPtr.pointee.src_size == 0 && compRemaining > 0 {
                let readLen = Int(min(UInt64(chunkSize), compRemaining))
                guard let chunk = try? sourceFH.read(upToCount: readLen),
                      chunk.count == readLen else { return false }

                let isLast = (compRemaining - UInt64(chunk.count)) == 0
                let flags: Int32 = isLast ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

                let procResult: Bool = chunk.withUnsafeBytes { rawBuf -> Bool in
                    guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                    streamPtr.pointee.src_ptr = base
                    streamPtr.pointee.src_size = chunk.count

                    while streamPtr.pointee.src_size > 0 || isLast {
                        status = compression_stream_process(streamPtr, flags)
                        let produced = chunkSize - streamPtr.pointee.dst_size
                        if produced > 0 {
                            let outData = Data(bytes: outBuf, count: produced)
                            do { try destFH.write(contentsOf: outData) } catch { return false }
                            totalWritten += UInt64(produced)
                            streamPtr.pointee.dst_ptr = outBuf
                            streamPtr.pointee.dst_size = chunkSize
                        }
                        if status == COMPRESSION_STATUS_END { return true }
                        if status == COMPRESSION_STATUS_ERROR { return false }
                        if status == COMPRESSION_STATUS_OK && streamPtr.pointee.src_size == 0 && !isLast {
                            break
                        }
                    }
                    return true
                }
                if !procResult { return false }
                compRemaining -= UInt64(chunk.count)
                if status == COMPRESSION_STATUS_END { break }
            } else if compRemaining == 0 {
                break
            }
        }

        if totalWritten != uncompSize {
            LogManager.shared.log("Export", "inflate size mismatch expected=\(uncompSize) got=\(totalWritten)")
        }
        return totalWritten > 0
    }

    // MARK: - ZIP手動展開（旧版、小ファイル互換用だが extractZipStreaming に統一）

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
