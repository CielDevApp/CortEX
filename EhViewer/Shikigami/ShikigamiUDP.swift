import Foundation
import Network

// MARK: - UDP 送信 (NWConnection 1本)
//
// 間借り人原則 (指示書): 送信失敗はすべて黙殺し、アプリを壊さない。
// 送信先は open(destination:) で "IP:port" 文字列として渡される (ハードコード無し)。

final class ShikigamiUDP {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "shikigami.udp")
    private(set) var isOpen = false

    /// "IP:port" をパースして UDP コネクションを開く。不正な値なら何もしない。
    func open(destination: String) {
        close()
        let parts = destination.split(separator: ":")
        guard parts.count == 2,
              let port = NWEndpoint.Port(String(parts[1])) else { return }
        let host = NWEndpoint.Host(String(parts[0]))
        let conn = NWConnection(host: host, port: port, using: .udp)
        conn.start(queue: queue)
        connection = conn
        isOpen = true
    }

    /// 1行を打電。末尾に改行を付ける (母艦 bridge は行単位で受ける)。失敗黙殺。
    func send(_ line: String) {
        guard let conn = connection else { return }
        let data = Data((line + "\n").utf8)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection?.cancel()
        connection = nil
        isOpen = false
    }
}
