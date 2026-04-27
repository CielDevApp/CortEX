import Foundation
import Compression
#if canImport(UIKit)
import UIKit
#endif
import zlib

/// ダウンロード済みギャラリーのエクスポート/インポート
///
/// nonisolated: プロジェクトの Default Actor Isolation = @MainActor 設定により
/// 暗黙的に main isolated になっていた結果、Task.detached 内でも main thread に
/// dispatch 戻され NSFileCoordinator の ZIP 生成が 59 秒 main を block していた。
/// enum 全体を nonisolated 化して importFromZip も予防的に main から切り離す。
nonisolated enum GalleryExporter {

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

    // MARK: - エクスポート（フォルダ→ZIP streaming→ShareSheet）

    /// ギャラリーフォルダをZIPにしてURLを返す
    ///
    /// ZIP streaming 版 (stored 方式、ZIP64 常時有効)。旧 NSFileCoordinator(.forUploading)
    /// は 500+ ページ作品で Code=512 失敗 + 59 秒 main block していたため廃止。
    /// 自前実装の利点:
    ///   - `progress` コールバックで実進捗報告可能 (ページ単位)
    ///   - chunk-wise 読み書きでメモリピークは 256KB 程度
    ///   - WebP/MP4 は既に圧縮済みなので stored (無圧縮) で速度優先
    /// 失敗時は throws、成功時は .cortex の URL を返す。
    static func exportAsZipStreaming(
        gid: Int,
        progress: ((_ completed: Int, _ total: Int) -> Void)? = nil,
        destOverride: URL? = nil
    ) throws -> URL {
        // 田中要望 2026-04-27: destOverride で NAS final path を直接指定可能。
        //   旧来の tmp 経由 → NAS copy フローは SSD ピーク使用量が staging × 2 となり
        //   大容量作品 (~10GB) で ENOSPC 発生。NAS 直接 stream で SSD 倍取り解消。
        //   nil 時は従来通り tmp に書く (Share Sheet などの export 用)。
        LogManager.shared.log("Export", "exportAsZipStreaming ENTER gid=\(gid) mainThread=\(Thread.isMainThread) directNAS=\(destOverride != nil)")
        cleanupOldExportFiles()

        let dm = DownloadManager.shared
        let galleryDir = galleryDirectory(gid: gid)

        guard FileManager.default.fileExists(atPath: galleryDir.path) else {
            throw NSError(domain: "GalleryExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ギャラリーフォルダが見つかりません (gid=\(gid))"])
        }

        // ディレクトリ再帰走査、相対パスを収集
        guard let enumerator = FileManager.default.enumerator(
            at: galleryDir,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw NSError(domain: "GalleryExporter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "ギャラリーフォルダの列挙に失敗"])
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isFile { fileURLs.append(fileURL) }
        }
        guard !fileURLs.isEmpty else {
            throw NSError(domain: "GalleryExporter", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "ギャラリーにファイルがありません"])
        }

        // 出力先 .cortex
        let destURL: URL
        if let override = destOverride {
            destURL = override
        } else {
            let exportDir = FileManager.default.temporaryDirectory
            let title = dm.downloads[gid]?.title ?? "\(gid)"
            let safeName = title.replacingOccurrences(of: "/", with: "_").prefix(50)
            destURL = exportDir.appendingPathComponent("\(safeName).cortex")
        }
        try? FileManager.default.removeItem(at: destURL)

        let t0 = Date()
        let writer = try ZipStreamWriter(url: destURL)

        let total = fileURLs.count
        progress?(0, total)

        // iOS の /private/var/ と /var/ は同一場所を指すシンボリックリンクだが、
        // FileManager.enumerator(at:) が返す URL の .path は /private/var/... と
        // なる一方、galleryDir.path は /var/... の場合がある。単純な prefix 比較では
        // 一致せず、ZIP entry 名がフルパスになって import 側の metadata.json 検出が
        // 失敗する致命バグ。standardizedFileURL で両者を正規化してから差分を取る。
        let baseURL = galleryDir.standardizedFileURL
        let baseComponents = baseURL.pathComponents
        for (i, fileURL) in fileURLs.enumerated() {
            let stdURL = fileURL.standardizedFileURL
            let fullComponents = stdURL.pathComponents
            let relPath: String
            if fullComponents.count > baseComponents.count,
               Array(fullComponents.prefix(baseComponents.count)) == baseComponents {
                relPath = fullComponents.dropFirst(baseComponents.count).joined(separator: "/")
            } else {
                // フォールバック: ファイル名のみ（metadata.json や page_NNNN.jpg は衝突しない前提）
                LogManager.shared.log("Export", "path normalize fallback: base=\(baseURL.path) file=\(stdURL.path)")
                relPath = fileURL.lastPathComponent
            }
            try autoreleasepool {
                try writer.addFileStored(name: relPath, sourceURL: fileURL)
            }
            progress?(i + 1, total)
        }

        try writer.finish()

        let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        LogManager.shared.log("Export",
            "exportAsZipStreaming DONE gid=\(gid) files=\(total) size=\(size / 1024 / 1024)MB elapsedMs=\(elapsedMs) → \(destURL.lastPathComponent)")
        return destURL
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
        // 田中要望 2026-04-26 staging fix: DL save dest 設定時の staging 経路を尊重するため、
        // DownloadManager.shared.galleryDirectory を使う (旧: Documents/EhViewer/downloads ハードコード)。
        // これで isStaging gid なら staging dir、それ以外は baseDirectory に解決される。
        return DownloadManager.shared.galleryDirectory(gid: gid)
    }
}

