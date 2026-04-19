import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct LogViewerView: View {
    @ObservedObject private var logManager = LogManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filterCategory = "All"
    @State private var searchText = ""

    private let categories = ["All", "Thumb", "Metal", "CoreML", "Auth", "LiveActivity", "Download", "Pipeline", "Reader", "App"]

    #if canImport(UIKit)
    /// Documents/logs/ に書き出し。FilesアプリのEhViewerフォルダから取り出せる（UIFileSharingEnabled有効）
    private func saveLogToDocuments() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = df.string(from: Date())
        let url = dir.appendingPathComponent("cortex_\(stamp).txt")
        do {
            try logManager.allText().write(to: url, atomically: true, encoding: .utf8)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            print("[LogExport] write failed: \(error)")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
    #endif

    private var filteredLogs: [LogEntry] {
        logManager.logs.filter { entry in
            (filterCategory == "All" || entry.category == filterCategory) &&
            (searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText) || entry.category.localizedCaseInsensitiveContains(searchText))
        }
    }

    private func color(for category: String) -> Color {
        switch category {
        case "Thumb": return .blue
        case "Metal": return .green
        case "CoreML": return .purple
        case "Auth": return .orange
        case "LiveActivity": return .red
        case "Download": return .cyan
        case "Pipeline": return .yellow
        case "Reader": return .mint
        case "App": return .gray
        default: return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // カテゴリフィルタ
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(categories, id: \.self) { cat in
                            Button {
                                filterCategory = cat
                            } label: {
                                Text(cat)
                                    .font(.caption2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(filterCategory == cat ? color(for: cat).opacity(0.3) : Color.gray.opacity(0.1))
                                    .clipShape(Capsule())
                                    .foregroundStyle(filterCategory == cat ? color(for: cat) : .secondary)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }

                // ログリスト
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredLogs) { entry in
                            HStack(alignment: .top, spacing: 4) {
                                Text(entry.timeString)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 75, alignment: .leading)

                                Text(entry.category)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(color(for: entry.category))
                                    .frame(width: 65, alignment: .leading)

                                Text(entry.message)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                        }
                    }
                }

                // ステータスバー
                HStack {
                    Text("\(filteredLogs.count) / \(logManager.logs.count) entries")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    #if canImport(UIKit)
                    Button {
                        UIPasteboard.general.string = logManager.allText()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption2)
                    }
                    #endif
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .searchable(text: $searchText, prompt: "Search logs...")
            .navigationTitle("Debug Log")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { logManager.clear() }
                }
                ToolbarItem(placement: .automatic) {
                    ShareLink(item: logManager.allText()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                #if canImport(UIKit)
                ToolbarItem(placement: .automatic) {
                    Button {
                        UIPasteboard.general.string = logManager.allText()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        saveLogToDocuments()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
                #endif
            }
        }
    }
}
