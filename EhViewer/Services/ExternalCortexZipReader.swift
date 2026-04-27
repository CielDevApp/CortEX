import Foundation
import Compression

/// 外部参照フォルダ配下の `.cortex` ZIP archive を直接参照する reader (Phase E1.B, 2026-04-26)。
///
/// 役割:
/// - .cortex ZIP の TOC (Central Directory) を読み込んで entry リスト + offset/size を保持
/// - リーダーから page 要求があれば ZIP entry を short-burst で展開、SSD LRU cache に書き出し
/// - cache hit 時は materialized URL を即返す、SSD 上限 1GB で LRU 自動退避
/// - Mac SSD には作品本体は永続保存しない (LRU で削除されるため)
///
/// 設計書 docs/external_folder_import_design_20260425.md Phase E1.A/B、田中判断 2026-04-26 確定
/// (Q-A 一気実装、Q-B 短期 SSD cache 1GB 上限 LRU)。
///
/// thread-safety: scan は detached task から呼ばれるため、本 class は actor isolated にせず
/// NSLock で zipInfo を保護。Reader (main thread) から materialize 呼出も同 lock 経由。
final class ExternalCortexZipReader: @unchecked Sendable {
    static let shared = ExternalCortexZipReader()

    // MARK: - 状態

    /// gid → ZIP 情報 (bookmarkData + zipPath + TOC)。Scanner.register で投入。
    /// bookmarkData を struct 内に持たせて main actor 越しの folders 検索を回避。
    private struct ZipInfo {
        let bookmarkData: Data
        let zipPath: URL
        let entries: [String: ZipEntry]
        let imageNames: [String]
        let coverName: String?
    }
    private var zipInfo: [Int: ZipInfo] = [:]
    private let lock = NSLock()

