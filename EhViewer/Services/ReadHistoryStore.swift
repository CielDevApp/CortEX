import Foundation
import Combine

/// ギャラリー既読管理 (2026-07-02)。詳細画面を開いた作品の gid を記録し、
/// 一覧タイトルのグレー表示に使う (田中要望で当日中にリーダー起動→詳細表示へ前倒し)。
/// リーダー側にも保険フックあり (プレビュー等の詳細を経ない経路)。
/// HistoryManager (閲覧履歴) や DL 済みフラグとは独立した概念。
///
/// - キーは "eh:{gid}" / "nh:{gid}" でサイト名前空間を分離。
///   E-Hentai と ExHentai は同一 gid 空間なので "eh:" を共有する。
/// - UserDefaults に [String] で永続化 (数千件規模なら十分軽い)。
///   肥大化したら persist()/init の 2 箇所を JSON ファイルに差し替えれば移行できる。
/// - 書き込みは既読追加時に即 save (クラッシュ / 強制終了でもロスしない)。
///   読み込みは init (初回アクセス時) の 1 回だけ。
/// - グレー表示 ON/OFF (UDKey.grayOutReadGalleries) は表示の抑制のみで、
///   OFF 中も記録は継続する (再 ON で既読表示が復活)。
@MainActor
final class ReadHistoryStore: ObservableObject {
    static let shared = ReadHistoryStore()

    enum Site: String {
        case eh
        case nh
    }

    @Published private(set) var readKeys: Set<String>

    private init() {
        readKeys = Set(UserDefaults.standard.stringArray(forKey: UDKey.readHistoryKeys) ?? [])
    }

    var count: Int { readKeys.count }

    /// 一覧セルからの既読判定。O(1) の Set lookup。
    func isRead(site: Site, gid: Int) -> Bool {
        readKeys.contains(key(site: site, gid: gid))
    }

    /// リーダー起動フックから呼ぶ。既読済みなら publish も save も走らない。
    func markAsRead(site: Site, gid: Int) {
        let k = key(site: site, gid: gid)
        guard !readKeys.contains(k) else { return }
        readKeys.insert(k)
        persist()
    }

    /// 設定画面の「既読履歴を全消去」。表示中の一覧には @Published 経由で即反映。
    func clearAll() {
        guard !readKeys.isEmpty else { return }
        readKeys.removeAll()
        persist()
    }

    private func key(site: Site, gid: Int) -> String { "\(site.rawValue):\(gid)" }

    private func persist() {
        UserDefaults.standard.set(Array(readKeys), forKey: UDKey.readHistoryKeys)
    }
}
