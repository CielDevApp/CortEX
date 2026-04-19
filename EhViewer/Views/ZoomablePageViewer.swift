import SwiftUI

#if canImport(UIKit)
import UIKit

/// 横モード用: ページング対応全画面ズームビューア
/// ZoomableScrollViewにタップ領域判定を内蔵（ピンチと干渉しない）
struct ZoomablePageViewer: View {
    let viewModel: ReaderViewModel
    let initialPage: Int
    let onClose: () -> Void
    let onPageChange: (Int) -> Void

    @State private var currentPage: Int
    @State private var isAtMinZoom = true
    @AppStorage("readingOrder") private var readingOrder = 1

    init(viewModel: ReaderViewModel, initialPage: Int, onClose: @escaping () -> Void, onPageChange: @escaping (Int) -> Void) {
        self.viewModel = viewModel
        self.initialPage = initialPage
        self.onClose = onClose
        self.onPageChange = onPageChange
        self._currentPage = State(initialValue: initialPage)
    }

    private func imageFor(page: Int) -> PlatformImage? {
        viewModel.holder(for: page).image ?? viewModel.holder(for: page).originalImage
    }

    private func animatedSourceFor(page: Int) -> AnimatedImageSource? {
        viewModel.holder(for: page).animatedSource
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let animSrc = animatedSourceFor(page: currentPage) {
                AnimatedPageZoomableScrollView(
                    source: animSrc,
                    isAtMinZoom: $isAtMinZoom,
                    onTapRegion: { region in
                        handleTap(region)
                    }
                )
                .ignoresSafeArea()
                .id(currentPage)
            } else if let img = imageFor(page: currentPage) {
                PageZoomableScrollView(
                    image: img,
                    isAtMinZoom: $isAtMinZoom,
                    onTapRegion: { region in
                        handleTap(region)
                    }
                )
                .ignoresSafeArea()
                .id(currentPage)
            } else {
                // 未ロード: タップで閉じる/ページ送り可能にする
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let width = UIScreen.main.bounds.width
                        if location.x < width * 0.33 {
                            handleTap(.left)
                        } else if location.x > width * 0.67 {
                            handleTap(.right)
                        } else {
                            handleTap(.center)
                        }
                    }
            }

            // ページ番号（等倍時のみ）
            if isAtMinZoom {
                VStack {
                    Spacer()
                    Text("\(currentPage + 1) / \(viewModel.totalPages)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 8)
                }
            }
        }
        .onChange(of: currentPage) { _, newPage in
            onPageChange(newPage)
            viewModel.onAppear(index: newPage)
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        .transition(.opacity)
    }

    private func handleTap(_ region: TapRegion) {
        guard isAtMinZoom else { return }
        switch region {
        case .left:
            let dir = readingOrder == 1 ? 1 : -1
            goToPage(currentPage + dir)
        case .center:
            onClose()
        case .right:
            let dir = readingOrder == 1 ? -1 : 1
            goToPage(currentPage + dir)
        }
    }

    private func goToPage(_ page: Int) {
        let clamped = max(0, min(page, viewModel.totalPages - 1))
        guard clamped != currentPage else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentPage = clamped
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - タップ領域

enum TapRegion {
    case left, center, right
}

/// ピンチ/ダブルタップズーム + シングルタップ領域判定を内蔵したUIScrollView
struct PageZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    @Binding var isAtMinZoom: Bool
    let onTapRegion: (TapRegion) -> Void

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
        context.coordinator.onTapRegion = onTapRegion

        // シングルタップ（ページ送り/閉じる）— 即発火（ダブルタップ待ち不要）
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        scrollView.addGestureRecognizer(singleTap)

        // Live Textは無効（ページ送り用ビューアのため）

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        imageView.image = image
        context.coordinator.isAtMinZoomBinding = $isAtMinZoom
        context.coordinator.onTapRegion = onTapRegion

        DispatchQueue.main.async {
            context.coordinator.configureForImage(image)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        var isAtMinZoomBinding: Binding<Bool>?
        var onTapRegion: ((TapRegion) -> Void)?
        private var lastConfiguredSize: CGSize = .zero


        func configureForImage(_ image: UIImage) {
            guard let scrollView, let imageView else { return }
            let svSize = scrollView.bounds.size
            guard svSize.width > 0, svSize.height > 0 else { return }
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
            // 等倍時のみタップ領域判定
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
