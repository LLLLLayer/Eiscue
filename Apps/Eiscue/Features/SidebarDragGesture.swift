import SwiftUI
import UIKit

/// Horizontal recognition leaves vertical history scrolling and nested image/code
/// scrolling alone. Translation is delivered on every movement, not just release.
struct SidebarDragGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let isOpen: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat, Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        context.coordinator.isOpen = isOpen
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: onChanged(x)
        case .ended: onEnded(x, recognizer.velocity(in: recognizer.view).x, false)
        case .cancelled, .failed: onEnded(x, 0, true)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(isOpen: isOpen) }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isOpen: Bool
        init(isOpen: Bool) { self.isOpen = isOpen }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return (isOpen ? velocity.x < 0 : velocity.x > 0) && abs(velocity.x) > abs(velocity.y) * 1.5
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view, current !== gestureRecognizer.view {
                if current is UITextField || current is UISlider || (current as? UITextView)?.isEditable == true { return false }
                if !isOpen, current is UIControl { return false }
                if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let scroll = other.view as? UIScrollView else { return false }
            return other === scroll.panGestureRecognizer
        }
    }
}
