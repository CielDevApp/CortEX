import SwiftUI

#if canImport(UIKit)
import UIKit

/// アニメ画像表示用 UIImageView
/// isActive=true: UIImage.animatedImage(全フレーム展開) + startAnimating
/// isActive=false: 先頭フレームの静止画のみ
final class AnimatedSourceImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    private var animSource: AnimatedImageSource?
    private var currentSourceID: ObjectIdentifier?
    private var isActive: Bool = false
    /// 静止画→アニメ展開用バックグラウンドキュー
    private static let buildQueue = DispatchQueue(label: "anim.build", qos: .userInitiated)

    func setSource(_ source: AnimatedImageSource, isActive: Bool) {
        let sid = ObjectIdentifier(source)
        let sourceChanged = currentSourceID != sid
        let activeChanged = self.isActive != isActive
        guard sourceChanged || activeChanged || image == nil else { return }

        self.animSource = source
        self.currentSourceID = sid
        self.isActive = isActive

        stopAnimating()

        let maxDim = computeMaxPixelSize()
        LogManager.shared.log("Anim", "setSource frames=\(source.frameCount) active=\(isActive) srcChanged=\(sourceChanged) maxDim=\(Int(maxDim)) boundsW=\(Int(bounds.width))")

        // first frame は sync decode で即 image セット（メインスレッド ~20ms 覚悟、黒画面回避）
        if sourceChanged || image == nil {
            let t0 = CFAbsoluteTimeGetCurrent()
            if let first = source.frame(at: 0, maxPixelSize: maxDim) {
                self.image = UIImage(cgImage: first)
                LogManager.shared.log("Anim", "first frame SYNC (decode=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms size=\(first.width)x\(first.height))")
            } else {
                LogManager.shared.log("Anim", "first frame decode FAILED")
            }
        }

        guard isActive else { return }

        // 全フレームは background、完了時 sid 一致なら差し替え
        Self.buildQueue.async { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let animated = source.buildAnimatedImage(maxPixelSize: maxDim) else {
                LogManager.shared.log("Anim", "buildAnimatedImage FAILED")
                return
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let frames = animated.images?.count ?? 0
            let dur = animated.duration
            DispatchQueue.main.async {
                guard let self, self.currentSourceID == sid, self.isActive else {
                    LogManager.shared.log("Anim", "animated skip (build=\(ms)ms sid-mismatch or not active)")
                    return
                }
                self.image = animated
                self.startAnimating()
                LogManager.shared.log("Anim", "animated set (build=\(ms)ms frames=\(frames) dur=\(String(format: "%.2f", dur))s startAnim=\(self.isAnimating))")
            }
        }
    }

    private func computeMaxPixelSize() -> CGFloat {
        let w = bounds.width
        let h = bounds.height
        let d = max(w, h)
        if d <= 0 {
            return max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        }
        return d
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopAnimating()
        } else if isActive, !isAnimating, image?.images != nil {
            startAnimating()
        }
    }
}

/// リーダーセル用の軽量アニメビュー（ズーム無し）
struct AnimatedImageCellView: UIViewRepresentable {
    let source: AnimatedImageSource
    var isActive: Bool = true

    func makeUIView(context: Context) -> AnimatedSourceImageView {
        let iv = AnimatedSourceImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.setSource(source, isActive: isActive)
        return iv
    }

    func updateUIView(_ uiView: AnimatedSourceImageView, context: Context) {
        uiView.setSource(source, isActive: isActive)
    }
}

/// layoutSubviewsでconfigureForSizeをトリガーできるUIScrollViewサブクラス
final class LayoutNotifyingScrollView: UIScrollView {
    var onLayout: ((CGSize) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size.width > 0 && bounds.size.height > 0 {
            onLayout?(bounds.size)
        }
    }
}

/// アニメ再生用のズーム対応ビュー
struct AnimatedPageZoomableScrollView: UIViewRepresentable {
    let source: AnimatedImageSource
    @Binding var isAtMinZoom: Bool
    let onTapRegion: (TapRegion) -> Void

    func makeUIView(context: Context) -> LayoutNotifyingScrollView {
        let scrollView = LayoutNotifyingScrollView()
        scrollView.maximumZoomScale = 4.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear

        let imageView = AnimatedSourceImageView()
        imageView.frame = CGRect(origin: .zero, size: source.pixelSize)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true
        imageView.setSource(source, isActive: true)
        scrollView.addSubview(imageView)
        scrollView.contentSize = source.pixelSize

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.isAtMinZoomBinding = $isAtMinZoom
        context.coordinator.onTapRegion = onTapRegion

        let pixelSize = source.pixelSize
        scrollView.onLayout = { [weak coord = context.coordinator] _ in
            coord?.configureForSize(pixelSize)
        }

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: LayoutNotifyingScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        imageView.setSource(source, isActive: true)
        context.coordinator.isAtMinZoomBinding = $isAtMinZoom
        context.coordinator.onTapRegion = onTapRegion
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: AnimatedSourceImageView?
        weak var scrollView: UIScrollView?
        var isAtMinZoomBinding: Binding<Bool>?
        var onTapRegion: ((TapRegion) -> Void)?
        private var lastConfiguredSize: CGSize = .zero

        func configureForSize(_ pixelSize: CGSize) {
            guard let scrollView, let imageView else { return }
            let svSize = scrollView.bounds.size
            guard svSize.width > 0, svSize.height > 0 else { return }
            if lastConfiguredSize == svSize { return }
            lastConfiguredSize = svSize
            guard pixelSize.width > 0, pixelSize.height > 0 else { return }

            imageView.frame = CGRect(origin: .zero, size: pixelSize)
            scrollView.contentSize = pixelSize

            let scaleW = svSize.width / pixelSize.width
            let scaleH = svSize.height / pixelSize.height
            let minScale = min(scaleW, scaleH)

            scrollView.minimumZoomScale = minScale
            scrollView.maximumZoomScale = max(minScale * 4, 4.0)
            scrollView.zoomScale = minScale

            centerImage()
            isAtMinZoomBinding?.wrappedValue = true
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

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

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let atMin = scrollView.zoomScale <= scrollView.minimumZoomScale * 1.05
            guard atMin else { return }

            let location = gesture.location(in: scrollView)
            let width = scrollView.bounds.width
            let region: TapRegion
            if location.x < width * 0.33 {
                region = .left
            } else if location.x > width * 0.67 {
                region = .right
            } else {
                region = .center
            }
            onTapRegion?(region)
        }
    }
}
#endif
