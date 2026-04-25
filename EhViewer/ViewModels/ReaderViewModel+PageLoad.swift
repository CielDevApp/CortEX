import Foundation
import SwiftUI
import CoreImage

// MARK: - ページロード & リクエストキュー
extension ReaderViewModel {

    /// ロードをリクエスト（重複チェック+キューイング）
    func requestLoad(_ index: Int) {
        guard index >= 0, index < totalPages else { return }
        // currentIndex から遠すぎるページはロードしない（スライダージャンプ時のスパム防止）
        let maxDistance = SafetyMode.shared.isEnabled ? 5 : 10
        if abs(index - currentIndex) > maxDistance { return }
        if rawImages[index] != nil { return }
        if completedPages.contains(index) { return }
        if loadingPages.contains(index) { return }
        if loadingPages.count >= maxConcurrent {
            // スキップログは1秒に1回だけ（洪水防止）
            skippedSinceLastLog += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastSkipLogTime > 1.0 {
                LogManager.shared.log("Reader", "requestLoad skip: maxConcurrent(\(loadingPages.count)), \(skippedSinceLastLog) skipped since last log")
                lastSkipLogTime = now
                skippedSinceLastLog = 0
            }
            return
        }

        // サムネプレースホルダー（全モードで実行 - mode 0/1も初回setLoadedをMainThread保証）
        if holder(for: index).image == nil {
            if let thumb = thumbnailImage(for: index) {
                holder(for: index).setLoaded(thumb, placeholder: true)
                placeholderPages.insert(index)
            }
        }

        loadingPages.insert(index)
        let isVisible = abs(index - currentIndex) <= 2
        let priority: TaskPriority = isVisible ? .userInitiated : .utility
        Task(priority: priority) {
            let success = await loadSingle(index)
            self.loadingPages.remove(index)
            if success {
                self.completedPages.insert(index)
            }
        }

        // ★ 周辺ページの URL を先行並列解決（fetchImageURL の 300ms 待ちを事前に消化）
        // loadSingle 内で resolvedImageURLs[idx] があればキャッシュヒットで即画像取得に入れる
        if isVisible {
            prefetchImageURLs(around: index, range: 3)
        }
    }

    /// 周辺ページの画像 URL を先行解決（resolvedImageURLs に格納）
    func prefetchImageURLs(around center: Int, range: Int) {
        for offset in 1...range {
            for idx in [center + offset, center - offset] {
                guard idx >= 0, idx < imagePageURLs.count else { continue }
                guard resolvedImageURLs[idx] == nil else { continue }
                guard !urlResolvingPages.contains(idx) else { continue }
                urlResolvingPages.insert(idx)
                Task(priority: .utility) {
                    do {
                        let url = try await client.fetchImageURL(pageURL: imagePageURLs[idx])
                        resolvedImageURLs[idx] = url
                    } catch {}
                    urlResolvingPages.remove(idx)
                }
            }
        }
    }

    /// ページをロード。成功したらtrue、URLが未準備ならfalse
    @discardableResult
    func loadSingle(_ index: Int) async -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard index < totalPages else {
            LogManager.shared.log("Reader", "loadSingle \(index) exit: index>=totalPages (\(totalPages))")
            return false
        }