    /// SSD LRU cache 上限。田中要望 2026-04-27: 1112 page 動画作品 (UnityNay 10GB 等) を
    /// 全 page precache できるよう SSD 空きから動的計算 (空き - 4GB ヘッドルーム、上限 32GB、下限 8GB)。
    /// 取得失敗時は 8GB fallback。
    private var cacheBudget: UInt64 {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: docs.path),
              let free = attrs[.systemFreeSize] as? UInt64 else {
            return 8_589_934_592  // 8GB fallback
        }
        let headroom: UInt64 = 4_294_967_296  // 4GB
        let dynamic: UInt64 = free > headroom ? free - headroom : 0
        let cap: UInt64 = 34_359_738_368   // 32GB max
        let floor: UInt64 = 8_589_934_592   // 8GB min
        return min(cap, max(floor, dynamic))
    }

    /// evict debounce: 直近 evict から 5 秒以内なら skip (連続 page load で何度も走らない)
    private var lastEvictAt: Date = .distantPast
    /// 既に evict task が pending なら重複起動しない
    private var evictPending: Bool = false
    private let evictLock = NSLock()
    private let evictDebounce: TimeInterval = 5.0

    // MARK: - cache directory

    private var cacheRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("EhViewer/external_cache", isDirectory: true)
    }

    private init() {
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    // MARK: - 登録 (Scanner から呼ぶ)

    /// `.cortex` ZIP を gid にひもづけて TOC 情報を保持。
    /// 既に同 gid 登録済なら上書き (再 scan 等で更新される)。
    func register(gid: Int, bookmarkData: Data, zipPath: URL, toc: [String: ZipEntry]) {
        // page_NNNN.* と cover.* を分類
        var images: [String] = []
        var cover: String?
        for name in toc.keys.sorted() {
            let lower = name.lowercased()
            let base = (lower as NSString).lastPathComponent
            if base.hasPrefix("page_") {
                images.append(name)
            } else if base.hasPrefix("cover.") {
                cover = name
            }
        }
        let info = ZipInfo(bookmarkData: bookmarkData, zipPath: zipPath, entries: toc, imageNames: images, coverName: cover)
        lock.lock(); zipInfo[gid] = info; lock.unlock()
    }

    /// 指定 gid が外部 ZIP かどうか (DownloadManager の hook で使う)。
    func isExternalGallery(gid: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return zipInfo[gid] != nil
    }

    /// 指定 gid の登録解除 (rescan で消えた gallery 用)。
    func unregister(gid: Int) {
        lock.lock(); zipInfo[gid] = nil; lock.unlock()
        // cache directory も掃除
        let dir = cacheRoot.appendingPathComponent("\(gid)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// 全 gid 登録解除 (rescan の前に呼ぶ)。
    func unregisterAll() {
        lock.lock(); zipInfo.removeAll(); lock.unlock()
    }

    // MARK: - β-1 (2026-04-26): non-blocking 経路 (Reader freeze 回避)

    /// in-flight materialize の dedupe 用 (gid:page → 1 task)
    private var materializeInFlight: Set<String> = []
    private let materializeFlightLock = NSLock()

    /// 期待される cache file URL (存在するかは別問題)。imageFilePath hook の戻り値用。
    /// Reader 側 loadLocalImage は file が無ければ nil を返すので placeholder 描画される。
    func expectedCacheURL(gid: Int, page: Int) -> URL? {
        lock.lock(); let info = zipInfo[gid]; lock.unlock()
        guard let info else { return nil }
        guard page >= 0 && page < info.imageNames.count else { return nil }
        let entryName = info.imageNames[page]
        let ext = (entryName as NSString).pathExtension.isEmpty ? "bin" : (entryName as NSString).pathExtension
        return cacheRoot
            .appendingPathComponent("\(gid)", isDirectory: true)
            .appendingPathComponent("page_\(String(format: "%04d", page)).\(ext)")
    }

    /// 高速 cache 存在確認 (no SMB IO)。hit なら URL、miss なら nil。
    func cachedImageURL(gid: Int, page: Int) -> URL? {
        guard let url = expectedCacheURL(gid: gid, page: page) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// β-1 main API: cache 存在チェック + 未取得なら background materialize trigger (dedupe)。
    /// 戻り値: cache hit なら URL、miss なら expectedCacheURL (存在しない URL、loadLocalImage は nil 返す)。
    /// main thread からの呼び出しでも SMB IO ブロック発生しない。完了で Notification 通知。
    func cachedOrTriggerBackground(gid: Int, page: Int) -> URL? {
        if let hit = cachedImageURL(gid: gid, page: page) {
            return hit
        }
        // miss: background materialize trigger (dedupe)
        let key = "\(gid):\(page)"
        materializeFlightLock.lock()
        let already = materializeInFlight.contains(key)
        if !already { materializeInFlight.insert(key) }
        materializeFlightLock.unlock()

        if !already {
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                _ = self.materializedImageURL(gid: gid, page: page)
                self.materializeFlightLock.lock()
                self.materializeInFlight.remove(key)
                self.materializeFlightLock.unlock()
                NotificationCenter.default.post(
                    name: .externalCortexImageReady,
                    object: nil,
                    userInfo: ["gid": gid, "page": page]
                )
            }
        }
        // 存在しないかもしれない URL を返す (caller は file exists check でハンドル)
        return expectedCacheURL(gid: gid, page: page)
    }

    /// 指定 gid の image 件数 (Scanner で metadata から取れない場合用)。
    func imageCount(gid: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        return zipInfo[gid]?.imageNames.count ?? 0
    }

    /// 田中案 2026-04-26: budget bytes 内に収まる最大 page 数 (累積 compressedSize ≤ budget)。
    /// pre-cache の事前計算用、SMB IO 不要 (TOC は scan 時に既読込み)。
    /// 戻り値: (pages: 取得対象ページ数, totalBytes: その累積サイズ)
    func maxPagesWithinBudget(gid: Int, budget: UInt64) -> (pages: Int, totalBytes: UInt64) {
        lock.lock(); let info = zipInfo[gid]; lock.unlock()
        guard let info else { return (0, 0) }
        var sum: UInt64 = 0
        var count = 0
        for name in info.imageNames {
            let size = info.entries[name]?.compressedSize ?? 0
            if sum + size > budget { break }
            sum += size
            count += 1
        }
        return (count, sum)
    }

    // MARK: - materialized URL (DownloadManager の imageFilePath hook 用)

    /// 指定 gid + page を SSD cache 上に materialize して URL を返す。
    /// - cache hit: そのまま URL 返す (mtime 更新で LRU 順位更新)
    /// - cache miss: ZIP から entry 抽出 → cache に書き出し → LRU 退避 → URL 返す
    /// - 失敗時 nil
    func materializedImageURL(gid: Int, page: Int) -> URL? {
        lock.lock(); let info = zipInfo[gid]; lock.unlock()
        guard let info else { return nil }
        guard page >= 0 && page < info.imageNames.count else { return nil }
        let entryName = info.imageNames[page]
        return materialize(info: info, gid: gid, entryName: entryName, expectedFileName: "page_\(String(format: "%04d", page))")
    }

    /// cover 画像の materialized URL。cover.* が ZIP 内に無ければ最初の画像 (page_0001 相当) を返す。
    func materializedCoverURL(gid: Int) -> URL? {
        lock.lock(); let info = zipInfo[gid]; lock.unlock()
        guard let info else { return nil }
        if let coverName = info.coverName {
            return materialize(info: info, gid: gid, entryName: coverName, expectedFileName: "cover")
        }
        return materializedImageURL(gid: gid, page: 0)
    }

    // MARK: - 内部: 1 entry を cache に書き出す

    private func materialize(info: ZipInfo, gid: Int, entryName: String, expectedFileName: String) -> URL? {
        guard let entry = info.entries[entryName] else { return nil }
        let ext = (entryName as NSString).pathExtension.isEmpty ? "bin" : (entryName as NSString).pathExtension
        let cacheURL = cacheRoot
            .appendingPathComponent("\(gid)", isDirectory: true)
            .appendingPathComponent("\(expectedFileName).\(ext)")

        let fm = FileManager.default
        if fm.fileExists(atPath: cacheURL.path) {
            // hit: mtime 更新で LRU 順位を最新化
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheURL.path)
            return cacheURL
        }

        // miss: ZIP から抽出。リーダー側経路では security-scoped access scope 外のため、
        // 保持している bookmarkData から再 resolve + access する。
        // ただし path-override 経路 (bookmark 不要、sandbox=off) では bookmarkData が空 →
        // bookmark 解決を bypass してパス直接アクセス。
        var extracted: Data?
        if info.bookmarkData.isEmpty {
            extracted = ExternalCortexZipReader.extractEntry(zipPath: info.zipPath, entry: entry)
        } else {
            do {
                try SecurityScopedBookmark.access(info.bookmarkData) { _ in
                    extracted = ExternalCortexZipReader.extractEntry(zipPath: info.zipPath, entry: entry)
                }
            } catch {
                LogManager.shared.log("ExtZipReader", "access failed for gid=\(gid): \(error)")
                return nil
            }
        }
        guard let data = extracted else { return nil }

        // cache に書き出し
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: cacheURL, options: .atomic) } catch {
            LogManager.shared.log("ExtZipReader", "cache write failed: \(error)")
            return nil
        }

        // LRU 退避 (background + debounce、main thread 完全に解放)
        // 田中判断 2026-04-26: 400p 動画 WebP page jump で main 占有しないよう
        // background priority + 5 秒 debounce で連続発火を抑制。
        scheduleEvict()

        return cacheURL
    }

    // MARK: - LRU 退避 (background + debounce)

    /// evict の起動制御。直近 5 秒以内 or 既に pending なら skip、それ以外は detached task 起動。
    private func scheduleEvict() {
        evictLock.lock()
        let now = Date()
        if evictPending || now.timeIntervalSince(lastEvictAt) < evictDebounce {
            evictLock.unlock()
            return
        }
        evictPending = true
        evictLock.unlock()

        Task.detached(priority: .background) { [weak self] in
            self?.evictNow()
        }
    }

    private func evictNow() {
        evictIfNeeded()
        evictLock.lock()
        lastEvictAt = Date()
        evictPending = false
        evictLock.unlock()
    }

    private func evictIfNeeded() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: cacheRoot,
                                             includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return
        }
        struct Entry { let url: URL; let size: UInt64; let mtime: Date }
        var entries: [Entry] = []
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let size = UInt64(vals?.fileSize ?? 0)
            let mtime = vals?.contentModificationDate ?? Date.distantPast
            entries.append(Entry(url: url, size: size, mtime: mtime))
            total += size
        }
        guard total > cacheBudget else { return }
        // 古い順にソート、退避
        let sorted = entries.sorted { $0.mtime < $1.mtime }
        var freed: UInt64 = 0
        for e in sorted {
            try? fm.removeItem(at: e.url)
            freed += e.size
            if total - freed <= cacheBudget { break }
        }
        LogManager.shared.log("ExtZipReader", "LRU evict freed=\(freed) bytes (budget=\(cacheBudget))")
    }

    // MARK: - ZIP TOC reader (static、scan 時に呼ばれる)

    /// ZIP file から Central Directory を読み込んで entry name → ZipEntry の map を返す。
    /// .cortex は STORE (画像) + DEFLATE (metadata.json) 混在を想定。失敗時 nil。
    static func readTOC(zipPath: URL) -> [String: ZipEntry]? {
        guard let fh = try? FileHandle(forReadingFrom: zipPath) else { return nil }
        defer { try? fh.close() }
        guard let fileSize = try? fh.seekToEnd() else { return nil }

        // 末尾 64KB+22B を読んで EOCD を探す
        let tailSize: UInt64 = min(65557, fileSize)
        let tailStart = fileSize - tailSize
        do { try fh.seek(toOffset: tailStart) } catch { return nil }
        guard let tail = try? fh.read(upToCount: Int(tailSize)), tail.count >= 22 else { return nil }

        var eocdRel: Int = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50 && tail[i+1] == 0x4b && tail[i+2] == 0x05 && tail[i+3] == 0x06 {
                eocdRel = i
                break
            }
            i -= 1
        }
        guard eocdRel >= 0 else { return nil }

        var totalEntries = UInt64(readU16(tail, at: eocdRel + 10))
        var cdSize = UInt64(readU32(tail, at: eocdRel + 12))
        var cdOffset = UInt64(readU32(tail, at: eocdRel + 16))

        // ZIP64 検出
        if cdOffset == 0xFFFFFFFF || totalEntries == 0xFFFF || cdSize == 0xFFFFFFFF {
            // EOCD locator は EOCD の 20B 前
            let locatorOffset = eocdRel - 20
            guard locatorOffset >= 0,
                  tail[locatorOffset] == 0x50, tail[locatorOffset+1] == 0x4b,
                  tail[locatorOffset+2] == 0x06, tail[locatorOffset+3] == 0x07 else {
                return nil
            }
            let zip64EocdOffset = readU64(tail, at: locatorOffset + 8)
            // ZIP64 EOCD を読む
            do { try fh.seek(toOffset: zip64EocdOffset) } catch { return nil }
            guard let z64 = try? fh.read(upToCount: 56), z64.count >= 56 else { return nil }
            guard z64[0] == 0x50, z64[1] == 0x4b, z64[2] == 0x06, z64[3] == 0x06 else { return nil }
            totalEntries = readU64(z64, at: 32)
            cdSize = readU64(z64, at: 40)
            cdOffset = readU64(z64, at: 48)
        }

        // Central Directory をまとめ読み
        do { try fh.seek(toOffset: cdOffset) } catch { return nil }
        guard let cd = try? fh.read(upToCount: Int(cdSize)), UInt64(cd.count) == cdSize else { return nil }

        var entries: [String: ZipEntry] = [:]
        var p = 0
        for _ in 0..<totalEntries {
            guard p + 46 <= cd.count else { break }
            // signature 0x02014b50
            guard cd[p] == 0x50, cd[p+1] == 0x4b, cd[p+2] == 0x01, cd[p+3] == 0x02 else { break }
            let method = readU16(cd, at: p + 10)
            var compSize: UInt64 = UInt64(readU32(cd, at: p + 20))
            var uncompSize: UInt64 = UInt64(readU32(cd, at: p + 24))
            let nameLen = Int(readU16(cd, at: p + 28))
            let extraLen = Int(readU16(cd, at: p + 30))
            let commentLen = Int(readU16(cd, at: p + 32))
            var localHeaderOffset: UInt64 = UInt64(readU32(cd, at: p + 42))

            let nameStart = p + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= cd.count else { break }
            let name = String(decoding: cd[nameStart..<nameEnd], as: UTF8.self)

            // ZIP64 extra field
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                let extraStart = nameEnd
                var ep = 0
                while ep + 4 <= extraLen {
                    let tag = readU16(cd, at: extraStart + ep)
                    let size = Int(readU16(cd, at: extraStart + ep + 2))
                    if tag == 0x0001 { // ZIP64
                        var fp = extraStart + ep + 4
                        if uncompSize == 0xFFFFFFFF { uncompSize = readU64(cd, at: fp); fp += 8 }
                        if compSize == 0xFFFFFFFF { compSize = readU64(cd, at: fp); fp += 8 }
                        if localHeaderOffset == 0xFFFFFFFF { localHeaderOffset = readU64(cd, at: fp); fp += 8 }
                        break
                    }
                    ep += 4 + size
                }
            }

            entries[name] = ZipEntry(method: method, compressedSize: compSize, uncompressedSize: uncompSize, localHeaderOffset: localHeaderOffset)
            p = nameEnd + extraLen + commentLen
        }
        return entries
    }

    /// 指定 entry の data を抽出。STORE / DEFLATE 対応。
    static func extractEntry(zipPath: URL, entry: ZipEntry) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: zipPath) else { return nil }
        defer { try? fh.close() }

        // local file header を読んで data offset を計算
        do { try fh.seek(toOffset: entry.localHeaderOffset) } catch { return nil }
        guard let lfhPrefix = try? fh.read(upToCount: 30), lfhPrefix.count == 30 else { return nil }
        guard lfhPrefix[0] == 0x50, lfhPrefix[1] == 0x4b, lfhPrefix[2] == 0x03, lfhPrefix[3] == 0x04 else { return nil }
        let nameLen = Int(readU16(lfhPrefix, at: 26))
        let extraLen = Int(readU16(lfhPrefix, at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLen) + UInt64(extraLen)

        do { try fh.seek(toOffset: dataOffset) } catch { return nil }
        guard let raw = try? fh.read(upToCount: Int(entry.compressedSize)),
              UInt64(raw.count) == entry.compressedSize else { return nil }

        switch entry.method {
        case 0:  // STORE
            return raw
        case 8:  // DEFLATE
            return inflateRaw(raw, expectedSize: Int(entry.uncompressedSize))
        default:
            LogManager.shared.log("ExtZipReader", "unsupported compression method: \(entry.method)")
            return nil
        }
    }

    private static func inflateRaw(_ data: Data, expectedSize: Int) -> Data? {
        var dst = Data(count: max(expectedSize, 1))
        let result: Int = data.withUnsafeBytes { srcRaw -> Int in
            return dst.withUnsafeMutableBytes { dstRaw -> Int in
                guard let srcBase = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dstBase = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return compression_decode_buffer(dstBase, dstRaw.count, srcBase, srcRaw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard result > 0 else { return nil }
        return dst.prefix(result)
    }

    // MARK: - byte helpers (内部)

    private static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset+1]) << 8)
    }
    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) | (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
    }
    private static func readU64(_ data: Data, at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[offset+i]) << (i * 8) }
        return v
    }
}

// MARK: - Model

/// .cortex ZIP 内 entry のメタ情報。
struct ZipEntry: Sendable {
    let method: UInt16             // 0 = STORE, 8 = DEFLATE
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
}

extension Notification.Name {
    /// β-1 (2026-04-26): 外部参照 ZIP の background materialize 完了通知。
    /// userInfo: ["gid": Int, "page": Int]。Reader / Library cell が観察して再描画 trigger。
    static let externalCortexImageReady = Notification.Name("externalCortexImageReady")
}
