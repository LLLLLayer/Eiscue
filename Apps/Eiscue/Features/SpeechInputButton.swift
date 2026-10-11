import SwiftUI
import UIKit

/// A dedicated voice surface has no text selection recognizer. Touch tracking
/// starts on press, release finishes, and dragging upward cancels the utterance.
struct SpeechInputButton: View {
    let controller: SpeechInputController
    var locale: Locale = .current
    var isDisabled = false
    let onTranscript: @MainActor (String) -> Void
    @State private var isCancelling = false

    var body: some View {
        VStack(spacing: 5) {
            HoldToTalkControl(
                isBusy: controller.isBusy, isDisabled: isDisabled,
                title: isCancelling ? speechText("speech.releaseToCancel")
                    : controller.isBusy ? controller.statusText : speechText("speech.holdToTalk"),
                status: controller.statusText,
                onStart: { controller.beginHold(locale: locale, onTranscript: onTranscript) },
                onFinish: { controller.endHold() },
                onCancel: { controller.cancel() },
                onCancelZone: { isCancelling = $0 },
                onAccessibleTap: { controller.toggle(locale: locale, onTranscript: onTranscript) }
            )
            .frame(height: 50)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(isCancelling ? Color.primary.opacity(0.35) : .clear))
            if controller.isBusy {
                Text(speechText(isCancelling ? "speech.releaseToCancel" : "speech.slideToCancel"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: isDisabled) { if isDisabled { controller.cancel() } }
        .onDisappear { controller.cancel(); isCancelling = false }
    }
}

/// Deterministic gesture state makes cancellation decisions independent of
/// microphone authorization latency and recognition callbacks.
struct SpeechHoldInteraction {
    enum Completion: Equatable { case finish, cancel }
    private(set) var isPressed = false
    private(set) var isCancelling = false
    mutating func begin(isEnabled: Bool) -> Bool {
        guard isEnabled, !isPressed else { return false }
        isPressed = true; isCancelling = false
        return true
    }
    mutating func move(verticalDistance: CGFloat) {
        guard isPressed else { return }
        isCancelling = verticalDistance < -64
    }
    mutating func end(cancelled: Bool = false) -> Completion? {
        guard isPressed else { return nil }
        let completion: Completion = cancelled || isCancelling ? .cancel : .finish
        isPressed = false; isCancelling = false
        return completion
    }
}

private struct HoldToTalkControl: UIViewRepresentable {
    let isBusy: Bool
    let isDisabled: Bool
    let title: String
    let status: String
    let onStart: @MainActor () -> Void
    let onFinish: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onCancelZone: @MainActor (Bool) -> Void
    let onAccessibleTap: @MainActor () -> Void

    func makeUIView(context: Context) -> HoldToTalkButton {
        let button = HoldToTalkButton(type: .system)
        button.accessibilityIdentifier = "holdToTalkButton"
        return button
    }

    func updateUIView(_ button: HoldToTalkButton, context: Context) {
        // VoiceOver starts via accessibilityActivate without a pressed finger;
        // keep the surface enabled so its next activation can stop recording.
        button.isEnabled = !isDisabled
        button.onStart = onStart; button.onFinish = onFinish; button.onCancel = onCancel
        button.onCancelZone = onCancelZone; button.onAccessibleTap = onAccessibleTap
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .body)
            return attributes
        }
        button.configuration = configuration
        button.accessibilityLabel = speechText("speech.holdToTalk")
        button.accessibilityValue = status
        button.accessibilityHint = speechText("speech.holdHint")
    }
}

@MainActor
private final class HoldToTalkButton: UIButton {
    var interaction = SpeechHoldInteraction()
    private var origin = CGPoint.zero
    var onStart: (@MainActor () -> Void)?
    var onFinish: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?
    var onCancelZone: (@MainActor (Bool) -> Void)?
    var onAccessibleTap: (@MainActor () -> Void)?

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard interaction.begin(isEnabled: isEnabled) else { return false }
        origin = touch.location(in: nil)
        isHighlighted = true
        onStart?()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let wasCancelling = interaction.isCancelling
        interaction.move(verticalDistance: touch.location(in: nil).y - origin.y)
        if wasCancelling != interaction.isCancelling {
            onCancelZone?(interaction.isCancelling)
            UISelectionFeedbackGenerator().selectionChanged()
        }
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { interaction.move(verticalDistance: touch.location(in: nil).y - origin.y) }
        complete(cancelled: false)
    }
    override func cancelTracking(with event: UIEvent?) { complete(cancelled: true) }
    private func complete(cancelled: Bool) {
        guard let completion = interaction.end(cancelled: cancelled) else { return }
        isHighlighted = false
        onCancelZone?(false)
        if completion == .cancel { onCancel?() } else { onFinish?() }
    }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        onAccessibleTap?()
        return true
    }
}

private func speechText(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Speech") }
