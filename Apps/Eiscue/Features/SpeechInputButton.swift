import SwiftUI
import UIKit

/// Tap for hands-free dictation, or hold and release for a short utterance.
/// A dedicated control avoids competing with text selection gestures.
struct SpeechInputButton: View {
    let controller: SpeechInputController
    var locale: Locale = .current
    var isDisabled = false
    var hapticsEnabled = true
    let onTranscript: @MainActor (String) -> Void
    @State private var isCancelling = false

    var body: some View {
        HoldToTalkControl(
            isBusy: controller.isBusy, isDisabled: isDisabled || controller.state == .finishing,
            hapticsEnabled: hapticsEnabled,
            title: isCancelling ? speechText("speech.releaseToCancel")
                : controller.isBusy && !controller.transcript.isEmpty ? controller.transcript
                : controller.isRecording ? finishHint
                : controller.isBusy ? controller.statusText : speechText("speech.tapToTalk"),
            subtitle: !isCancelling && controller.isBusy && !controller.transcript.isEmpty
                ? (controller.isRecording ? finishHint : controller.statusText) : nil,
            status: controller.accessibilityStatus,
            onStart: { controller.beginHold(locale: locale, onTranscript: onTranscript) },
            onFinish: { controller.endHold() },
            onCancel: { controller.cancel() },
            onCancelZone: { isCancelling = $0 },
            onAccessibleTap: { controller.toggle(locale: locale, onTranscript: onTranscript) }
        )
        .frame(height: 44)
        .background(isCancelling ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
        .onChange(of: isDisabled) { if isDisabled { controller.cancel() } }
        .onChange(of: controller.isBusy) { if !controller.isBusy { isCancelling = false } }
    }

    private var finishHint: String {
        speechText(controller.isHoldSession ? "speech.releaseToFinish" : "speech.tapToFinish")
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
    let hapticsEnabled: Bool
    let title: String
    let subtitle: String?
    let status: String
    let onStart: @MainActor () -> Void
    let onFinish: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onCancelZone: @MainActor (Bool) -> Void
    let onAccessibleTap: @MainActor () -> Void

    func makeUIView(context: Context) -> HoldToTalkButton {
        let button = HoldToTalkButton(type: .system)
        button.configureGestures()
        button.accessibilityIdentifier = "holdToTalkButton"
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HoldToTalkButton, context: Context) -> CGSize? {
        proposal.width.map { CGSize(width: $0, height: 44) }
    }

    func updateUIView(_ button: HoldToTalkButton, context: Context) {
        button.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        button.tintColor = .label
        // VoiceOver starts via accessibilityActivate without a pressed finger;
        // keep the surface enabled so its next activation can stop recording.
        button.isEnabled = !isDisabled
        button.canBeginHold = !isBusy
        button.hapticsEnabled = hapticsEnabled
        button.onStart = onStart; button.onFinish = onFinish; button.onCancel = onCancel
        button.onCancelZone = onCancelZone; button.onAccessibleTap = onAccessibleTap
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.contentInsets = .init(top: 0, leading: 4, bottom: 0, trailing: 4)
        configuration.titleLineBreakMode = .byTruncatingHead
        configuration.subtitleLineBreakMode = .byTruncatingTail
        configuration.baseForegroundColor = .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .body)
            return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .caption2)
            attributes.foregroundColor = UIColor.secondaryLabel
            return attributes
        }
        button.configuration = configuration
        button.accessibilityLabel = title
        button.accessibilityValue = status
        button.accessibilityHint = speechText("speech.holdHint")
    }
}

@MainActor
private final class HoldToTalkButton: UIButton, UIGestureRecognizerDelegate {
    var interaction = SpeechHoldInteraction()
    private var origin = CGPoint.zero
    var canBeginHold = true
    var hapticsEnabled = true
    var onStart: (@MainActor () -> Void)?
    var onFinish: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?
    var onCancelZone: (@MainActor (Bool) -> Void)?
    var onAccessibleTap: (@MainActor () -> Void)?

    func configureGestures() {
        // Keep the held gesture independent of title/configuration updates.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
        hold.minimumPressDuration = 0.3; hold.allowableMovement = 12
        hold.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        tap.require(toFail: hold)
        addGestureRecognizer(hold); addGestureRecognizer(tap)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isEnabled && (!(gestureRecognizer is UILongPressGestureRecognizer) || canBeginHold)
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { onAccessibleTap?() }
    }
    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard interaction.begin(isEnabled: isEnabled && canBeginHold) else { return }
            origin = recognizer.location(in: nil)
            isHighlighted = true
            onStart?()
            if hapticsEnabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        case .changed, .ended:
            let wasCancelling = interaction.isCancelling
            interaction.move(verticalDistance: recognizer.location(in: nil).y - origin.y)
            if wasCancelling != interaction.isCancelling {
                onCancelZone?(interaction.isCancelling)
                if hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
            }
            if recognizer.state == .ended { complete(cancelled: false) }
        case .cancelled, .failed: complete(cancelled: true)
        default: break
        }
    }
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
