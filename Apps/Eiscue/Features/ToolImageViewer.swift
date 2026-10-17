import SwiftUI
import UIKit

private struct OpenToolImageKey: EnvironmentKey {
    static let defaultValue: @MainActor (ToolImagePreview, CGRect) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var openToolImage: @MainActor (ToolImagePreview, CGRect) -> Void {
        get { self[OpenToolImageKey.self] }
        set { self[OpenToolImageKey.self] = newValue }
    }
}

struct ToolImageThumbnail: View {
    @Environment(\.openToolImage) private var openImage
    let preview: ToolImagePreview
    var width: CGFloat? = 104
    var height: CGFloat = 112
    @State private var sourceFrame = CGRect.zero

    var body: some View {
        Button { openImage(preview, sourceFrame) } label: {
            Image(uiImage: preview.image).resizable().scaledToFit()
                .frame(width: width, height: height)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.08)))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sourceFrame = $0 }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chatText("chat.activity.openImage"))
        .accessibilityIdentifier("toolActivityImageThumbnail")
    }
}

extension View {
    /// Install above a navigation stack so the image covers its bars as well.
    func toolImagePreviewHost() -> some View { modifier(ToolImagePreviewHost()) }
}

private struct ToolImagePreviewHost: ViewModifier {
    private struct Selection: Identifiable {
        let preview: ToolImagePreview
        let sourceFrame: CGRect
        var id: String { preview.id }
    }
    @State private var selection: Selection?

    func body(content: Content) -> some View {
        ZStack {
            content
                .environment(\.openToolImage) { preview, frame in
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    selection = Selection(preview: preview, sourceFrame: frame)
                }
                .allowsHitTesting(selection == nil)
                .accessibilityHidden(selection != nil)
            if let selection {
                ToolImageViewer(image: selection.preview.image, sourceFrame: selection.sourceFrame) {
                    self.selection = nil
                }
                .id(selection.id)
                .zIndex(100)
            }
        }
    }
}

private struct ToolImageViewer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let image: UIImage
    let sourceFrame: CGRect
    let dismiss: () -> Void
    @State private var expanded = false
    @State private var interactive = false
    @State private var closing = false
    @State private var dragOffset = CGSize.zero

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let origin = geometry.frame(in: .global).origin
                let source = sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
                let target = fittedRect(in: bounds.insetBy(dx: 0, dy: 16))
                let start = source.isEmpty || reduceMotion ? target : fittedRect(in: source)
                let frame = expanded ? target : start
                ZStack {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 12))
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(interactive ? 0 : 1)
                        .accessibilityHidden(true)
                    ZoomableToolImage(image: image, dismissalEnabled: interactive && !closing,
                                      onDismissDrag: updateDismissDrag, onDismissEnd: endDismissDrag)
                        .padding(.vertical, 16)
                        .opacity(interactive ? 1 : 0)
                        .allowsHitTesting(interactive && !closing)
                        .accessibilityLabel(chatText("chat.activity.imagePreview"))
                        .accessibilityIdentifier("toolActivityImageViewer")
                }
                .scaleEffect(reduceMotion ? 1 : 1 - dragProgress * 0.15)
                .offset(dragOffset)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape, close)
                .task {
                    await Task.yield()
                    withAnimation(animation, completionCriteria: .logicallyComplete) {
                        expanded = true
                    } completion: { if !closing { interactive = true } }
                }
            }
            .containerBackground(.clear, for: .navigation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .foregroundStyle(.white)
                        .accessibilityLabel(String(localized: "common.done"))
                        .accessibilityIdentifier("closeToolImagePreviewButton")
                        .opacity(expanded ? 1 - dragProgress : 0).disabled(closing)
                }
            }
        }.background(Color.black.opacity(expanded ? 1.0 - Double(dragProgress) * 0.7 : 0.0).ignoresSafeArea())
    }

    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.9) }
    private var dragProgress: CGFloat { min(hypot(dragOffset.width, dragOffset.height) / 300, 1) }

    private func updateDismissDrag(_ translation: CGSize) {
        guard interactive, !closing else { return }
        dragOffset = translation
    }

    private func endDismissDrag(_ translation: CGSize, _ velocity: CGSize, _ cancelled: Bool) {
        guard interactive, !closing else { return }
        let distance = hypot(translation.width, translation.height)
        // Count only velocity continuing along the drag, not a sideways or reversing flick.
        let outwardVelocity = distance > 0 ? (translation.width * velocity.width + translation.height * velocity.height) / distance : 0
        let flicked = distance > 18 && outwardVelocity > 800
        if !cancelled && (distance > 120 || flicked) { close() }
        else { withAnimation(animation) { dragOffset = .zero } }
    }

    private func fittedRect(in bounds: CGRect) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func close() {
        guard !closing else { return }
        closing = true; interactive = false
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            expanded = false; dragOffset = .zero
        } completion: { dismiss() }
    }
}