        // ダウンロード済みローカル画像
        // アニメGIF/WebP はファイル URL ベース（rawData メモリ保持しない）
        #if canImport(UIKit)
        let localFileURL = DownloadManager.shared.imageFilePath(gid: gallery.gid, page: index)
        if FileManager.default.fileExists(atPath: localFileURL.path),
           AnimatedImageDecoder.isAnimatedFile(url: localFileURL) {
            // ポスター（先頭フレーム）だけ decode
            let poster: PlatformImage? = await Task.detached(priority: .userInitiated) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 540
                ]
                guard let src = CGImageSourceCreateWithURL(localFileURL as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
                return PlatformImage(cgImage: cg)
            }.value
            if let poster {
                await MainActor.run {
                    let h = holder(for: index)
                    h.animatedFileURL = localFileURL
                    h.setLoaded(poster)
                }
                LogManager.shared.log("Reader", "loadSingle \(index) exit: local animated URL")
                LogManager.shared.log("Perf", "pageLoad[\(index)]: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms source=local-animated-url")
                return true
            }
        }
        #endif
        if let localData = DownloadManager.shared.loadLocalImageData(gid: gallery.gid, page: index) {
            if let localImage = PlatformImage(data: localData) {
                LogManager.shared.log("Reader", "loadSingle \(index) exit: local image hit")
                LogManager.shared.log("Perf", "pageLoad[\(index)]: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms source=local")
                rawImages[index] = localImage
                applyFilterPipeline(index: index, raw: localImage)
                return true
            }
        }

        let mode = qualityMode
        LogManager.shared.log("Reader", "loadSingle \(index) mode=\(mode) thumbs=\(thumbnails.count) pageURLs=\(imagePageURLs.count)")

        // モード0,1: サムネベース（オフライン）
        if mode <= 1, index < thumbnails.count {
            if let thumb = await getThumbImage(index: index) {
                if mode == 1 {
                    if holder(for: index).image == nil {
                        holder(for: index).setLoaded(thumb)
                    }
                    let capturedIndex = index
                    let processed = await Task.detached(priority: .userInitiated) {
                        guard let upscaled = LanczosUpscaler.shared.upscale(thumb, scale: 4.0) else { return thumb }
                        return LanczosUpscaler.shared.enhanceLowQuality(upscaled) ?? upscaled
                    }.value
                    rawImages[index] = processed
                    applyFilterPipeline(index: index, raw: processed)
                    Task.detached(priority: .utility) {
                        if let enhanced = LanczosUpscaler.shared.upscaleWithTextEnhance(thumb, scale: 4.0) {
                            let result = LanczosUpscaler.shared.enhanceLowQuality(enhanced) ?? enhanced
                            await MainActor.run {
                                self.rawImages[capturedIndex] = result
                                self.applyFilterPipeline(index: capturedIndex, raw: result)
                            }
                        }
                    }
                } else {
                    rawImages[index] = thumb
                    applyFilterPipeline(index: index, raw: thumb)
                }
                LogManager.shared.log("Reader", "loadSingle \(index) exit: mode\(mode) thumb success")
                return true
            }
            LogManager.shared.log("Reader", "loadSingle \(index): mode\(mode) thumb nil, falling through")
        }

        // モード2,3: フル画像
        // about:blank はURL優先取得のプレースホルダー → 実URL取得まで待つ
        if index < imagePageURLs.count && imagePageURLs[index].absoluteString == "about:blank" {
            return false
        }
        guard index < imagePageURLs.count else {
            // "not ready" ログはスロットリング（洪水防止）
            skippedSinceLastLog += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastSkipLogTime > 1.0 {
                LogManager.shared.log("Reader", "loadSingle \(index) exit: imagePageURLs not ready (count=\(imagePageURLs.count), mode=\(mode)), \(skippedSinceLastLog) not-ready since last log")
                lastSkipLogTime = now
                skippedSinceLastLog = 0
            }
            return false
        }

        // サムネプレースホルダー: requestLoad時にスプライト未クロップだった場合のリトライ
        // ネットワーク fetch 前にサムネを表示して黒画面を回避（NHリーダーと同じ設計）
        if holder(for: index).image == nil {
            if let thumb = await getThumbImage(index: index) {
                holder(for: index).setLoaded(thumb, placeholder: true)
                placeholderPages.insert(index)
            } else {
                holder(for: index).setLoading()
            }
        }

        let resolvedHit = resolvedImageURLs[index] != nil
        do {
            var imageURL: URL
            if let resolved = resolvedImageURLs[index] {
                imageURL = resolved
            } else {
                imageURL = try await client.fetchImageURL(pageURL: imagePageURLs[index])
                resolvedImageURLs[index] = imageURL
                Self.saveResolvedURLs(resolvedImageURLs, gid: gallery.gid)
            }

            let cacheHit = ImageCache.shared.image(for: imageURL) != nil
            LogManager.shared.log("Reader", "loadSingle \(index): resolved=\(resolvedHit) cache=\(cacheHit) url=\(imageURL.absoluteString.prefix(80))")

            if let cached = ImageCache.shared.image(for: imageURL) {
                // 自動保存: キャッシュヒット時もローカルに保存
                #if canImport(UIKit)
                if UserDefaults.standard.bool(forKey: "autoSaveOnRead") {
                    if let data = cached.jpegData(compressionQuality: 0.92) {
                        DownloadManager.shared.autoSavePage(
                            gid: gallery.gid, token: gallery.token, title: gallery.title,
                            pageCount: totalPages, page: index, imageData: data
                        )
                    }
                }
                #endif

                // ImageCache は JPEG 再エンコードでアニメ情報を捨てる。別 dir に保存した生 WebP を
                // ファイル URL 経由で holder に注ぐ (Data をメモリ常駐させると 1ページ 5-10MB × 全アニメ
                // ページで数百 MB に膨らむため URL 経由で disk 直 stream を AVPlayer に任せる)。
                if let animURL = ImageCache.shared.animatedWebPFileURL(for: imageURL),
                   WebPAnimationDetector.isAnimatedWebP(url: animURL) {
                    await MainActor.run {
                        self.holder(for: index).animatedFileURL = animURL
                    }
                    LogManager.shared.log("Anim", "cache hit page \(index) restored animatedFileURL from disk")
                }

                let display = Self.downsample(cached)
                rawImages[index] = display
                applyFilterPipeline(index: index, raw: display)
                LogManager.shared.log("Reader", "loadSingle \(index) exit: cache hit, displayed")
                LogManager.shared.log("Perf", "pageLoad[\(index)]: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms source=imageCache")
                if mode >= 3 {
                    let capturedIndex = index
                    Task.detached(priority: .utility) {
                        let enhanced = mode == 4
                            ? LanczosUpscaler.shared.enhanceUltimate(cached)
                            : LanczosUpscaler.shared.sharpenOnly(cached)
                        if let enhanced {
                            await MainActor.run {
                                self.rawImages[capturedIndex] = enhanced
                                self.applyFilterPipeline(index: capturedIndex, raw: enhanced)
                            }
                        }
                    }
                }
                return true
            }

            let isVisible = abs(index - currentIndex) <= 2
            if !isVisible {
                await SafetyMode.shared.delay(nanoseconds: requestDelay)
            }

            let fetchStart = CFAbsoluteTimeGetCurrent()
            let imageData = try await client.fetchImageData(url: imageURL, host: host)
            let fetchMs = Int((CFAbsoluteTimeGetCurrent() - fetchStart) * 1000)

            // 自動保存: 設定ONの場合のみ
            if UserDefaults.standard.bool(forKey: "autoSaveOnRead") {
                DownloadManager.shared.autoSavePage(
                    gid: gallery.gid, token: gallery.token, title: gallery.title,
                    pageCount: totalPages, page: index, imageData: imageData
                )
            }

            // アニメ WebP 判定: VP8X flag bit で判定 (ICCP/XMP chunk で ANIM 文字列が 256B 窓を
            // 超えるケースの誤陰性を回避)。検知時は disk に永続化し holder.animatedFileURL に設定。
            // Data をメモリに持たず AVPlayer が disk 直読みする方針でメモリ常駐を削る (数百 MB 削減)。
            if WebPAnimationDetector.isAnimatedWebP(data: imageData) {
                let animURL = ImageCache.shared.saveAnimatedWebPData(imageData, for: imageURL, gid: gallery.gid, page: index)
                await MainActor.run {
                    self.holder(for: index).animatedFileURL = animURL
                }
                LogManager.shared.log("Anim", "page \(index) detected animated WebP, persisted \(imageData.count)B → disk URL")
            }

            let decodeStart = CFAbsoluteTimeGetCurrent()
            // 専用キュー+GPU(CIContext)でデコード（協調プール不使用 → UIスレッド影響ゼロ）
            let image: PlatformImage? = await withCheckedContinuation { (cont: CheckedContinuation<PlatformImage?, Never>) in
                SpriteCache.imageQueue.async {
                    if let ciImage = CIImage(data: imageData),
                       let cgImage = SpriteCache.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                        cont.resume(returning: PlatformImage(cgImage: cgImage))
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            let decodeMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)

            guard let image else {
                LogManager.shared.log("Reader", "loadSingle \(index) exit: image decode failed")
                holder(for: index).setFailed("画像デコード失敗")
                return true
            }

            ImageCache.shared.set(image, for: imageURL)
            let display = Self.downsample(image)
            rawImages[index] = display
            applyFilterPipeline(index: index, raw: display)
            LogManager.shared.log("Reader", "loadSingle \(index) exit: fetched & displayed (\(image.pixelWidth)x\(image.pixelHeight))")
            LogManager.shared.log("Perf", "pageLoad[\(index)]: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms fetch=\(fetchMs)ms decode=\(decodeMs)ms size=\(imageData.count)B \(image.pixelWidth)x\(image.pixelHeight)")

            if mode >= 3 {
                let capturedIndex = index
                Task.detached(priority: .utility) {
                    let enhanced = mode == 4
                        ? LanczosUpscaler.shared.enhanceUltimate(image)
                        : LanczosUpscaler.shared.sharpenOnly(image)
                    if let enhanced {
                        await MainActor.run {
                            self.rawImages[capturedIndex] = enhanced
                            self.applyFilterPipeline(index: capturedIndex, raw: enhanced)
                        }
                    }
                }
            }
        } catch {
            if resolvedHit && SafetyMode.shared.isEnabled {
                LogManager.shared.log("Reader", "loadSingle \(index): resolved URL expired, retrying fresh")
                resolvedImageURLs.removeValue(forKey: index)
                Self.saveResolvedURLs(resolvedImageURLs, gid: gallery.gid)
                do {
                    let freshURL = try await client.fetchImageURL(pageURL: imagePageURLs[index])
                    resolvedImageURLs[index] = freshURL
                    Self.saveResolvedURLs(resolvedImageURLs, gid: gallery.gid)
                    let isVisible = abs(index - currentIndex) <= 2
                    if !isVisible { await SafetyMode.shared.delay(nanoseconds: requestDelay) }
                    let imageData = try await client.fetchImageData(url: freshURL, host: host)

                    // 自動保存（リトライ時、設定ONの場合のみ）
                    if UserDefaults.standard.bool(forKey: "autoSaveOnRead") {
                        DownloadManager.shared.autoSavePage(
                            gid: gallery.gid, token: gallery.token, title: gallery.title,
                            pageCount: totalPages, page: index, imageData: imageData
                        )
                    }

                    let retryImage: PlatformImage? = await withCheckedContinuation { (cont: CheckedContinuation<PlatformImage?, Never>) in
                        SpriteCache.imageQueue.async {
                            if let ciImage = CIImage(data: imageData),
                               let cgImage = SpriteCache.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                                cont.resume(returning: PlatformImage(cgImage: cgImage))
                            } else {
                                cont.resume(returning: nil)
                            }
                        }
                    }
                    if let retryImage {
                        ImageCache.shared.set(retryImage, for: freshURL)
                        let display = Self.downsample(retryImage)
                        rawImages[index] = display
                        applyFilterPipeline(index: index, raw: display)
                        LogManager.shared.log("Reader", "loadSingle \(index) exit: retry success (\(retryImage.pixelWidth)x\(retryImage.pixelHeight))")
                        return true
                    }
                } catch {
                    LogManager.shared.log("Reader", "loadSingle \(index) exit: retry also failed: \(error.localizedDescription)")
                }
            }
            LogManager.shared.log("Reader", "loadSingle \(index) exit: error \(error.localizedDescription)")
            holder(for: index).setFailed(error.localizedDescription)
        }
        return true
    }

    // MARK: - ページURL取得

    func loadImagePages() async {
        guard !hasLoadedImagePages else { return }
        hasLoadedImagePages = true

        if isOfflineMode {
            if thumbnails.isEmpty {
                do {
                    let infos = try await client.fetchThumbnailInfos(host: host, gallery: gallery, page: 0)
                    if !infos.isEmpty {
                        thumbnails = infos
                        let spriteURLs = Set(infos.map(\.spriteURL))
                        for url in spriteURLs {
                            if ImageCache.shared.image(for: url) == nil {
                                if let data = try? await client.fetchImageData(url: url, host: host) {
                                    let img: PlatformImage? = await withCheckedContinuation { cont in
                                        SpriteCache.imageQueue.async {
                                            if let ci = CIImage(data: data),
                                               let cg = SpriteCache.ciContext.createCGImage(ci, from: ci.extent) {
                                                cont.resume(returning: PlatformImage(cgImage: cg))
                                            } else { cont.resume(returning: nil) }
                                        }
                                    }
                                    if let img { ImageCache.shared.setThumb(img, for: url) }
                                }
                            }
                        }
                    }
                } catch {}
            }
            if !thumbnails.isEmpty {
                totalPages = thumbnails.count
                isLoading = false
                let start = min(initialPage, thumbnails.count - 1)
                requestLoad(start)
                if start + 1 < thumbnails.count { requestLoad(start + 1) }
                if initialPage > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.scrollTarget = self.initialPage }
                }
                if thumbnails.count >= 20 {
                    Task(priority: .utility) { await self.fetchMoreThumbnails() }
                }
                return
            }
        }

        if imagePageURLs.isEmpty {
            if let cached = Self.loadURLCache(gid: gallery.gid) {
                imagePageURLs = cached
                totalPages = cached.count
                LogManager.shared.log("Reader", "URL cache hit: \(cached.count) pages for gid=\(gallery.gid)")
                isLoading = false
                let center = max(currentIndex, initialPage)
                requestLoad(center)
                requestLoad(center + 1)
                requestLoad(center - 1)
                if initialPage != currentIndex { requestLoad(initialPage) }
                return
            }
        }

        isLoading = true
        errorMessage = nil
        await fetchAndCacheURLs()
        isLoading = false
    }

    func fetchAndCacheURLs() async {
        let urlsPerPage = 20
        let knownTotal = gallery.pageCount
        let targetPage = max(currentIndex, initialPage)
        let targetURLPage = targetPage / urlsPerPage

        do {
            var allPageURLs: [URL] = []
            var seenURLs: Set<URL> = []
            var fetchedPages: Set<Int> = []

            // ★ Phase 1: ジャンプ先の URL ページを最優先で取得
            // 後半ページタップ時に page 0 から順番待ちする問題を解消
            if targetURLPage > 0 {
                // page 0 → targetURLPage を一気に取得（途中の URL が無いと配列に穴が空く）
                // 穴を埋めるためにプレースホルダーを置きつつ、targetURLPage 周辺を先に取得
                let priorityPages = [targetURLPage, targetURLPage + 1, targetURLPage - 1].filter { $0 >= 0 }
                for p in priorityPages {
                    if fetchedPages.contains(p) { continue }
                    let urls = try await client.fetchImagePageURLs(host: host, gallery: gallery, page: p)
                    if urls.isEmpty { continue }
                    fetchedPages.insert(p)
                    let offset = p * urlsPerPage
                    // 配列を拡張
                    while allPageURLs.count < offset + urls.count {
                        allPageURLs.append(URL(string: "about:blank")!)
                    }
                    for (i, url) in urls.enumerated() {
                        let idx = offset + i
                        if idx < allPageURLs.count {
                            allPageURLs[idx] = url
                            seenURLs.insert(url)
                        }
                    }
                    imagePageURLs = allPageURLs
                    LogManager.shared.log("Perf", "fetchImagePageURLs: priority p=\(p) count=\(urls.count) total=\(allPageURLs.count)")
                }
                // 優先ページ取得完了 → 即座にリクエスト
                if targetPage < allPageURLs.count {
                    requestLoad(targetPage)
                    requestLoad(targetPage + 1)
                    requestLoad(targetPage - 1)
                }
            }

            // ★ Phase 2: 残り全ページを順番に取得（穴埋め + 新規）
            var page = 0
            while true {
                if fetchedPages.contains(page) { page += 1; continue }
                let urls = try await client.fetchImagePageURLs(host: host, gallery: gallery, page: page)
                if urls.isEmpty { break }
                fetchedPages.insert(page)
                let offset = page * urlsPerPage
                // 配列を拡張
                while allPageURLs.count < offset + urls.count {
                    allPageURLs.append(URL(string: "about:blank")!)
                }
                for (i, url) in urls.enumerated() {
                    let idx = offset + i
                    if idx < allPageURLs.count && !seenURLs.contains(url) {
                        allPageURLs[idx] = url
                        seenURLs.insert(url)
                    }
                }
                page += 1
                imagePageURLs = allPageURLs
                if knownTotal > 0 && seenURLs.count >= knownTotal { break }
                if page > 200 { break }
                await SafetyMode.shared.delay(nanoseconds: requestDelay)
            }

            imagePageURLs = allPageURLs
            if allPageURLs.count > totalPages { totalPages = allPageURLs.count }
            if !allPageURLs.isEmpty {
                Self.saveURLCache(allPageURLs, gid: gallery.gid)
                let center = max(currentIndex, initialPage)
                requestLoad(center)
                requestLoad(center + 1)
                requestLoad(center - 1)
            } else if errorMessage == nil {
                errorMessage = "ページURLを取得できませんでした"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchMoreThumbnails() async {
        var page = 1
        var seenIndices = Set(thumbnails.map(\.index))
        while page <= 100 {
            await SafetyMode.shared.delay(nanoseconds: requestDelay)
            do {
                let infos = try await client.fetchThumbnailInfos(host: host, gallery: gallery, page: page)
                if infos.isEmpty { break }
                let newInfos = infos.filter { !seenIndices.contains($0.index) }
                if newInfos.isEmpty { break }
                seenIndices.formUnion(newInfos.map(\.index))
                let spriteURLs = Set(newInfos.map(\.spriteURL))
                for url in spriteURLs {
                    if ImageCache.shared.image(for: url) == nil {
                        if let data = try? await client.fetchImageData(url: url, host: host) {
                            let img: PlatformImage? = await withCheckedContinuation { cont in
                                SpriteCache.imageQueue.async {
                                    if let ci = CIImage(data: data),
                                       let cg = SpriteCache.ciContext.createCGImage(ci, from: ci.extent) {
                                        cont.resume(returning: PlatformImage(cgImage: cg))
                                    } else { cont.resume(returning: nil) }
                                }
                            }
                            if let img { ImageCache.shared.setThumb(img, for: url) }
                        }
                    }
                }
                await MainActor.run {
                    thumbnails.append(contentsOf: newInfos)
                    totalPages = thumbnails.count
                }
                page += 1
            } catch { break }
        }
        LogManager.shared.log("Reader", "thumbnail loading complete: \(thumbnails.count) pages")
    }

    // MARK: - サムネ画像取得

    func getThumbImage(index: Int) async -> PlatformImage? {
        guard index < thumbnails.count else { return nil }
        let info = thumbnails[index]
        // SpriteCacheのクロップ済みキャッシュを先に確認
        let croppedKey = SpriteCache.shared.croppedKey(url: info.spriteURL, offsetX: info.offsetX)
        if let cached = SpriteCache.shared.croppedImage(key: croppedKey) { return cached }
        // スプライトシートからクロップ
        if let sprite = SpriteCache.shared.sprite(for: info.spriteURL) {
            let x = abs(Int(info.offsetX))
            let w = Int(info.width), h = Int(info.height)
            let clampedX = min(x, sprite.pixelWidth - 1)
            let clampedW = min(w, sprite.pixelWidth - clampedX)
            let clampedH = min(h, sprite.pixelHeight)
            return sprite.croppedImage(rect: CGRect(x: clampedX, y: 0, width: clampedW, height: clampedH))
        }
        return nil
    }
}
