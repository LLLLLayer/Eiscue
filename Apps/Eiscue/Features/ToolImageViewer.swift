import SwiftUI
import UIKit

struct ToolImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        NavigationStack {
            ZoomableToolImage(image: image)
                .background(.black)
                .accessibilityLabel(chatText("chat.activity.imagePreview"))
                .accessibilityIdentifier("toolActivityImageViewer")
                .navigationTitle(chatText("chat.activity.imagePreview"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") { dismiss() }
                            .accessibilityIdentifier("closeToolImagePreviewButton")
                    }
                }
        }
        .presentationDetents([.large])
    }
}

/// Native zooming keeps a tall screen readable without stretching its pixels.
private struct ZoomableToolImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ToolImageScrollView { ToolImageScrollView() }
    func updateUIView(_ view: ToolImageScrollView, context: Context) { view.setImage(image) }
}

private final class ToolImageScrollView: UIScrollView, UIScrollViewDelegate {
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