/// Native zooming keeps a tall screen readable without stretching its pixels.
struct ZoomableToolImage: UIViewRepresentable {
    let image: UIImage
    var dismissalEnabled = false
    var onDismissDrag: (CGSize) -> Void = { _ in }
    var onDismissEnd: (CGSize, CGSize, Bool) -> Void = { _, _, _ in }
    func makeUIView(context: Context) -> ToolImageScrollView { ToolImageScrollView() }
    func updateUIView(_ view: ToolImageScrollView, context: Context) {
        view.onDismissDrag = onDismissDrag; view.onDismissEnd = onDismissEnd
        view.dismissalEnabled = dismissalEnabled
        view.setImage(image)
    }
}

final class ToolImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedBounds = CGSize.zero
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(dragToDismiss(_:)))
    private lazy var dismissDelegate = DismissGestureDelegate(scrollView: self)
    var onDismissDrag: (CGSize) -> Void = { _ in }
    var onDismissEnd: (CGSize, CGSize, Bool) -> Void = { _, _, _ in }
    var dismissalEnabled = false {
        didSet { if oldValue != dismissalEnabled { dismissPan.isEnabled = dismissalEnabled } }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1; maximumZoomScale = 6
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        dismissPan.minimumNumberOfTouches = 1; dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = dismissDelegate
        dismissPan.isEnabled = false
        addGestureRecognizer(dismissPan)
        panGestureRecognizer.require(toFail: dismissPan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fittedBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let image = imageView.image else { return }
        if fittedBounds != bounds.size {
            fittedBounds = bounds.size
            setZoomScale(1, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            contentSize = imageView.bounds.size
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        // A second finger hands the gesture back to native pinch zooming.
        if dismissPan.state == .began || dismissPan.state == .changed {
            dismissPan.isEnabled = false
            dismissPan.isEnabled = dismissalEnabled
        }
    }

    @objc private func dragToDismiss(_ gesture: UIPanGestureRecognizer) {
        // The SwiftUI container moves during this gesture; its window stays fixed.
        let translation = gesture.translation(in: window)
        let offset = CGSize(width: translation.x, height: translation.y)
        switch gesture.state {
        case .began, .changed: onDismissDrag(offset)
        case .ended:
            let velocity = gesture.velocity(in: window)
            onDismissEnd(offset, CGSize(width: velocity.x, height: velocity.y), false)
        case .cancelled, .failed: onDismissEnd(offset, .zero, true)
        default: break
        }
    }

    private final class DismissGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var scrollView: ToolImageScrollView?
        init(scrollView: ToolImageScrollView) { self.scrollView = scrollView }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scrollView, scrollView.dismissalEnabled,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01,
                  !scrollView.isZooming, !scrollView.isZoomBouncing else { return false }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other === scrollView?.pinchGestureRecognizer
        }
    }

    private func centerImage() {
        let horizontal = max(0, (bounds.width - imageView.frame.width) / 2)
        let vertical = max(0, (bounds.height - imageView.frame.height) / 2)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != insets { contentInset = insets }
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        guard zoomScale <= minimumZoomScale else { setZoomScale(minimumZoomScale, animated: true); return }
        let scale: CGFloat = 3
        let point = gesture.location(in: imageView)
        zoom(to: CGRect(x: point.x - bounds.width / scale / 2, y: point.y - bounds.height / scale / 2,
                        width: bounds.width / scale, height: bounds.height / scale), animated: true)
    }
}
