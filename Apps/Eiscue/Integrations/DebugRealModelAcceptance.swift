#if DEBUG && !EISCUE_HID_ONLY
import Foundation
import SwiftUI

/// A read-only accessibility projection for an explicitly requested real-model
/// check. It neither creates an engine nor reads credentials or message bodies.
@MainActor
enum DebugRealModelAcceptance {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--real-model-acceptance-diagnostics")
    }

    struct Snapshot: Encodable {
        let version = 1
        let normalAppMode: Bool
        let isLoading: Bool
        let isIdle: Bool
        let ownerHeld: Bool
        let isDeviceReady: Bool
        let hasConfiguredModel: Bool
        let newRunScope: String
        let draftEmpty: Bool
        let attachmentCount: Int
        let keyboardModeIdle: Bool
        let needsRecovery: Bool
        let hasDeviceContinuation: Bool
        let selectedConversationID: UUID?
        let selectedMessageCount: Int
        let selectedModelProfileID: UUID?
        let connectionMethod: String
        let controlBackend: String
        let timeoutSeconds: Int
        let activeRunID: UUID?
        let run: Run?
    }

    struct Run: Encodable {
        let id: UUID
        let conversationID: UUID
        let requestID: UUID
        let startedAt: TimeInterval
        let endedAt: TimeInterval?
        let scope: String
        let state: String
        let submission: String?
        let stopped: Bool
        let unknownOutcome: Bool
        let cleanupFailed: Bool
        let activities: [Activity]
        let events: [Event]

        init(_ record: RunRecord) {
            id = record.id; conversationID = record.conversationID; requestID = record.requestID
            startedAt = record.startedAt.timeIntervalSince1970
            endedAt = record.endedAt?.timeIntervalSince1970
            scope = record.scope.rawValue; state = record.state.rawValue; submission = record.submission?.rawValue
            stopped = record.stopCause != nil
            unknownOutcome = record.state == .outcomeUnknown || record.stopCause?.isOutcomeUnknown == true
            cleanupFailed = record.cleanupFailure != nil
            activities = (record.activities ?? []).map(Activity.init)
            events = record.events.compactMap(Event.init)
        }
    }

    struct Activity: Encodable {
        let id: String
        let name: String?
        let startedAt: TimeInterval
        let endedAt: TimeInterval?
        let isError: Bool

        init(_ activity: ToolActivity) {
            id = activity.id; name = DeviceToolSpec(rawValue: activity.name)?.rawValue
            startedAt = activity.startedAt.timeIntervalSince1970
            endedAt = activity.endedAt?.timeIntervalSince1970
            isError = activity.isError
        }
    }

    struct Event: Encodable {
        let kind: String
        let date: TimeInterval
        let tool: String?

        init?(_ event: RunLogEntry) {
            let allowed = ["action.prepared", "action.dispatched", "action.acknowledged", "action.unknown",
                           "observation.prepared", "observation.captured", "tool.started", "tool.finished", "tool.failed"]
            guard allowed.contains(event.kind) else { return nil }
            kind = event.kind; date = event.date.timeIntervalSince1970
            tool = DeviceToolSpec(rawValue: event.summary)?.rawValue
        }
    }

    static func json(model: AppModel) -> String {
        let arguments = ProcessInfo.processInfo.arguments
        // Other automation flags can replace normal state or start work. This
        // check deliberately requires the diagnostics-only launch for evidence.
        let normal = !arguments.contains { $0.hasPrefix("--") && $0 != "--real-model-acceptance-diagnostics" }
            && ProcessInfo.processInfo.environment["EISCUE_TEST_MODEL_URL"] == nil
        let dictation = model.dictationSession
        let record = model.activeRun.flatMap { $0.conversationID == model.selectedConversationID ? $0 : nil }
            ?? model.selectedRuns.first
        let snapshot = Snapshot(normalAppMode: normal, isLoading: model.isLoading,
            isIdle: !model.isBusy && !model.isSubmittingMessage, ownerHeld: model.deviceSession.owner != nil,
            isDeviceReady: model.isDeviceReady, hasConfiguredModel: model.hasConfiguredModel,
            newRunScope: model.newRunScope.rawValue, draftEmpty: model.draft.isEmpty,
            attachmentCount: model.draftAttachments.count,
            keyboardModeIdle: !dictation.isVoiceMode && !dictation.speech.isBusy && dictation.recordingID == nil
                && !dictation.isChangingConnection && dictation.deviceRestoration == nil,
            needsRecovery: model.needsRecovery, hasDeviceContinuation: model.hasDeviceContinuation,
            selectedConversationID: model.selectedConversationID,
            selectedMessageCount: model.selectedConversation?.messages.count ?? 0,
            selectedModelProfileID: model.selectedModelProfileID,
            connectionMethod: model.deviceConnectionMethod.rawValue, controlBackend: model.deviceControlBackend.rawValue,
            timeoutSeconds: model.modelSettings.timeoutSeconds, activeRunID: model.activeRun?.id, run: record.map(Run.init))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

struct DebugRealModelAcceptanceProjection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(verbatim: "Real-model run metadata")
            .font(.system(size: 1))
            .foregroundStyle(.secondary)
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityLabel(Text(verbatim: "Real-model run metadata"))
            .accessibilityValue(Text(verbatim: DebugRealModelAcceptance.json(model: model)))
            .accessibilityIdentifier("debugRealModelRunMetadata")
            .allowsHitTesting(false)
    }
}
#endif
