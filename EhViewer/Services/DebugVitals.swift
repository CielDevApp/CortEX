import SwiftUI
import Foundation

/// プロセスの物理メモリフットプリント(MB)。デバッグHUD用に公開
enum DebugVitals {
    static func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : -1
    }
}

/// 画面右上に常駐する小型デバッグHUD（debugLogEnabled 時のみ表示）
/// メモリMB / アクティブDL数 / DL合計速度 を 1秒毎に更新
struct DebugVitalsHUD: View {
    @AppStorage("debugLogEnabled") private var debugLogEnabled = false
    @ObservedObject private var dlManager = DownloadManager.shared
    @State private var memMB: Int = 0
    @State private var peakMemMB: Int = 0
    @State private var sampleTimer: Timer?

    var body: some View {
        if debugLogEnabled {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 9))
                    Text("\(memMB)MB (peak \(peakMemMB))")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(memColor)
                if !dlManager.activeDownloads.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 9))
                        Text("\(dlManager.activeDownloads.count)DL")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onAppear { startSampling() }
            .onDisappear { stopSampling() }
        }
    }

    private var memColor: Color {
        if memMB > 800 { return .red }
        if memMB > 500 { return .orange }
        return .white
    }

    private func startSampling() {
        sampleTimer?.invalidate()
        memMB = DebugVitals.memoryFootprintMB()
        peakMemMB = max(peakMemMB, memMB)
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let mb = DebugVitals.memoryFootprintMB()
            memMB = mb
            if mb > peakMemMB { peakMemMB = mb }
        }
    }

    private func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    private func formatSpeed(_ bps: Int64) -> String {
        let b = Double(bps)
        if b >= 1_000_000 { return String(format: "%.1fMB/s", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0fKB/s", b / 1_000) }
        return "\(bps)B/s"
    }
}
