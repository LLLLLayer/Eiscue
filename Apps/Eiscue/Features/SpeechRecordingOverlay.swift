import SwiftUI
import UIKit

/// Lives over the transcript, inside the composer's safe-area reservation.
/// Only an actual recording request creates this surface; voice mode alone does not.
struct SpeechRecordingOverlay: View {
    let controller: SpeechInputController
    @Environment(\.colorScheme) private var colorScheme

    // The chrome backdrop shares this tone, while this overlay alone blocks transcript input.
    static func scrimColor(for colorScheme: ColorScheme) -> Color {
        Color(uiColor: .systemGray).opacity(colorScheme == .dark ? 0.38 : 0.24)
    }

    var body: some View {
        if controller.isBusy {
            ZStack {
                Rectangle()
                    .fill(Self.scrimColor(for: colorScheme))
                    .accessibilityHidden(true)
                VStack(spacing: 16) {
                    if controller.isRecording {
                        SpeechRecordingWaveform(meter: controller.audioMeter)
                            .frame(height: 64)
                    } else {
                        Image(systemName: controller.state == .finishing ? "text.bubble" : "mic")
                            .font(.system(size: 28, weight: .light))
                            .frame(height: 64).accessibilityHidden(true)
                    }
                    Text(controller.statusText)
                        .font(.headline).multilineTextAlignment(.center)
                        .accessibilityIdentifier("speechRecordingStatus")
                    if controller.isRecording {
                        Text(String(localized: "speech.recordingFeedback", table: "Speech"))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(.primary)
                .padding(24).frame(maxWidth: 320)
                .background(.thickMaterial, in: .rect(cornerRadius: 28))
                .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("speechRecordingOverlay")
            .onAppear { announceStage() }
            .onChange(of: controller.state) { announceStage() }
        }
    }

    private func announceStage() {
        guard controller.isBusy, UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: controller.statusText)
    }
}

/// Level changes invalidate this small view only, never the transcript or composer.
private struct SpeechRecordingWaveform: View {
    let meter: SpeechAudioMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SpeechWaveformTrace(levels: reduceMotion ? [0, 0, meter.level, 0, 0] : meter.levels)
            .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .accessibilityHidden(true)
    }
}

private struct SpeechWaveformTrace: Shape {
    let levels: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        let width = rect.width / CGFloat(max(1, levels.count))
        for (index, level) in levels.enumerated() {
            let x = rect.minX + CGFloat(index) * width
            let height = CGFloat(level) * rect.height * 0.44
            path.addLine(to: CGPoint(x: x + width * 0.25, y: rect.midY - height))
            path.addLine(to: CGPoint(x: x + width * 0.65, y: rect.midY + height))
            path.addLine(to: CGPoint(x: x + width, y: rect.midY))
        }
        return path
    }
}
