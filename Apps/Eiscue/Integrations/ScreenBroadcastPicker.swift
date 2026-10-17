import EiscueDeviceCore
import ReplayKit
import SwiftUI

/// A real system button: the user must tap it and confirm iOS's broadcast sheet.
/// Never synthesize button actions or programmatically bypass that confirmation.
struct ScreenBroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> BroadcastPickerContainer {
        BroadcastPickerContainer(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
    }

    func updateUIView(_ view: BroadcastPickerContainer, context: Context) {
        view.overrideUserInterfaceStyle = .light
        view.tintColor = .black
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BroadcastPickerContainer, context: Context) -> CGSize? {
        CGSize(width: 52, height: 52)
    }
}

final class BroadcastPickerContainer: UIView {
    private let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))

    override init(frame: CGRect) {
        super.init(frame: frame)
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "org.eiscue.app") + ".broadcast"
        picker.showsMicrophoneButton = false
        // ReplayKit supplies a black icon on some OS versions even in dark
        // mode. Give the actual system control a consistent contrasting disc.
        backgroundColor = .white
        addSubview(picker)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        picker.frame = bounds
        picker.layoutIfNeeded()
        // ReplayKit can retain its button's original center after SwiftUI sizes
        // the picker. Keep the concrete system view, button and actions intact.
        for button in picker.subviews.compactMap({ $0 as? UIButton }) {
            button.center = CGPoint(x: picker.bounds.midX, y: picker.bounds.midY)
        }
    }
}
