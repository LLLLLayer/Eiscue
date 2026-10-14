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
                .ignoresSafeArea()
                .zIndex(100)
            }
        }.statusBarHidden(selection != nil)
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

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let origin = geometry.frame(in: .global).origin
            let source = sourceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let target = fittedRect(in: bounds.insetBy(dx: 0, dy: max(16, geometry.safeAreaInsets.top)))
            let start = source.isEmpty || reduceMotion ? target : fittedRect(in: source)
            let frame = expanded ? target : start
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(expanded ? 1 : 0).accessibilityHidden(true)
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 12))
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(interactive ? 0 : 1)
                    .accessibilityHidden(true)
                ZoomableToolImage(image: image)
                    .padding(.vertical, max(16, geometry.safeAreaInsets.top))
                    .opacity(interactive ? 1 : 0)
                    .allowsHitTesting(interactive && !closing)
                    .accessibilityLabel(chatText("chat.activity.imagePreview"))
                    .accessibilityIdentifier("toolActivityImageViewer")
                Button(action: close) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .tint(.black).foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                .accessibilityLabel(String(localized: "common.done"))
                .accessibilityIdentifier("closeToolImagePreviewButton")
                .padding(.top, geometry.safeAreaInsets.top + 12).padding(.trailing, 16)
                .opacity(expanded ? 1 : 0)
                .disabled(closing)
            }
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
    }

    private var animation: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.9) }

    private func fittedRect(in bounds: CGRect) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func close() {
        guard !closing else { return }
        closing = true; interactive = false
        withAnimation(animation, completionCriteria: .logicallyComplete) { expanded = false } completion: { dismiss() }
    }
}

/// Native zooming keeps a tall screen readable without stretching its pixels.
struct ZoomableToolImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ToolImageScrollView { ToolImageScrollView() }
    func updateUIView(_ view: ToolImageScrollView, context: Context) { view.setImage(image) }
}

final class ToolImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedBounds = CGSize.zero

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1; maximumZoomScale = 6
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
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
