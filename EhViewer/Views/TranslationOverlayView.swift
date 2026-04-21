import SwiftUI

#if targetEnvironment(macCatalyst)
// Mac Catalyst は Translation framework 非対応（Catalyst 26.0+ で利用可、現状未サポート）
// スタブで consumer (GalleryReaderView) の参照を通す
struct TranslationManagerView: View {
    let viewModel: ReaderViewModel
    let gid: Int
    let targetLang: String
    let sourceLang: String
    let isActive: Bool
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}
#else
import Translation

/// リーダー全体で1つだけ配置する翻訳マネージャーView
/// .translationTask で1回だけセッションを取得し、保持して全ページに使い回す
struct TranslationManagerView: View {
    let viewModel: ReaderViewModel
    let gid: Int
    let targetLang: String
    let sourceLang: String // "auto" or "en", "zh-Hans", "zh-Hant", "ja", "ko"
    let isActive: Bool

    @State private var translationConfig: TranslationSession.Configuration?
    @State private var session: TranslationSession?
    @State private var completedPages: Set<Int> = []
    /// OCRでテキストなしだったページ（画像更新時に再試行）
    @State private var noTextPages: [Int: Int] = [:] // page → originalImage.pixelWidth at OCR time
    @State private var sessionReady = false
    /// フル解像度判定の最小幅
    private let minFullWidth = 400

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: isActive) {
                guard isActive else { return }
                for i in 0..<viewModel.totalPages {
                    viewModel.holder(for: i).translationActive = true
                }
                // セッション未取得なら取得開始
                if session == nil {
                    triggerSession()
                } else {
                    sessionReady = true
                    await processAllPages()
                }
            }
            .translationTask(translationConfig) { receivedSession in
                LogManager.shared.log("Translation", "session acquired")
                session = receivedSession
                sessionReady = true
                await processAllPages()
            }
            .onChange(of: isActive) {
                if !isActive {
                    for i in 0..<viewModel.totalPages {
                        viewModel.holder(for: i).showOriginal()
                    }
                } else {
                    for i in completedPages {
                        viewModel.holder(for: i).showTranslated()
                    }
                    for i in 0..<viewModel.totalPages {
                        viewModel.holder(for: i).translationActive = true
                    }
                    if sessionReady {
                        Task { await processAllPages() }
                    } else {
                        triggerSession()
                    }
                }
            }
    }

    /// source/target言語からTranslationSession.Configurationを生成
    private func triggerSession() {
        // "auto"の場合はsource=nilでApple翻訳に自動検出させる
        let effectiveSource = sourceLang == "auto" ? nil : sourceLang
        let targetLocale = localeFor(targetLang)
        if let effectiveSource {
            let sourceLocale = localeFor(effectiveSource)
            LogManager.shared.log("Translation", "triggerSession: source=\(effectiveSource) target=\(targetLang)")
            translationConfig = .init(source: sourceLocale, target: targetLocale)
        } else {
            LogManager.shared.log("Translation", "triggerSession: source=auto target=\(targetLang)")
            translationConfig = .init(target: targetLocale)
        }
    }

    private func localeFor(_ lang: String) -> Locale.Language {
        switch lang {
        case "ja": return .init(identifier: "ja")
        case "en": return .init(identifier: "en")
        case "zh": return .init(identifier: "zh-Hans")
        case "zh-Hans": return .init(identifier: "zh-Hans")
        case "zh-Hant": return .init(identifier: "zh-Hant")
        case "ko": return .init(identifier: "ko")
        default:
            // NSLinguisticTaggerが返す "zh-Hans" 等をそのまま使う
            if lang.hasPrefix("zh") { return .init(identifier: "zh-Hans") }
            if lang.hasPrefix("ja") { return .init(identifier: "ja") }
            if lang.hasPrefix("ko") { return .init(identifier: "ko") }
            if lang.hasPrefix("en") { return .init(identifier: "en") }
            return .init(identifier: lang)
        }
    }

    // MARK: - 全ページ処理ループ

    private func processAllPages() async {
        guard isActive, sessionReady else { return }
        LogManager.shared.log("Translation", "processAllPages start (completed=\(completedPages.count)/\(viewModel.totalPages))")

        // バッチOCR: 最大N(通常3/エクストリーム6)ページ同時にOCRを実行してからシリアルに翻訳
        let batchSize = SafetyMode.shared.isEnabled ? 3 : 6
        while isActive && !Task.isCancelled {
            var batch: [Int] = []
            let center = viewModel.currentIndex
            for offset in 0..<viewModel.totalPages {
                let candidates = offset == 0 ? [center] : [center + offset, center - offset]
                for p in candidates {
                    guard p >= 0, p < viewModel.totalPages else { continue }
                    if completedPages.contains(p) { continue }
                    if let prevWidth = noTextPages[p] {
                        let holder = viewModel.holder(for: p)
                        if let orig = holder.originalImage, orig.pixelWidth != prevWidth {
                            noTextPages.removeValue(forKey: p)
                        } else { continue }
                    }
                    let holder = viewModel.holder(for: p)
                    guard let orig = holder.originalImage,
                          orig.pixelWidth >= minFullWidth, orig.pixelHeight >= minFullWidth else { continue }
                    batch.append(p)
                    if batch.count >= batchSize { break }
                }
                if batch.count >= batchSize { break }
            }

            guard !batch.isEmpty else {
                LogManager.shared.log("Translation", "all pages processed (\(completedPages.count)/\(viewModel.totalPages))")
                break
            }

            // バッチOCR: 3ページ同時にNEでOCR実行
            if batch.count > 1 {
                LogManager.shared.log("Translation", "batch OCR: \(batch)")
                await withTaskGroup(of: Void.self) { group in
                    for page in batch {
                        if TranslationService.shared.cached(gid: gid, page: page) == nil {
                            let holder = viewModel.holder(for: page)
                            guard let img = holder.originalImage else { continue }
                            let capturedGid = gid
                            group.addTask {
                                let _ = await TranslationService.shared.recognizeText(
                                    image: img, gid: capturedGid, page: page
                                )
                            }
                        }
                    }
                }
            }

            // 翻訳はシリアル（セッション制約）
            for page in batch {
                guard isActive && !Task.isCancelled else { break }
                await processPage(page)
            }
        }

        // 定期スキャン
        while isActive && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard isActive else { break }
            prefetchOCR()
            if let page = findNextPage() {
                LogManager.shared.log("Translation", "periodic: found new page \(page)")
                await processPage(page)
            }
        }
    }

    /// 現在ページ+1〜+2のOCRをバックグラウンドで先行実行
    private func prefetchOCR() {
        let center = viewModel.currentIndex
        for offset in 1...2 {
            let p = center + offset
            guard p >= 0, p < viewModel.totalPages else { continue }
            if TranslationService.shared.cached(gid: gid, page: p) != nil { continue }
            let holder = viewModel.holder(for: p)
            guard let orig = holder.originalImage,
                  orig.pixelWidth >= minFullWidth, orig.pixelHeight >= minFullWidth else { continue }
            let capturedImage = orig
            let capturedGid = gid
            let capturedPage = p
            Task.detached(priority: .utility) {
                let _ = await TranslationService.shared.recognizeText(
                    image: capturedImage, gid: capturedGid, page: capturedPage
                )
            }
        }
    }

    private func findNextPage() -> Int? {
        let center = viewModel.currentIndex
        for offset in 0..<viewModel.totalPages {
            let candidates = offset == 0 ? [center] : [center + offset, center - offset]
            for p in candidates {
                guard p >= 0, p < viewModel.totalPages else { continue }
                let holder = viewModel.holder(for: p)
                guard let orig = holder.originalImage,
                      orig.pixelWidth >= minFullWidth, orig.pixelHeight >= minFullWidth else { continue }

                // noTextだったページ: 画像が更新されていれば再試行
                if let prevWidth = noTextPages[p] {
                    if orig.pixelWidth != prevWidth {
                        noTextPages.removeValue(forKey: p)
                        // 再試行対象
                    } else {
                        continue // 同じ画像 → スキップ
                    }
                }

                if completedPages.contains(p) { continue }
                return p
            }
        }
        return nil
    }

    // MARK: - ページ処理

    /// 遠方ページのtranslatedImageをディスク退避
    private func evictDistantPages() {
        let center = viewModel.currentIndex
        for page in completedPages {
            let distance = abs(page - center)
            if distance > 10 {
                let holder = viewModel.holder(for: page)
                if holder.translatedImage != nil && !holder.translatedImageEvicted {
                    holder.evictTranslatedImage()
                }
            }
        }
    }

    private func processPage(_ page: Int) async {
        let holder = viewModel.holder(for: page)
        holder.translatedCacheKey = "\(gid)_\(page)"
        guard let originalImage = holder.originalImage,
              originalImage.pixelWidth >= minFullWidth, originalImage.pixelHeight >= minFullWidth else {
            return
        }

        // 遠方ページのメモリ退避
        evictDistantPages()

        // 既に焼き込み済み
        if holder.translatedImage != nil {
            completedPages.insert(page)
            holder.isTranslating = false
            if isActive { holder.showTranslated() }
            return
        }

        holder.isTranslating = true

        // キャッシュチェック
        if let cached = TranslationService.shared.cached(gid: gid, page: page),
           !cached.blocks.isEmpty,
           cached.blocks.allSatisfy({ !$0.translatedText.isEmpty }) {
            LogManager.shared.log("Translation", "page \(page): cache hit")
            await burnIn(holder: holder, image: originalImage, blocks: cached.blocks)
            completedPages.insert(page)
            holder.isTranslating = false
            return
        }

        // OCR
        LogManager.shared.log("Translation", "page \(page): OCR start")
        let ocrResult = await Task.detached(priority: .utility) {
            await TranslationService.shared.recognizeText(image: originalImage, gid: gid, page: page)
        }.value

        if ocrResult.blocks.isEmpty {
            LogManager.shared.log("Translation", "page \(page): no text (w=\(originalImage.pixelWidth))")
            noTextPages[page] = originalImage.pixelWidth
            holder.isTranslating = false
            return
        }

        // confidence低いブロックを除外（装飾フォント・筆記体の誤認識防止）
        var blocks = ocrResult.blocks.filter { $0.confidence >= 0.3 }
        if blocks.isEmpty {
            LogManager.shared.log("Translation", "page \(page): all \(ocrResult.blocks.count) blocks low confidence, skip")
            completedPages.insert(page)
            holder.isTranslating = false
            return
        }
        LogManager.shared.log("Translation", "page \(page): \(blocks.count) blocks (filtered from \(ocrResult.blocks.count))")

        // source言語チェック（手動指定時のみ）
        let targetPrefix = String(targetLang.prefix(2))
        if sourceLang != "auto" {
            let sourcePrefix = String(sourceLang.prefix(2))
            if sourcePrefix == targetPrefix {
                LogManager.shared.log("Translation", "page \(page): source=target (\(sourcePrefix)), skip")
                completedPages.insert(page)
                holder.isTranslating = false
                return
            }
        }

        // セッション未取得なら取得
        if session == nil && !sessionReady {
            triggerSession()
            holder.isTranslating = false
            LogManager.shared.log("Translation", "page \(page): acquiring session (source=\(sourceLang) target=\(targetLang))")
            return
        }

        // 翻訳（保持済みセッションを使用）
        guard let session else {
            LogManager.shared.log("Translation", "page \(page): no session available")
            for i in blocks.indices { blocks[i].translatedText = blocks[i].originalText }
            TranslationService.shared.saveTranslated(gid: gid, page: page, blocks: blocks)
            await burnIn(holder: holder, image: originalImage, blocks: blocks)
            completedPages.insert(page)
            holder.isTranslating = false
            return
        }

        // ブロック単位で翻訳対象を決定
        var toTranslate: [(Int, TranslationSession.Request)] = []
        if sourceLang == "auto" {
            // autoモード: 全ブロックをApple翻訳に投げる（NSLinguisticTaggerの誤判定を回避）
            // Apple Translation APIが自動で言語検出＋target言語と同じなら原文返却する
            for (i, block) in blocks.enumerated() {
                toTranslate.append((i, TranslationSession.Request(sourceText: block.originalText)))
            }
        } else {
            // 手動指定: source言語以外のブロックはスキップ
            for (i, block) in blocks.enumerated() {
                if block.originalText.count < 2 {
                    blocks[i].translatedText = ""
                } else {
                    toTranslate.append((i, TranslationSession.Request(sourceText: block.originalText)))
                }
            }
        }

        if toTranslate.isEmpty {
            LogManager.shared.log("Translation", "page \(page): no blocks to translate, skip")
            completedPages.insert(page)
            holder.isTranslating = false
            return
        }

        LogManager.shared.log("Translation", "page \(page): translating \(toTranslate.count)/\(blocks.count) blocks")
        do {
            let requests = toTranslate.map(\.1)
            let responses = try await session.translations(from: requests)
            for (j, response) in responses.enumerated() where j < toTranslate.count {
                let blockIndex = toTranslate[j].0
                let original = blocks[blockIndex].originalText
                // 翻訳結果が元テキストと同じなら焼き込み不要（装飾テキスト等）
                if response.targetText.lowercased() == original.lowercased() {
                    blocks[blockIndex].translatedText = ""
                } else {
                    blocks[blockIndex].translatedText = response.targetText
                }
            }
            LogManager.shared.log("Translation", "page \(page): translation success")
        } catch {
            LogManager.shared.log("Translation", "page \(page): translation error: \(error.localizedDescription)")
            for (idx, _) in toTranslate {
                if blocks[idx].translatedText.isEmpty {
                    blocks[idx].translatedText = blocks[idx].originalText
                }
            }
        }

        TranslationService.shared.saveTranslated(gid: gid, page: page, blocks: blocks)
        await burnIn(holder: holder, image: originalImage, blocks: blocks)
        completedPages.insert(page)
        holder.isTranslating = false
        LogManager.shared.log("Translation", "page \(page): complete (total=\(completedPages.count))")
    }

    // MARK: - 画像焼き込み

    private func burnIn(holder: PageImageHolder, image: PlatformImage, blocks: [TranslatedBlock]) async {
        let translatedBlocks = blocks.filter { !$0.translatedText.isEmpty }
        guard !translatedBlocks.isEmpty else { return }

        let result: PlatformImage? = await Task.detached(priority: .userInitiated) {
            TranslationRenderer.render(original: image, blocks: translatedBlocks)
        }.value

        guard let result else { return }
        holder.translatedImage = result
        if isActive { holder.showTranslated() }
    }
}
#endif
