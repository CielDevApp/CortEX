import Foundation
import SwiftUI
import CoreImage

// MARK: - スプライト画像キャッシュ（メモリ + ImageCacheのディスクキャッシュ）

/// isolation 方針 (A2-c, 2026-06-11):
/// - 型としては @MainActor (fetchingSprites は main 専用の重複 DL 防止フラグ)
/// - NSCache 系の読み書きメソッドと static メンバーは imageQueue / 背景デコード経路から
///   同期で使われるため nonisolated (NSCache / CIContext はスレッドセーフ)。
///   従来の暗黙時代と実行スレッドは不変。
@MainActor
final class SpriteCache {
    static let shared = SpriteCache()
    private let sprites = NSCache<NSURL, PlatformImage>()
    private let croppedCache = NSCache<NSString, PlatformImage>()
    /// フェッチ中のスプライト URL（重複 DL 防止、main 専用）
    var fetchingSprites: Set<URL> = []

    /// Metal GPU-backed CIContext（デコード・クロップ・リサイズ全てGPU実行）
    /// CIContext はスレッドセーフ (Apple doc 明記)。imageQueue から使うため (unsafe) 明示
    nonisolated(unsafe) static let ciContext: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    }()

    /// 表示用 CGImage 生成 (RGBA8 / sRGB 固定)。
    /// format 未指定の createCGImage は CIContext の作業フォーマット (拡張レンジ) の
    /// CGImage を返し、画面に出す瞬間の CA commit で main thread がピクセル変換を行う
    /// (1 ページ 100-200ms の MainStall = スクロール重さの真因、2026-06-10 実測)。
    /// 表示前提の画像は必ずこちらを使うこと。
    nonisolated(unsafe) static let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    nonisolated static func makeDisplayCGImage(_ ci: CIImage) -> CGImage? {
        ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: displayColorSpace)
    }

    /// 専用スレッド: 画像処理を協調プールから完全分離（UIスレッド飢餓防止）
    nonisolated static let imageQueue = DispatchQueue(label: "sprite-processing", qos: .userInitiated)

    /// ディスクキャッシュ用ディレクトリ (初期化以降は実質定数、imageQueue からも参照)
    nonisolated(unsafe) private static var spriteDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer/cache/sprites", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated(unsafe) private static var croppedDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("EhViewer/cache/cropped", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        sprites.countLimit = 30
        croppedCache.countLimit = 200
    }

    nonisolated private static func hashName(_ s: String) -> String {
        let h = s.utf8.reduce(into: UInt64(5381)) { acc, c in acc = acc &* 33 &+ UInt64(c) }
        return "\(h).jpg"
    }

    nonisolated func sprite(for url: URL) -> PlatformImage? {
        if let mem = sprites.object(forKey: url as NSURL) { return mem }
        // ディスクから復元（GPU CIContextで再デコード）
        let path = Self.spriteDir.appendingPathComponent(Self.hashName(url.absoluteString))
        guard let data = try? Data(contentsOf: path) else { return nil }
        if let ci = CIImage(data: data),
           let cg = Self.makeDisplayCGImage(ci) {
            let img = PlatformImage(cgImage: cg)
            sprites.setObject(img, forKey: url as NSURL)
            return img
        }
        return nil
    }

    nonisolated func setSprite(_ image: PlatformImage, for url: URL) {
        sprites.setObject(image, forKey: url as NSURL)
        // ディスク保存はバックグラウンドキューでJPEGエンコード（UIスレッド影響なし）
        Self.imageQueue.async {
            #if canImport(UIKit)
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            #elseif canImport(AppKit)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
            #endif
            let path = Self.spriteDir.appendingPathComponent(Self.hashName(url.absoluteString))
            try? data.write(to: path)
        }
    }

    nonisolated func croppedKey(url: URL, offsetX: CGFloat) -> String {
        "\(url.absoluteString)_\(Int(offsetX))"
    }

    /// メモリキャッシュのみ参照 (ディスクIO/デコードなし)。
    /// リーダーのスクロールパス (main 同期) 用: miss はバックグラウンド読込に回す前提。
    nonisolated func croppedImageInMemory(key: String) -> PlatformImage? {
        croppedCache.object(forKey: key as NSString)
    }

    nonisolated func croppedImage(key: String) -> PlatformImage? {
        if let mem = croppedCache.object(forKey: key as NSString) { return mem }
        let path = Self.croppedDir.appendingPathComponent(Self.hashName(key))
        guard let data = try? Data(contentsOf: path) else { return nil }
        if let ci = CIImage(data: data),
           let cg = Self.makeDisplayCGImage(ci) {
            let img = PlatformImage(cgImage: cg)
            croppedCache.setObject(img, forKey: key as NSString)
            return img
        }
        return nil
    }

    nonisolated func setCropped(_ image: PlatformImage, key: String) {
        croppedCache.setObject(image, forKey: key as NSString)
        Self.imageQueue.async {
            #if canImport(UIKit)
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            #elseif canImport(AppKit)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
            #endif
            let path = Self.croppedDir.appendingPathComponent(Self.hashName(key))
            try? data.write(to: path)
        }
    }
}