// MARK: - ZipStreamWriter

/// 自前 ZIP Writer (stored 方式、ZIP64 常時有効)。
/// - stored: 既に圧縮済みの画像 (WebP/JPEG/PNG/MP4) は deflate 効果薄 + CPU 浪費、stored で速度優先
/// - ZIP64: file size/offset/entry 数のいずれが 4GB/65535 を超えても安全に動く
/// - streaming: chunk 単位 (256KB) で読み書き、メモリピーク抑制
/// - nonisolated: 外側 enum の isolation を継承、Task.detached で別スレッド実行
final class ZipStreamWriter {
    private struct Entry {
        let name: String
        let crc32: UInt32
        let size: UInt64
        let localHeaderOffset: UInt64
    }

    private let fh: FileHandle
    private var currentOffset: UInt64 = 0
    private var entries: [Entry] = []
    private var finished = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fh = try FileHandle(forWritingTo: url)
    }

    deinit {
        if !finished { try? fh.close() }
    }

    /// ファイルを stored (無圧縮) で追加。
    /// メモリピーク: 256KB chunk × 2 程度 (入出力バッファ)。
    func addFileStored(name: String, sourceURL: URL) throws {
        let localHeaderOffset = currentOffset

        // 事前スキャン: CRC32 と総サイズを計算 (ZIP の LFH は CRC が先頭要求のため)
        let srcFH = try FileHandle(forReadingFrom: sourceURL)
        defer { try? srcFH.close() }

        var crc: UInt32 = 0
        var size: UInt64 = 0
        let chunkSize = 256 * 1024

        while true {
            let chunk: Data = autoreleasepool {
                (try? srcFH.read(upToCount: chunkSize)) ?? Data()
            }
            if chunk.isEmpty { break }
            crc = chunk.withUnsafeBytes { raw -> UInt32 in
                let base = raw.bindMemory(to: UInt8.self).baseAddress
                return UInt32(crc32(uLong(crc), base, UInt32(chunk.count)))
            }
            size += UInt64(chunk.count)
        }
        try srcFH.seek(toOffset: 0)

        // Local File Header
        let nameBytes = name.data(using: .utf8) ?? Data()
        var lfh = Data(capacity: 30 + nameBytes.count + 20)
        lfh.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])  // signature
        lfh.append(le: UInt16(45))    // version needed (ZIP64)
        lfh.append(le: UInt16(0))     // general purpose bit flag
        lfh.append(le: UInt16(0))     // compression method = stored
        lfh.append(le: UInt16(0))     // last mod file time
        lfh.append(le: UInt16(0))     // last mod file date
        lfh.append(le: crc)
        lfh.append(le: UInt32(0xFFFFFFFF))  // comp size (ZIP64 extra で指定)
        lfh.append(le: UInt32(0xFFFFFFFF))  // uncomp size (ZIP64 extra で指定)
        lfh.append(le: UInt16(nameBytes.count))
        lfh.append(le: UInt16(20))    // extra field length (ZIP64: tag 2 + size 2 + uncomp 8 + comp 8)
        lfh.append(nameBytes)
        // ZIP64 Extended Information Extra Field
        lfh.append(le: UInt16(0x0001))
        lfh.append(le: UInt16(16))    // size of following data
        lfh.append(le: size)           // uncomp size
        lfh.append(le: size)           // comp size (stored なので同じ)
        try fh.write(contentsOf: lfh)
        currentOffset += UInt64(lfh.count)

        // ファイル本体を chunk コピー
        while true {
            let done: Bool = try autoreleasepool {
                guard let chunk = try srcFH.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return true
                }
                try fh.write(contentsOf: chunk)
                currentOffset += UInt64(chunk.count)
                return false
            }
            if done { break }
        }

        entries.append(Entry(
            name: name,
            crc32: crc,
            size: size,
            localHeaderOffset: localHeaderOffset
        ))
    }

    /// Central Directory + ZIP64 EOCD + EOCD を書き出し、ファイルを閉じる。
    func finish() throws {
        guard !finished else { return }

        let cdStart = currentOffset

        // Central Directory File Headers
        for entry in entries {
            let nameBytes = entry.name.data(using: .utf8) ?? Data()
            var cd = Data(capacity: 46 + nameBytes.count + 28)
            cd.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])  // signature
            cd.append(le: UInt16(45))    // version made by
            cd.append(le: UInt16(45))    // version needed
            cd.append(le: UInt16(0))     // flags
            cd.append(le: UInt16(0))     // compression method = stored
            cd.append(le: UInt16(0))     // last mod time
            cd.append(le: UInt16(0))     // last mod date
            cd.append(le: entry.crc32)
            cd.append(le: UInt32(0xFFFFFFFF))  // comp size (ZIP64)
            cd.append(le: UInt32(0xFFFFFFFF))  // uncomp size (ZIP64)
            cd.append(le: UInt16(nameBytes.count))
            cd.append(le: UInt16(28))    // extra field length (ZIP64: uncomp 8 + comp 8 + offset 8 + tag 4)
            cd.append(le: UInt16(0))     // comment length
            cd.append(le: UInt16(0))     // disk number start
            cd.append(le: UInt16(0))     // internal file attrs
            cd.append(le: UInt32(0))     // external file attrs
            cd.append(le: UInt32(0xFFFFFFFF))  // local header offset (ZIP64)
            cd.append(nameBytes)
            // ZIP64 Extra Field
            cd.append(le: UInt16(0x0001))
            cd.append(le: UInt16(24))    // size of following data
            cd.append(le: entry.size)              // uncomp size
            cd.append(le: entry.size)              // comp size (stored なので同じ)
            cd.append(le: entry.localHeaderOffset)
            try fh.write(contentsOf: cd)
            currentOffset += UInt64(cd.count)
        }

        let cdSize = currentOffset - cdStart
        let z64EocdOffset = currentOffset

        // ZIP64 End of Central Directory Record
        var z64 = Data(capacity: 56)
        z64.append(contentsOf: [0x50, 0x4b, 0x06, 0x06])
        z64.append(le: UInt64(44))     // size of ZIP64 EOCD record - 12
        z64.append(le: UInt16(45))     // version made by
        z64.append(le: UInt16(45))     // version needed
        z64.append(le: UInt32(0))      // disk number
        z64.append(le: UInt32(0))      // disk with CD
        z64.append(le: UInt64(entries.count))  // entries on disk
        z64.append(le: UInt64(entries.count))  // total entries
        z64.append(le: cdSize)
        z64.append(le: cdStart)
        try fh.write(contentsOf: z64)
        currentOffset += UInt64(z64.count)

        // ZIP64 End of Central Directory Locator
        var loc = Data(capacity: 20)
        loc.append(contentsOf: [0x50, 0x4b, 0x06, 0x07])
        loc.append(le: UInt32(0))      // disk with ZIP64 EOCD
        loc.append(le: z64EocdOffset)
        loc.append(le: UInt32(1))      // total number of disks
        try fh.write(contentsOf: loc)
        currentOffset += UInt64(loc.count)

        // End of Central Directory Record (ZIP64 で実値は 0xFFFF... にしておく)
        var eocd = Data(capacity: 22)
        eocd.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        eocd.append(le: UInt16(0))     // disk number
        eocd.append(le: UInt16(0))     // disk with CD
        eocd.append(le: UInt16(0xFFFF))    // entries on disk (ZIP64 で実値参照)
        eocd.append(le: UInt16(0xFFFF))    // total entries (ZIP64 で実値参照)
        eocd.append(le: UInt32(0xFFFFFFFF))  // size of CD (ZIP64)
        eocd.append(le: UInt32(0xFFFFFFFF))  // offset of CD (ZIP64)
        eocd.append(le: UInt16(0))     // comment length
        try fh.write(contentsOf: eocd)
        currentOffset += UInt64(eocd.count)

        try fh.close()
        finished = true
    }
}

// MARK: - Data little-endian append helpers (ZIP is little-endian)

private extension Data {
    mutating func append(le value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
    mutating func append(le value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
    mutating func append(le value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
