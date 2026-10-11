import SwiftUI
import UIKit

/// Native press recognition cancels the button's tap when a hold is recognized.
/// The same controller can also serve a composer field's beginHold/endHold.
struct SpeechInputButton: View {
    let controller: SpeechInputController
    var locale: Locale = .current
    var isDisabled = false
    let onTranscript: @MainActor (String) -> Void

    var body: some View {
        MicrophoneControl(
            isRecording: controller.isRecording,
            isPreparing: controller.isBusy && !controller.isRecording,
            isBusy: controller.isBusy,
            isDisabled: isDisabled,
            status: controller.statusText,
            onTap: { controller.toggle(locale: locale, onTranscript: onTranscript) },
            onHoldStart: { controller.beginHold(locale: locale, onTranscript: onTranscript) },
            onHoldEnd: { controller.endHold() }
        )
        .frame(width: 44, height: 44)
        .onDisappear { controller.cancel() }
    }
}

private struct MicrophoneControl: UIViewRepresentable {
    let isRecording: Bool
    let isPreparing: Bool
    let isBusy: Bool
    let isDisabled: Bool
    let status: String
    let onTap: @MainActor () -> Void
    let onHoldStart: @MainActor () -> Void
    let onHoldEnd: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> AccessibleMicrophoneButton {
        let button = AccessibleMicrophoneButton(type: .system)
        button.addTarget(context.coordinator, action: #selector(Coordinator.touchDown), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .primaryActionTriggered)
        button.activate = { [weak coordinator = context.coordinator] in coordinator?.accessibleTap() }
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 24
        hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
        button.accessibilityIdentifier = "speechInputButton"
        return button
    }

    func updateUIView(_ button: AccessibleMicrophoneButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = !isDisabled
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: isRecording ? "stop.fill" : "mic")
        configuration.preferredSymbolConfigurationForImage = .init(pointSize: 18, weight: .medium, scale: .medium)
        configuration.contentInsets = .zero
        configuration.imagePadding = 0
        configuration.showsActivityIndicator = isPreparing
        configuration.baseForegroundColor = UIColor(named: "AccentColor") ?? .label
        button.configuration = configuration
        button.accessibilityLabel = isBusy
            ? String(localized: "speech.stop", table: "Speech")
            : String(localized: "speech.start", table: "Speech")
        button.accessibilityValue = status
        button.accessibilityHint = String(localized: "speech.hint", table: "Speech")
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MicrophoneControl
        private var didHold = false
        init(parent: MicrophoneControl) { self.parent = parent }
        @objc func touchDown() { didHold = false }
        @objc func tap() {
            guard !didHold, !parent.isDisabled else { return }
            parent.onTap()
        }
        func accessibleTap() {
            guard !parent.isDisabled else { return }
            parent.onTap()
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard !parent.isDisabled else { return }
                didHold = true
                parent.onHoldStart()
            case .ended, .cancelled, .failed:
                if didHold { parent.onHoldEnd() }
            default: break
            }
        }
    }
}

private final class AccessibleMicrophoneButton: UIButton {
    var activate: (@MainActor () -> Void)?
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        activate?()
        return true
    }
}
