import Foundation
import Combine

/// nh リーダーの大容量(標準画質)DL 進捗をページ単位で保持 (田中要望 2026-06-09)。
/// @State 辞書を escaping コールバックから更新できないため ObservableObject に持たせる。
final class NhPageProgressStore: ObservableObject {
    @Published var map: [Int: Double] = [:]
}
