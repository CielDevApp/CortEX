import Foundation
import Combine
import SwiftUI

/// ページ単位の画像ホルダー（@Publishedが独立しているので他ページの更新でre-renderされない）
@MainActor
final class PageImageHolder: ObservableObject {
    @Published var image: PlatformImage?
    @Published var isFailed = false
    @Published var failReason: String?
    @Published var isPlaceholder = false
    /// 翻訳処理中フラグ
    @Published var isTranslating = false
    /// 大容量 (標準画質/WebP) DL 進捗 (0...1)。-1 = 進捗なし/不明 (バー非表示)。田中要望 2026-06-09。
    /// ページ単位で持つことで、表示中ページと currentIndex のズレに影響されない。
    @Published var loadProgress: Double = -1
    /// アニメGIF/WebP用: ディスク上のファイルパス（rawDataはメモリに持たない）
    /// nilなら静止画として扱う
    @Published var animatedFileURL: URL?
    /// GalleryReader (オンライン E-Hentai) のアニメ WebP 生 Data。
    /// 静止画として imageData は保持しないが、アニメ WebP のみ ▶ ボタン再生用に保持。
    /// アプリ起動時に一括削除される tmp 経由の変換パイプラインに渡す用。
    @Published var animatedWebPData: Data?

    /// 翻訳焼き込み前の元画像
    var originalImage: PlatformImage?
    /// 翻訳焼き込み済み画像（メモリ上）
    var translatedImage: PlatformImage?
    /// 翻訳モードが有効か（setLoadedで自動切替するため）
    var translationActive = false
    /// ディスク退避済みフラグ（translatedImageをディスクに退避した場合true）
    var translatedImageEvicted = false
    /// ディスク退避先キー（gid_page）
    var translatedCacheKey: String?

    func setLoaded(_ img: PlatformImage, placeholder: Bool = false) {
        isFailed = false
        failReason = nil
        isPlaceholder = placeholder
        // フル画像が来たら進捗バーを消す (placeholder=サムネ時は DL 継続中なので維持)。
        if !placeholder { loadProgress = -1 }

        if !placeholder {
            originalImage = img
            if translationActive, let translated = translatedImage {
                image = translated
            } else if translationActive, translatedImageEvicted, let key = translatedCacheKey {
                if let restored = Self.loadEvicted(key: key) {
                    translatedImage = restored
                    translatedImageEvicted = false
                    image = restored
                } else {
                    image = img
                }
            } else {
                image = img
            }
        } else {
            image = img
        }
    }

    func setFailed(_ reason: String) {
        isFailed = true
        failReason = reason
    }

    /// ビットマップ系プロパティの一括解放。
    /// image だけ nil にしても originalImage/translatedImage が同一ビットマップを retain し続け、
    /// distance>20 の部分解放が実質無効だった (リーダー閉鎖後メモリ未解放・3度目指摘の真因の一つ)。
    /// 翻訳焼き込みは TranslationService の block キャッシュから再生成できるため破棄してよい。
    /// animatedFileURL は軽量な参照なので維持 (nil にすると再訪時に静画扱いになる既知問題があるため)。
    func releaseBitmaps() {
        image = nil
        originalImage = nil
        translatedImage = nil
        animatedWebPData = nil
        loadProgress = -1
    }

    func setLoading() {
        if image == nil {}
    }

    /// 翻訳ON: 焼き込み済み画像に切替
    func showTranslated() {
        translationActive = true
        if let translated = translatedImage {
            image = translated
        } else if translatedImageEvicted, let key = translatedCacheKey {
            if let restored = Self.loadEvicted(key: key) {
                translatedImage = restored
                translatedImageEvicted = false
                image = restored
            }
        }
    }

    /// 翻訳OFF: 元画像に戻す
    func showOriginal() {
        translationActive = false
        if let original = originalImage {
            image = original
        }
    }

    /// translatedImageをディスクに退避してメモリ解放
    func evictTranslatedImage() {
        guard let translated = translatedImage, let key = translatedCacheKey else { return }
        Self.saveEvicted(image: translated, key: key)
        translatedImage = nil
        translatedImageEvicted = true
    }

    /// translatedImageをディスクから復元
    func restoreTranslatedImage() {
        guard translatedImageEvicted, let key = translatedCacheKey else { return }
        if let restored = Self.loadEvicted(key: key) {
            translatedImage = restored
            translatedImageEvicted = false
            if translationActive { image = restored }
        }
    }

    // MARK: - ディスク退避

    private static var evictDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer/translated_cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func saveEvicted(image: PlatformImage, key: String) {
        #if canImport(UIKit)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let path = evictDir.appendingPathComponent("\(key).jpg")
        try? data.write(to: path)
        #endif
    }

    private static func loadEvicted(key: String) -> PlatformImage? {
        let path = evictDir.appendingPathComponent("\(key).jpg")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return PlatformImage(data: data)
    }
}
