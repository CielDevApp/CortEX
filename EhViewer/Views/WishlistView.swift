import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Phase R-7: ウィッシュリスト (バーコードスキャン/手動で集めた欲しい本)
struct WishlistView: View {
    @StateObject private var store = WishlistStore.shared
    @State private var showScanner = false
    @State private var showManualAdd = false
    @State private var manualTitle = ""
    @State private var copiedToast: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "ウィッシュリストは空です",
                        systemImage: "bookmark",
                        description: Text("右上の + からバーコードをスキャン、または手動で追加")
                    )
                } else {
                    List {
                        ForEach(store.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.headline)
                                if let a = item.author, !a.isEmpty {
                                    Text(a).font(.subheadline).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(item.source.rawValue.uppercased())
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary).cornerRadius(4)
                                    Spacer()
                                    Text(item.addedDate, style: .date)
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture { copyTitle(item.title) }
                        }
                        .onDelete { store.remove(at: $0) }
                    }
                }
            }
            .navigationTitle("ウィッシュリスト")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showScanner = true } label: {
                            Label("バーコードをスキャン", systemImage: "barcode.viewfinder")
                        }
                        Button { manualTitle = ""; showManualAdd = true } label: {
                            Label("手動で追加", systemImage: "plus")
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showScanner) { BarcodeScannerSheet() }
            .alert("手動で追加", isPresented: $showManualAdd) {
                TextField("タイトル", text: $manualTitle)
                Button("追加") { store.add(title: manualTitle, source: .manual) }
                Button("キャンセル", role: .cancel) {}
            }
            .overlay(alignment: .bottom) {
                if let c = copiedToast {
                    Text("「\(c)」をコピー")
                        .font(.caption)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: copiedToast)
        }
    }

    /// タップでタイトルをクリップボードにコピー (検索は手動で貼り付け)
    private func copyTitle(_ title: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = title
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        copiedToast = title
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            if copiedToast == title { copiedToast = nil }
        }
    }
}

/// バーコードスキャン用シート (カメラ映像は非表示)
struct BarcodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status: Status = .requesting
    @State private var foundTitle: String?
    @State private var foundAuthor: String?
    @State private var manualISBN = ""
    @State private var scanner = BarcodeScanner()
    @State private var ocrLines: [String] = []

    enum Status { case requesting, scanning, fetching, found, denied, failed }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                switch status {
                case .requesting:
                    ProgressView("カメラを準備中…")
                case .scanning:
                    #if os(iOS)
                    CameraPreview(session: scanner.session, onTapFocus: { dp in
                        scanner.focus(atDevicePoint: dp)
                    })
                    .frame(width: 300, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.4), lineWidth: 1))
                    #endif
                    Text("バーコード(ISBN)を枠内に / 画面タップでピント合わせ")
                        .font(.callout).multilineTextAlignment(.center)
                    Text("同人誌は ISBN が無い事が多い → 下の認識タイトルをタップ")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    ocrCandidatesView
                case .fetching:
                    ProgressView("書籍情報を取得中…")
                case .found:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.green)
                    Text(foundTitle ?? "").font(.title3).bold().multilineTextAlignment(.center)
                    if let a = foundAuthor, !a.isEmpty {
                        Text(a).foregroundStyle(.secondary)
                    }
                    Button("ウィッシュリストに追加") {
                        if let t = foundTitle {
                            WishlistStore.shared.add(title: t, author: foundAuthor, source: .isbn)
                        }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("もう一度スキャン") { resetScan() }
                case .denied:
                    Image(systemName: "video.slash")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("カメラへのアクセスが許可されていません")
                        .multilineTextAlignment(.center)
                    Text("設定 > Cort:EX > カメラ で許可してください")
                        .font(.caption).foregroundStyle(.tertiary)
                case .failed:
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("書籍情報が見つかりませんでした")
                    Button("もう一度スキャン") { resetScan() }
                }

                // ISBN 手入力フォールバック
                if status == .scanning || status == .failed {
                    HStack {
                        TextField("ISBN を手入力 (978…)", text: $manualISBN)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                        Button("検索") { handleISBN(manualISBN) }
                            .disabled(manualISBN.filter { $0.isNumber }.count < 10)
                    }
                    .padding(.horizontal)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("スキャン")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .task { await begin() }
        .onDisappear { scanner.stop() }
    }

    private func begin() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else { status = .denied; return }
        scanner.onISBN = { isbn in
            Task { @MainActor in handleISBN(isbn) }
        }
        scanner.onText = { lines in
            Task { @MainActor in
                guard status == .scanning else { return }
                // ISBN を含む行を検出したら自動で書誌取得へ (タップ不要・リスト揺れ回避)
                if let isbn = lines.lazy.compactMap({ extractISBN($0) }).first {
                    handleISBN(isbn)
                    return
                }
                // タイトル候補は accumulate (既出は動かさず安定。最大10件)
                for l in lines where !ocrLines.contains(l) && ocrLines.count < 10 {
                    ocrLines.append(l)
                }
            }
        }
        scanner.start()
        status = .scanning
    }

    /// OCR行が ISBN を含むなら数字13桁(978/979)or10桁を返す
    private func extractISBN(_ s: String) -> String? {
        let digits = s.filter { $0.isNumber }
        if digits.count == 13, digits.hasPrefix("978") || digits.hasPrefix("979") { return digits }
        if digits.count == 10 { return digits }
        return nil
    }

    private func handleISBN(_ raw: String) {
        let clean = raw.filter { $0.isNumber }
        guard clean.count >= 10 else { return }
        scanner.stop()
        status = .fetching
        Task {
            if let info = await BookInfoFetcher.fetch(isbn: clean) {
                foundTitle = info.title
                foundAuthor = info.author
                status = .found
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.success)  // スキャン成立の手応え
                #endif
            } else {
                status = .failed
                #if canImport(UIKit)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                #endif
            }
        }
    }

    private func resetScan() {
        foundTitle = nil
        foundAuthor = nil
        manualISBN = ""
        ocrLines = []
        scanner.clearSeen()
        scanner.start()
        status = .scanning
    }

    /// OCR で認識したタイトル候補 (タップでウィッシュリスト追加)
    @ViewBuilder
    private var ocrCandidatesView: some View {
        if !ocrLines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("認識したテキスト（タイトルをタップで追加）")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ocrLines, id: \.self) { line in
                    Button {
                        if let isbn = extractISBN(line) {
                            handleISBN(isbn)   // ISBN 行 → 書誌取得
                        } else {
                            WishlistStore.shared.add(title: line, source: .ocr)  // タイトル行 → そのまま追加
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: extractISBN(line) != nil ? "barcode" : "textformat")
                                .foregroundStyle(.secondary)
                            Text(line).lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
        }
    }
}

#if os(iOS)
import AVFoundation

/// Phase R-7: 読み取り時のカメラ小窓プレビュー
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTapFocus: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.view = v
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        context.coordinator.onTapFocus = onTapFocus
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTapFocus: onTapFocus) }

    final class Coordinator: NSObject {
        weak var view: PreviewView?
        var onTapFocus: ((CGPoint) -> Void)?
        init(onTapFocus: ((CGPoint) -> Void)?) { self.onTapFocus = onTapFocus }
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view else { return }
            let p = g.location(in: view)
            // レイヤー座標 → カメラ device 座標(0-1) に変換してフォーカス指定
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: p)
            onTapFocus?(devicePoint)
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
#endif
