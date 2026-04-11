import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit

/// UIPageViewController ベースの横ページめくりリーダー（iPad見開き対応）
struct PagedReaderView: UIViewControllerRepresentable {
    let totalPages: Int
    @Binding var currentPage: Int
    @Binding var showControls: Bool
    let readingOrder: Int // 0:左綴じ, 1:右綴じ
    let imageForPage: (Int) -> PlatformImage?
    let onPageAppear: (Int) -> Void
    var onDismiss: (() -> Void)? = nil
    /// ダブルタップでズーム表示（現在表示中の画像を渡す）
    var onZoomImage: ((PlatformImage) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 0]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .black

        let initialVC = context.coordinator.makePageVC(for: currentPage)
        pvc.setViewControllers([initialVC], direction: .forward, animated: false)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleVerticalPan(_:)))
        pan.delegate = context.coordinator
        pvc.view.addGestureRecognizer(pan)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        pvc.view.addGestureRecognizer(longPress)

        // 端タップでページ送り
        let edgeTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleEdgeTap(_:)))
        edgeTap.numberOfTapsRequired = 1
        // ダブルタップ（ズーム）との干渉回避：エリアで分けるのでrequire(toFail:)不要
        pvc.view.addGestureRecognizer(edgeTap)

        context.coordinator.pageViewController = pvc

        // 画面回転監視
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.orientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )

        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        if let currentVC = pvc.viewControllers?.first as? ReaderPageVC,
           currentVC.pageIndex != currentPage {
            let direction: UIPageViewController.NavigationDirection =
                currentPage > currentVC.pageIndex ? .forward : .reverse
            let newVC = coord.makePageVC(for: currentPage)
            pvc.setViewControllers([newVC], direction: direction, animated: false)
            // normalizeIndexでページが正規化された場合、currentPageを実際の表示ページに同期
            if newVC.pageIndex != currentPage {
                DispatchQueue.main.async {
                    self.currentPage = newVC.pageIndex
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - 見開き判定

    /// iPad横画面で見開きモードかどうか
    static var isSpreadMode: Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        guard let size = scene?.windows.first?.bounds.size else { return false }
        return size.width > size.height
    }

    /// 見開き時のページラベル生成（例: "5-6 / 100"、単独時: "1 / 100"）
    static func spreadPageLabel(currentPage: Int, totalPages: Int, readingOrder: Int, imageForPage: ((Int) -> PlatformImage?)? = nil) -> String {
        guard isSpreadMode, currentPage > 0 else {
            return "\(currentPage + 1) / \(totalPages)"
        }

        // 横長チェック
        let isWide: (Int) -> Bool = { idx in
            guard let provider = imageForPage, let img = provider(idx) else { return false }
            return img.size.width > img.size.height
        }

        if isWide(currentPage) {
            return "\(currentPage + 1) / \(totalPages)"
        }

        // normalizeIndexと同じロジックでペア先頭を計算
        var pairStart = 1
        var i = 1
        while i <= currentPage {
            if isWide(i) { i += 1; pairStart = i; continue }
            if i == currentPage { break }
            let next = i + 1
            if next <= currentPage && !isWide(next) {
                i = next + 1; pairStart = i
            } else {
                i += 1; pairStart = i
            }
        }

        let pairEnd = pairStart + 1
        if pairEnd >= totalPages || isWide(pairEnd) {
            return "\(pairStart + 1) / \(totalPages)"
        }

        let left = min(pairStart, pairEnd) + 1
        let right = max(pairStart, pairEnd) + 1
        return "\(left)-\(right) / \(totalPages)"
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PagedReaderView
        weak var pageViewController: UIPageViewController?

        init(_ parent: PagedReaderView) {
            self.parent = parent
        }

        /// 見開きモードかどうか
        var isSpread: Bool { PagedReaderView.isSpreadMode }

        /// 画像が横長かどうか（見開き扱い→単独表示）
        func isWideImage(at index: Int) -> Bool {
            guard let img = parent.imageForPage(index) else { return false }
            return img.size.width > img.size.height
        }

        /// 代表ページインデックス（横長画像でペアリングがリセットされる）
        func normalizeIndex(_ index: Int) -> Int {
            guard isSpread, index > 0 else { return index }
            if isWideImage(at: index) { return index }

            // index 0(表紙)は単独。1から順にペアリングを計算
            var pairStart = 1
            var i = 1
            while i <= index {
                if isWideImage(at: i) {
                    i += 1
                    pairStart = i
                    continue
                }
                if i == index { return pairStart }
                // ペアの2ページ目を消費
                let next = i + 1
                if next <= index && !isWideImage(at: next) {
                    i = next + 1
                    pairStart = i
                } else {
                    i += 1
                    pairStart = i
                }
            }
            return index
        }

        /// 見開きペアを計算（表紙=単独、横長=単独、それ以外=2ページ組）
        func spreadPages(for index: Int) -> (left: Int, right: Int?) {
            guard isSpread else { return (index, nil) }
            if index == 0 { return (0, nil) }
            if isWideImage(at: index) { return (index, nil) }

            let norm = normalizeIndex(index)
            let right = norm + 1

            if right >= parent.totalPages || isWideImage(at: right) {
                return (norm, nil)
            }

            if parent.readingOrder == 1 {
                return (right, norm)
            } else {
                return (norm, right)
            }
        }

        /// 次の見開きグループの代表ページ
        func nextSpreadIndex(from index: Int) -> Int? {
            let norm = normalizeIndex(index)
            let pair = spreadPages(for: norm)
            let advance = pair.right != nil ? norm + 2 : norm + 1
            return advance < parent.totalPages ? advance : nil
        }

        /// 前の見開きグループの代表ページ
        func prevSpreadIndex(from index: Int) -> Int? {
            let norm = normalizeIndex(index)
            if norm <= 0 { return nil }
            let prev = norm - 1
            let prevNorm = normalizeIndex(prev)
            return prevNorm >= 0 ? prevNorm : nil
        }

        func makePageVC(for index: Int) -> ReaderPageVC {
            let vc = ReaderPageVC()
            let norm = normalizeIndex(index)
            vc.pageIndex = norm
            vc.imageProvider = parent.imageForPage
            vc.onZoomImage = parent.onZoomImage

            if isSpread {
                let pair = spreadPages(for: norm)
                vc.setupSpreadView(
                    leftIndex: pair.left,
                    rightIndex: pair.right,
                    imageProvider: parent.imageForPage
                )
                // onPageAppearはviewDidAppearで呼ぶ（プリフェッチ時の無駄な呼び出し防止）
                vc.onDidAppear = { [weak self] in
                    self?.parent.onPageAppear(pair.left)
                    if let r = pair.right { self?.parent.onPageAppear(r) }
                }
            } else {
                vc.image = parent.imageForPage(norm)
                vc.setupImageView()
                vc.onDidAppear = { [weak self] in
                    self?.parent.onPageAppear(norm)
                }
            }

            vc.view.backgroundColor = .black
            return vc
        }

        // MARK: - DataSource

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? ReaderPageVC else { return nil }
            let prev: Int?
            if parent.readingOrder == 1 {
                prev = nextSpreadIndex(from: vc.pageIndex)
            } else {
                prev = prevSpreadIndex(from: vc.pageIndex)
            }
            guard let p = prev else { return nil }
            return makePageVC(for: p)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? ReaderPageVC else { return nil }
            let next: Int?
            if parent.readingOrder == 1 {
                next = prevSpreadIndex(from: vc.pageIndex)
            } else {
                next = nextSpreadIndex(from: vc.pageIndex)
            }
            guard let n = next else { return nil }
            return makePageVC(for: n)
        }

        // MARK: - Delegate

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed,
                  let vc = pvc.viewControllers?.first as? ReaderPageVC else { return }
            self.pageViewController = pvc
            DispatchQueue.main.async {
                self.parent.currentPage = vc.pageIndex
            }
        }

        // MARK: - 画面回転

        @objc func orientationChanged() {
            guard let pvc = pageViewController,
                  let currentVC = pvc.viewControllers?.first as? ReaderPageVC else { return }
            let currentIdx = currentVC.pageIndex
            // 少し遅延して回転完了を待つ
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let newVC = self.makePageVC(for: currentIdx)
                pvc.setViewControllers([newVC], direction: .forward, animated: false)
            }
        }

        // MARK: - ジェスチャー

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.parent.showControls.toggle()
                    }
                }
            }
        }

        @objc func handleEdgeTap(_ gesture: UITapGestureRecognizer) {
            guard let pvc = pageViewController, let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let width = view.bounds.width
            let quarter = width / 4

            if location.x < quarter {
                // 左端タップ → 戻る（goForward/goBackward内でreadingOrder考慮済み）
                goBackward(pvc: pvc)
            } else if location.x > width - quarter {
                // 右端タップ → 進む
                goForward(pvc: pvc)
            } else {
                // 中央タップ → コントロール表示切替
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.parent.showControls.toggle()
                    }
                }
            }
        }

        private func goForward(pvc: UIPageViewController) {
            guard let currentVC = pvc.viewControllers?.first as? ReaderPageVC else { return }
            let next: Int?
            if parent.readingOrder == 1 {
                next = prevSpreadIndex(from: currentVC.pageIndex)
            } else {
                next = nextSpreadIndex(from: currentVC.pageIndex)
            }
            guard let n = next else { return }
            let newVC = makePageVC(for: n)
            pvc.setViewControllers([newVC], direction: .forward, animated: false)
            DispatchQueue.main.async {
                self.parent.currentPage = n
            }
        }

        private func goBackward(pvc: UIPageViewController) {
            guard let currentVC = pvc.viewControllers?.first as? ReaderPageVC else { return }
            let prev: Int?
            if parent.readingOrder == 1 {
                prev = nextSpreadIndex(from: currentVC.pageIndex)
            } else {
                prev = prevSpreadIndex(from: currentVC.pageIndex)
            }
            guard let p = prev else { return }
            let newVC = makePageVC(for: p)
            pvc.setViewControllers([newVC], direction: .reverse, animated: false)
            DispatchQueue.main.async {
                self.parent.currentPage = p
            }
        }

        @objc func handleVerticalPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)

            switch gesture.state {
            case .changed:
                view.transform = CGAffineTransform(translationX: 0, y: translation.y)
                view.alpha = max(0, 1.0 - abs(translation.y) / 300.0)
            case .ended, .cancelled:
                if abs(translation.y) > 120 {
                    parent.onDismiss?()
                } else {
                    UIView.animate(withDuration: 0.2) {
                        view.transform = .identity
                        view.alpha = 1
                    }
                }
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.y) > abs(velocity.x) * 1.5
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return false
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// 1ページ or 見開き2ページ分のViewController
class ReaderPageVC: UIViewController {
    var pageIndex: Int = 0
    var image: PlatformImage?
    var imageProvider: ((Int) -> PlatformImage?)?
    private var imageView: UIImageView?
    private var spinner: UIActivityIndicatorView?
    private var updateTimer: Timer?

