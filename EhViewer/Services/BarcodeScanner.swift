import AVFoundation
import Vision

/// Phase R-7: カメラ映像から ISBN(EAN-13) を検出。プレビュー非表示 (映像は画面に出さない)。
final class BarcodeScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()   // プレビュー表示のため公開
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.kanayayuutou.cortex.barcode", qos: .userInitiated)
    private var seen = Set<String>()

    /// ISBN(978/979 始まり 13桁) 検出時に main で呼ばれる
    var onISBN: ((String) -> Void)?
    /// タイトル等のOCR結果 (同人誌は ISBN を持たないため). main で呼ばれる
    var onText: (([String]) -> Void)?
    private var lastTextScan: TimeInterval = 0

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// 同じ本の再検出を許可するためのリセット
    func clearSeen() { queue.async { [weak self] in self?.seen.removeAll() } }

    /// タップ位置にフォーカス/露出を合わせる (p: プレビュー層で変換済みの device point 0-1)
    func focus(atDevicePoint p: CGPoint) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        queue.async { [weak self] in
            guard let self,
                  let dev = (self.session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            do {
                try dev.lockForConfiguration()
                if dev.isFocusPointOfInterestSupported {
                    dev.focusPointOfInterest = p
                    if dev.isFocusModeSupported(.autoFocus) { dev.focusMode = .autoFocus }
                }
                if dev.isExposurePointOfInterestSupported {
                    dev.exposurePointOfInterest = p
                    if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                }
                dev.unlockForConfiguration()
            } catch {}
        }
        #endif
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        // 接写ピント対策: マクロ自動切替できる仮想カメラを優先 (Triple→DualWide→Wide)。
        // builtInTripleCamera/DualWide は近接時に超広角へ自動切替し macro が効く (iOS 16+ default)。
        // ※ これら仮想カメラ種別は iOS/iPadOS 専用 (macOS/Catalyst では unavailable)。
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let cam = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        #else
        let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        #endif
        if let cam, let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
            // バーコード接写向け: 連続オートフォーカス + 近距離レンジ制限 (ピンボケ対策)
            do {
                try cam.lockForConfiguration()
                if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
                #if os(iOS) && !targetEnvironment(macCatalyst)
                // 近距離レンジ制限 / スムーズAF は iOS/iPadOS 専用 (Mac Catalyst では unavailable)
                if cam.isAutoFocusRangeRestrictionSupported { cam.autoFocusRangeRestriction = .near }
                if cam.isSmoothAutoFocusSupported { cam.isSmoothAutoFocusEnabled = true }
                #endif
                if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
                cam.unlockForConfiguration()
            } catch {}
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest { [weak self] req, _ in
            guard let self else { return }
            for obs in (req.results as? [VNBarcodeObservation] ?? []) {
                guard let payload = obs.payloadStringValue, payload.count == 13,
                      payload.hasPrefix("978") || payload.hasPrefix("979") else { continue }
                if self.seen.insert(payload).inserted {
                    let isbn = payload
                    DispatchQueue.main.async { self.onISBN?(isbn) }
                }
            }
        }
        request.symbologies = [.ean13]
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([request])

        // タイトル OCR (同人誌は ISBN バーコードが無い事が多い)。負荷軽減で約0.7s間引き。
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastTextScan > 0.7 {
            lastTextScan = now
            let textReq = VNRecognizeTextRequest { [weak self] req, _ in
                guard let self else { return }
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first }
                    .filter { $0.confidence > 0.4 }
                    .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 4 }
                if !lines.isEmpty { DispatchQueue.main.async { self.onText?(lines) } }
            }
            textReq.recognitionLevel = .accurate
            textReq.recognitionLanguages = ["ja", "en"]
            textReq.usesLanguageCorrection = true
            try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([textReq])
        }
    }
}
