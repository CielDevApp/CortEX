import SwiftUI

#if canImport(UIKit)
import UIKit
import VisionKit

struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    @Binding var isAtMinZoom: Bool
    var onZoomOutToMin: (() -> Void)? = nil

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.maximumZoomScale = 4.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.isAtMinZoomBinding = $isAtMinZoom

        context.coordinator.onZoomOutToMin = onZoomOutToMin

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // Live Text（iOS 16+）
        if ImageAnalyzer.isSupported {
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = .textSelection
            imageView.addInteraction(interaction)
            context.coordinator.interaction = interaction
            context.coordinator.startAnalysis(for: image)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        imageView.image = image
        context.coordinator.isAtMinZoomBinding = $isAtMinZoom

        DispatchQueue.main.async {
            context.coordinator.configureForImage(image)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        var isAtMinZoomBinding: Binding<Bool>?
        var interaction: ImageAnalysisInteraction?
        private var lastConfiguredSize: CGSize = .zero
        private let analyzer = ImageAnalyzer()

        func startAnalysis(for image: UIImage) {
            Task {
                let config = ImageAnalyzer.Configuration([.text])
                do {
                    let analysis = try await analyzer.analyze(image, configuration: config)
                    await MainActor.run {
                        interaction?.analysis = analysis
                    }
                } catch {
                    print("[LiveText] analysis failed: \(error)")
                }
            }
        }

        func configureForImage(_ image: UIImage) {
            guard let scrollView, let imageView else { return }
            let svSize = scrollView.bounds.size
            guard svSize.width > 0, svSize.height > 0 else { return }

            // 同じサイズなら再計算不要
            if lastConfiguredSize == svSize { return }
            lastConfiguredSize = svSize

            let imgSize = image.size
            guard imgSize.width > 0, imgSize.height > 0 else { return }

            imageView.frame = CGRect(origin: .zero, size: imgSize)
            scrollView.contentSize = imgSize

            let scaleW = svSize.width / imgSize.width
            let scaleH = svSize.height / imgSize.height
            let minScale = min(scaleW, scaleH)

            scrollView.minimumZoomScale = minScale
            scrollView.maximumZoomScale = max(minScale * 4, 4.0)
            scrollView.zoomScale = minScale

            centerImage()
            isAtMinZoomBinding?.wrappedValue = true
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage()
            let atMin = scrollView.zoomScale <= scrollView.minimumZoomScale * 1.05
            isAtMinZoomBinding?.wrappedValue = atMin
        }

        private func centerImage() {
            guard let scrollView, let imageView else { return }
            let svSize = scrollView.bounds.size
            let contentSize = scrollView.contentSize

            let insetX = max(0, (svSize.width - contentSize.width) / 2)
            let insetY = max(0, (svSize.height - contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
            imageView.frame.size = contentSize
        }

        /// ダブルタップでズームアウト→閉じるコールバック
        var onZoomOutToMin: (() -> Void)?

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale * 1.1 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                // ズームアウト完了後にオーバーレイを閉じる
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.onZoomOutToMin?()
                }
            } else {
                let point = gesture.location(in: scrollView.subviews.first)
                let targetScale = scrollView.minimumZoomScale * 2.5
                let zoomW = scrollView.bounds.width / targetScale
                let zoomH = scrollView.bounds.height / targetScale
                let rect = CGRect(
                    x: point.x - zoomW / 2,
                    y: point.y - zoomH / 2,
                    width: zoomW,
                    height: zoomH
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}
#endif

/// アニメGIF/WebP用の全画面オーバーレイ（ズーム+再生）
#if canImport(UIKit)
struct ZoomableAnimatedOverlay: View {
    let source: AnimatedImageSource
    let onClose: () -> Void

    @State private var isAtMinZoom = true
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AnimatedPageZoomableScrollView(
                source: source,
                isAtMinZoom: $isAtMinZoom,
                onTapRegion: { region in
                    if region == .center { onClose() }
                }
            )
            .ignoresSafeArea()
        }
        .offset(y: dragOffset)
        .opacity(max(0, 1.0 - abs(dragOffset) / 300.0))
        .gesture(
            isAtMinZoom
            ? DragGesture()
                .onChanged { value in dragOffset = value.translation.height }
                .onEnded { value in
                    if abs(value.translation.height) > 120 { onClose() }
                    else { withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 } }
                }
            : nil
        )
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        .transition(.opacity)
    }
}
#endif

/// タップした画像をフルスクリーンで拡大表示するオーバーレイ（常に全画面）
struct ZoomableImageOverlay: View {
    let image: PlatformImage
    let onClose: () -> Void

    @State private var isAtMinZoom = true
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if canImport(UIKit)
            ZoomableScrollView(image: image, isAtMinZoom: $isAtMinZoom, onZoomOutToMin: onClose)
                .ignoresSafeArea()
            #else
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
            #endif
        }
        .offset(y: dragOffset)
        .opacity(max(0, 1.0 - abs(dragOffset) / 300.0))
        .gesture(
            isAtMinZoom
            ? DragGesture()
                .onChanged { value in
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    if abs(value.translation.height) > 120 {
                        onClose()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffset = 0
                        }
                    }
                }
            : nil
        )
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        #endif
        .transition(.opacity)
    }
}
