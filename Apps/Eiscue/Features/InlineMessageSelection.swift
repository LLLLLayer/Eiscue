import SwiftUI
import UIKit

/// Created only while selecting a message; the ordinary lazy Markdown rows stay lightweight.
struct InlineMessageSelection: UIViewRepresentable {
    let text: String
    let markdown: Bool
    let foregroundColor: UIColor
    let preferredWidth: CGFloat
    let onFinish: () -> Void

    func makeUIView(context: Context) -> MessageSelectionTextView {
        let view = MessageSelectionTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = "selectableMessageText"
        view.attributedText = MessageSelectionContent.make(text: text, markdown: markdown,
            foregroundColor: foregroundColor, traits: view.traitCollection)
        view.linkTextAttributes = [.foregroundColor: foregroundColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.tintColor = foregroundColor
        view.onFinish = onFinish
        return view
    }

    func updateUIView(_ view: MessageSelectionTextView, context: Context) {
        view.onFinish = onFinish
        view.tintColor = foregroundColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MessageSelectionTextView, context: Context) -> CGSize? {
        let width = min(proposal.width ?? preferredWidth, preferredWidth > 0 ? preferredWidth : 320)
        guard width > 0 else { return nil }
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }

    static func dismantleUIView(_ uiView: MessageSelectionTextView, coordinator: ()) {
        uiView.onFinish = nil
        uiView.finishSelection()
    }
}

final class MessageSelectionTextView: UITextView, @MainActor UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    var onFinish: (() -> Void)?
    private var selectionTask: Task<Void, Never>?
    private var started = false
    private var finished = false
    private weak var outsideTapHost: UIView?
    private var outsideTap: UITapGestureRecognizer?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            if started { finishSelection() }
            return
        }
        guard !started else { return }
        started = true
        addInteraction(editMenu)
        installOutsideTap()
        // Wait for the inline view's first layout, without an intermediate menu.
        selectionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.window != nil, !self.finished else { return }
            self.beginSelection()
        }
    }

    private func beginSelection() {
        layoutIfNeeded()
        guard becomeFirstResponder() else { finishSelection(); return }
        var visible = bounds
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds { visible = visible.intersection(convert(view.bounds, from: view)) }
            ancestor = view.superview
        }
        if visible.isNull || visible.isEmpty { finishSelection(); return }
        let point = CGPoint(x: visible.minX + min(8, visible.width / 2),
                            y: visible.minY + min((font?.lineHeight ?? 20) / 2, visible.height / 2))
        selectedTextRange = textRange(from: beginningOfDocument, to: endOfDocument)
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil,
            sourcePoint: point))
    }

    private func installOutsideTap() {
        // Include the composer, but not the system edit menu hosted outside our controller.
        // Install before activation so a new tap cannot have its focus stolen back.
        var responder = next
        while let current = responder {
            if let controller = current as? UIViewController {
                outsideTapHost = controller.view
                break
            }
            responder = current.next
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        outsideTapHost?.addGestureRecognizer(tap)
        outsideTap = tap
    }

    override func copy(_ sender: Any?) {
        super.copy(sender)
        finishSelection()
    }

    override func resignFirstResponder() -> Bool {
        let wasFirstResponder = isFirstResponder
        let resigned = super.resignFirstResponder()
        if wasFirstResponder && resigned { finishSelection() }
        return resigned
    }

    func finishSelection() {
        guard !finished else { return }
        finished = true
        selectionTask?.cancel()
        editMenu.dismissMenu()
        if let outsideTap { outsideTapHost?.removeGestureRecognizer(outsideTap) }
        outsideTap = nil
        if isFirstResponder { resignFirstResponder() }
        // UIKit can resign during a SwiftUI update; publish the row change on the next turn.
        Task { @MainActor [weak self] in self?.onFinish?() }
    }

    @objc private func tappedOutside() { finishSelection() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return false }
        return !view.isDescendant(of: self)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        // A long message can start above the viewport; anchor its menu to the visible part.
        CGRect(origin: configuration.sourcePoint, size: .zero)
    }
}
