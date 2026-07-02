import Foundation

/// UserDefaults キーの一元管理 (基盤衛生 A1、2026-06-10)。
/// 文字列リテラル直書き 100 箇所超で同一キーが最大 8 ファイルに重複しており、
/// タイポがコンパイルエラーにならない構造だった。キーの「値」は既存の永続データとの
/// 互換のため絶対に変更しないこと (識別子名だけ Swift 風に整形)。
/// 純定数のみ → nonisolated (どのスレッドからでも参照可)。
nonisolated enum UDKey {
    // MARK: - 読書 / 保存
    static let autoSaveOnRead = "autoSaveOnRead"
    static let readingOrder = "readingOrder"
    static let readerDirection = "readerDirection"

    // MARK: - 画質 / 画像処理
    static let onlineQualityMode = "onlineQualityMode"
    static let downloadQualityMode = "downloadQualityMode"
    static let dlQualityMigrated2 = "dlQualityMigrated2"
    static let hdrEnhancement = "hdrEnhancement"
    static let imageEnhanceFilter = "imageEnhanceFilter"
    static let aiImageProcessing = "aiImageProcessing"
    static let denoiseEnabled = "denoiseEnabled"
    static let noFilterMode = "noFilterMode"
    static let useMetalPipeline = "useMetalPipeline"
    static let aiGenreClassification = "aiGenreClassification"

    // MARK: - アニメ再生
    static let animPlaybackMode = "animPlaybackMode"
    static let animMaxConcurrentPlay = "animMaxConcurrentPlay"
    static let animatedPersonSegmentation = "animatedPersonSegmentation"
    static let animationDialogDontAskDefault = "animationDialogDontAskDefault"
    static let preloadPlayback = "preloadPlayback"
    static let boomerangMode = "boomerangMode"

    // MARK: - 翻訳
    static let translationMode = "translationMode"
    static let translationLang = "translationLang"
    static let translationSourceLang = "translationSourceLang"
    static let tagTranslation = "tagTranslation"

    // MARK: - CORTEX PROTOCOL
    static let cortexProtocolUnlocked = "cortexProtocolUnlocked"
    static let cortexCharacterAges = "cortex_character_ages"
    static let cortexEhTagsFetched = "cortex_eh_tags_fetched"

    // MARK: - 認証 / 資格情報バックアップ
    static let lastMemberID = "lastMemberID"
    static let lastPassHash = "lastPassHash"
    static let lastIgneous = "lastIgneous"
    static let lastNhCookies = "lastNhCookies"
    static let biometricLockEnabled = "biometricLockEnabled"

    // MARK: - 表示 / レイアウト
    static let appTheme = "appTheme"
    static let galleryListLayout = "galleryListLayout"
    static let libraryListLayout = "libraryListLayout"
    static let downloadsCompletedSortOrderRaw = "downloadsCompletedSortOrderRaw"
    static let showAdvancedSettings = "showAdvancedSettings"
    static let gachaSkipEffect = "gachaSkipEffect"
    static let tipsShownOnce = "tipsShownOnce"

    // MARK: - 既読管理
    static let grayOutReadGalleries = "grayOutReadGalleries"
    static let readHistoryKeys = "readHistory.v1"

    // MARK: - 省電力 / 診断
    static let ecoMode = "ecoMode"
    static let ecoLinkLowPower = "ecoLinkLowPower"
    static let debugLogEnabled = "debugLogEnabled"
    static let allowCellularDownload = "allowCellularDownload"

    // MARK: - DL / 移行フラグ
    static let abortAllOnLaunch = "com.kanayayuutou.cortex.abortAllOnLaunch"
    static let autoSaveOnlyMigrated = "com.kanayayuutou.cortex.autoSaveOnlyMigrated"
    static let phoenixBackupDone = "phoenixBackupDone"

    // MARK: - 動的キー
    static func localReaderBookmark(gid: Int) -> String { "localReaderBookmark_\(gid)" }
}
