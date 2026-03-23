import Foundation
import Combine

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: String
    let message: String

    var timeString: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

final class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published var logs: [LogEntry] = []
    private let maxEntries = 1000

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "debugLogEnabled")
    }

    func log(_ category: String, _ message: String) {
        // 常にprint（Xcodeコンソール用）
        print("[\(category)] \(message)")

        guard isEnabled else { return }

        let entry = LogEntry(timestamp: Date(), category: category, message: message)
        DispatchQueue.main.async {
            self.logs.append(entry)
            if self.logs.count > self.maxEntries {
                self.logs.removeFirst(self.logs.count - self.maxEntries)
            }
        }
    }

    func clear() {
        logs.removeAll()
    }

    func allText() -> String {
        logs.map { "[\($0.timeString)] [\($0.category)] \($0.message)" }.joined(separator: "\n")
    }
}
