import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct BenchmarkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phase: BenchPhase = .idle
    @State private var smallImage: PlatformImage?
    @State private var largeImage: PlatformImage?
    @State private var flashOpacity: Double = 0
    @State private var currentRun = 0
    @State private var progress: Double = 0
    @State private var smallCI: Double = 0
    @State private var smallMetal: Double = 0
    @State private var largeCI: Double = 0
    @State private var largeMetal: Double = 0
    @State private var metalResultImage: PlatformImage?
    @State private var hasLarge = false

    private let runs = 5
    private enum BenchPhase { case idle, running, done }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        if phase == .idle {
                            idleView
                        } else if phase == .running {
                            runningView
                        } else {
                            doneView
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .onAppear { loadImages() }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 16) {
            // テスト画像プレビュー
            HStack(spacing: 12) {
                if let s = smallImage {
                    VStack(spacing: 4) {
                        Image(platformImage: s).resizable().aspectRatio(contentMode: .fit)
                            .frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("Small \(s.pixelWidth)×\(s.pixelHeight)")
                            .font(.caption2).foregroundStyle(.gray)
                    }
                }
                if let l = largeImage {
                    VStack(spacing: 4) {
                        Image(platformImage: l).resizable().aspectRatio(contentMode: .fit)
                            .frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("Large \(l.pixelWidth)×\(l.pixelHeight)")
                            .font(.caption2).foregroundStyle(.gray)
                    }
                }
            }

            if smallImage != nil {
                Button { startBenchmark() } label: {
                    Label("Run Benchmark", systemImage: "bolt.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                        .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Text("CIFilter vs Metal × \(runs) runs")
                    .font(.caption2).foregroundStyle(.gray)
            } else {
                Text("No test images available").foregroundStyle(.gray)
            }
        }
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bolt.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, isActive: true)

            Text("Benchmarking...")
                .font(.title3.bold())
                .foregroundStyle(.white)

            ProgressView(value: progress)
                .tint(.blue)
                .padding(.horizontal, 40)

            Text("\(currentRun) / \(totalTests)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.gray)

            #if os(iOS)
            Text(Self.deviceModel())
                .font(.caption2)
                .foregroundStyle(.gray.opacity(0.6))
            #endif

            Spacer()
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 12) {
            // 結果カード: Small / Large 横並び
            HStack(spacing: 8) {
                resultCard(title: "Small", size: smallImage, ci: smallCI, metal: smallMetal)
                if hasLarge {
                    resultCard(title: "Large", size: largeImage, ci: largeCI, metal: largeMetal)
                }
            }

            // Before / After
            if let orig = smallImage, let metal = metalResultImage {
                HStack(spacing: 8) {
                    VStack(spacing: 2) {
                        Image(platformImage: orig).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 120).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Original").font(.caption2).foregroundStyle(.gray)
                    }
                    VStack(spacing: 2) {
                        Image(platformImage: metal).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 120).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Metal").font(.caption2).foregroundStyle(.gray)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
            }

            // デバイス + リトライ
            HStack {
                #if os(iOS)
                Text(Self.deviceModel()).font(.caption2).foregroundStyle(.gray)
                #endif
                Spacer()
                Button { startBenchmark() } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.blue).foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Result Card

    private func resultCard(title: String, size: PlatformImage?, ci: Double, metal: Double) -> some View {
        let metalWins = metal < ci * 0.99
        let speedup = ci > 0 && metal > 0 ? (metalWins ? ci / metal : metal / ci) : 0
        let winner = metalWins ? "Metal" : "CIFilter"

        return VStack(spacing: 6) {
            HStack {
                Text(title).font(.caption.bold()).foregroundStyle(.white)
                if let img = size {
                    Text("\(img.pixelWidth)×\(img.pixelHeight)")
                        .font(.system(size: 9)).foregroundStyle(.gray)
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Circle().fill(.cyan).frame(width: 6, height: 6)
                Text("Metal").font(.system(size: 10)).foregroundStyle(.cyan)
                Spacer()
                Text(String(format: "%.1fms", metal))
                    .font(.system(size: metalWins ? 20 : 14, weight: .bold, design: .rounded))
                    .foregroundStyle(metalWins ? .white : .white.opacity(0.5))
                if metalWins { Text("⚡").font(.caption) }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text("CIFilter").font(.system(size: 10)).foregroundStyle(.orange)
                Spacer()
                Text(String(format: "%.1fms", ci))
                    .font(.system(size: !metalWins ? 20 : 14, weight: .bold, design: .rounded))
                    .foregroundStyle(!metalWins ? .white : .white.opacity(0.5))
                if !metalWins { Text("⚡").font(.caption) }
            }

            if speedup > 1 {
                Text(String(format: "%@ %.1fx", winner, speedup))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
    }

    private var totalTests: Int { (hasLarge ? 4 : 2) * runs }

    // MARK: - Logic

    #if os(iOS)
    static func deviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let map: [String: String] = [
            // iPhone
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            // iPad mini
            "iPad11,1": "iPad mini 5", "iPad11,2": "iPad mini 5",
            "iPad14,1": "iPad mini 6", "iPad14,2": "iPad mini 6",
            "iPad16,1": "iPad mini 7 (A17 Pro)", "iPad16,2": "iPad mini 7 (A17 Pro)",
            // iPad Air
            "iPad13,16": "iPad Air 5 (M1)", "iPad13,17": "iPad Air 5 (M1)",
            "iPad14,8": "iPad Air 11\" (M2)", "iPad14,9": "iPad Air 11\" (M2)",
            "iPad14,10": "iPad Air 13\" (M2)", "iPad14,11": "iPad Air 13\" (M2)",
            // iPad Pro
            "iPad13,4": "iPad Pro 11\" (M1)", "iPad13,5": "iPad Pro 11\" (M1)",
            "iPad13,8": "iPad Pro 12.9\" (M1)", "iPad13,9": "iPad Pro 12.9\" (M1)",
            "iPad14,3": "iPad Pro 11\" (M2)", "iPad14,4": "iPad Pro 11\" (M2)",
            "iPad14,5": "iPad Pro 12.9\" (M2)", "iPad14,6": "iPad Pro 12.9\" (M2)",
            "iPad16,3": "iPad Pro 11\" (M4)", "iPad16,4": "iPad Pro 11\" (M4)",
            "iPad16,5": "iPad Pro 13\" (M4)", "iPad16,6": "iPad Pro 13\" (M4)",
        ]
        let model = map[machine] ?? machine
        let chip = ProcessInfo.processInfo.processorCount > 0 ? "\(ProcessInfo.processInfo.processorCount)-core" : ""
        let ram = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        return "\(model) / \(ram)GB / \(os)"
    }
    #endif

    private func loadImages() {
        for g in FavoritesCache.shared.load() {
            if let url = g.coverURL, let img = ImageCache.shared.image(for: url) {
                smallImage = img; break
            }
        }
        for (_, meta) in DownloadManager.shared.downloads {
            if let img = DownloadManager.shared.loadLocalImage(gid: meta.gid, page: 0) {
                largeImage = img; hasLarge = true; break
            }
        }
    }

    private func startBenchmark() {
        phase = .running; currentRun = 0; progress = 0
        smallCI = 0; smallMetal = 0; largeCI = 0; largeMetal = 0

        Task.detached(priority: .userInitiated) {
            let total = totalTests
            if let img = smallImage {
                let (ci, mt, mtImg) = await bench(img, total: total, offset: 0)
                await MainActor.run { smallCI = ci; smallMetal = mt; metalResultImage = mtImg }
            }
            if let img = largeImage {
                let (ci, mt, _) = await bench(img, total: total, offset: hasLarge ? runs * 2 : 0)
                await MainActor.run { largeCI = ci; largeMetal = mt }
            }
            await MainActor.run { phase = .done }
        }
    }

    private func bench(_ image: PlatformImage, total: Int, offset: Int) async -> (ci: Double, metal: Double, metalImg: PlatformImage?) {
        var ciTimes: [Double] = []
        var metalTimes: [Double] = []
        var lastMetal: PlatformImage?

        for i in 0..<runs {
            let r: PlatformImage? = autoreleasepool {
                let s = CFAbsoluteTimeGetCurrent()
                let result = LanczosUpscaler.shared.enhanceFilter(image)
                ciTimes.append((CFAbsoluteTimeGetCurrent() - s) * 1000)
                return result
            }
            await MainActor.run {
                currentRun = offset + i + 1; progress = Double(currentRun) / Double(total)
                flash()
            }
            let _ = r // keep alive
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for i in 0..<runs {
            let r: PlatformImage? = autoreleasepool {
                let s = CFAbsoluteTimeGetCurrent()
                let result = MetalImageProcessor.shared.process(image, sharpen: true, hdr: true, toneCurve: true, vibrance: true, localTone: true)
                metalTimes.append((CFAbsoluteTimeGetCurrent() - s) * 1000)
                if let result { lastMetal = result }
                return result
            }
            await MainActor.run {
                currentRun = offset + runs + i + 1; progress = Double(currentRun) / Double(total)
                flash()
            }
            let _ = r
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return (ciTimes.reduce(0, +) / Double(runs), metalTimes.reduce(0, +) / Double(runs), lastMetal)
    }

    private func flash() {
        flashOpacity = 0.5
        withAnimation(.easeOut(duration: 0.15)) { flashOpacity = 0 }
    }
}