    // 見開き用
    private var leftImageView: UIImageView?
    private var rightImageView: UIImageView?
    private var leftIndex: Int?
    private var rightIndex: Int?
    private var isSpreadLayout = false
    /// ダブルタップでズーム
    var onZoomImage: ((PlatformImage) -> Void)?
    /// 表示時コールバック（onPageAppear遅延実行用）
    var onDidAppear: (() -> Void)?

    /// 単一ページ表示
    func setupImageView() {
        isSpreadLayout = false
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = .black
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: view.topAnchor),
            iv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            iv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        iv.image = image
        imageView = iv

        addDoubleTapZoom()
    }

    /// 見開き表示（左右2ページ）
    func setupSpreadView(leftIndex: Int, rightIndex: Int?, imageProvider: @escaping (Int) -> PlatformImage?) {
        isSpreadLayout = true
        self.leftIndex = leftIndex
        self.rightIndex = rightIndex
        self.imageProvider = imageProvider

        self.leftIndex = leftIndex
        self.rightIndex = rightIndex

        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = .black
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: view.topAnchor),
            iv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            iv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        imageView = iv

        // 合成は表示時に実行（プリフェッチ時の無駄な合成を防止）
        addDoubleTapZoom()
    }

    private func addSpinner() {
        guard spinner == nil else { return }
        let sp = UIActivityIndicatorView(style: .medium)
        sp.color = .white
        sp.translatesAutoresizingMaskIntoConstraints = false
        sp.startAnimating()
        view.addSubview(sp)
        NSLayoutConstraint.activate([
            sp.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sp.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner = sp
    }

    private func startImagePolling() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForImage()
        }
    }

    private func checkForImage() {
        guard let provider = imageProvider else { return }

        if isSpreadLayout {
            updateSpreadImage()
            let leftLoaded = leftIndex.flatMap { provider($0) } != nil
            let rightLoaded = rightIndex == nil || rightIndex.flatMap { provider($0) } != nil
            if leftLoaded && rightLoaded {
                spinner?.stopAnimating()
                spinner?.removeFromSuperview()
                spinner = nil
            }
        } else {
            if let newImg = provider(pageIndex) {
                if imageView?.image !== newImg {
                    imageView?.image = newImg
                    spinner?.stopAnimating()
                    spinner?.removeFromSuperview()
                    spinner = nil
                }
            }
        }
    }

    /// 左右ページを1枚に合成して表示
    private func updateSpreadImage() {
        guard isSpreadLayout, let provider = imageProvider, let li = leftIndex else { return }
        let leftImg = provider(li)

        if let ri = rightIndex {
            let rightImg = provider(ri)
            guard let l = leftImg else { return }
            guard let r = rightImg else {
                imageView?.image = l
                return
            }
            // 専用キューで合成（メインスレッドブロック防止）
            SpriteCache.imageQueue.async { [weak self] in
                let composed = Self.composeTwoPages(left: l, right: r)
                DispatchQueue.main.async {
                    if self?.imageView?.image !== composed {
                        self?.imageView?.image = composed
                    }
                }
            }
        } else {
            if let img = leftImg, imageView?.image !== img {
                imageView?.image = img
            }
        }
    }

    /// 2枚の画像を横に合成（高さを揃える）
    static func composeTwoPages(left: UIImage, right: UIImage) -> UIImage {
        let targetH = max(left.size.height, right.size.height)

        let leftScale = targetH / left.size.height
        let leftW = left.size.width * leftScale

        let rightScale = targetH / right.size.height
        let rightW = right.size.width * rightScale

        let totalW = leftW + rightW
        let size = CGSize(width: totalW, height: targetH)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            left.draw(in: CGRect(x: 0, y: 0, width: leftW, height: targetH))
            right.draw(in: CGRect(x: leftW, y: 0, width: rightW, height: targetH))
        }
    }

    private func addDoubleTapZoom() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
    }

    @objc private func handleDoubleTap() {
        guard let img = imageView?.image else { return }
        onZoomImage?(img)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onDidAppear?()
        onDidAppear = nil
        // 表示時に合成+ポーリング開始（プリフェッチ時は実行しない）
        if isSpreadLayout {
            updateSpreadImage()
            let hasBlank = (leftIndex.flatMap { imageProvider?($0) } == nil) ||
                           (rightIndex != nil && rightIndex.flatMap { imageProvider?($0) } == nil)
            if hasBlank { addSpinner() }
        } else {
            if let img = imageProvider?(pageIndex) {
                imageView?.image = img
            } else {
                addSpinner()
            }
        }
        if updateTimer == nil { startImagePolling() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        updateTimer?.invalidate()
        updateTimer = nil
    }

    deinit {
        updateTimer?.invalidate()
    }
}
#endif
