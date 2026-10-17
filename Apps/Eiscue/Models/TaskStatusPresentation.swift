import Foundation

/// Privacy-safe presentation for the system's continued-processing activity.
/// A fixed large scale keeps the ring visually quiet while phase text changes.
/// Real step counts still advance; this is not a goal-completion estimate.
struct TaskStatusPresentation: Equatable, Sendable {
    static let progressTotalUnitCount: Int64 = 1_000_000

    let title: String
    let subtitle: String
    let completedToolCalls: Int
    let completedWorkUnits: Int64
    let totalWorkUnits: Int64

    static func snapshot(
        for run: RunRecord,
        currentTool: String? = nil,
        isReceivingResponse: Bool = false,
        isFinishing: Bool = false,
        devicePhase: DeviceTaskPhase? = nil
    ) -> Self {
        var seen = Set<UUID>()
        var endedCalls = 0
        var hasStarted = run.state == .running || run.state == .completed

        // A journal entry may be replayed, but the same entry is not new work.
        // Do not read summaries: they can contain private or untrusted text.
        for event in run.events where seen.insert(event.id).inserted {
            switch event.kind {
            case "run.started", "tool.started": hasStarted = true
            case "tool.finished", "tool.failed":
                endedCalls += 1
                // A recovered call can finish without a new start event.
                hasStarted = true
            default: break
            }
        }
        let preparationUnits: Int64 = hasStarted ? 1 : 0

        let stage: Stage
        let phase: String
        switch run.state {
        case .completed:
            stage = .completed
            phase = String(localized: "task.status.phase.completed", defaultValue: "Open Eiscue to view the result", table: "TaskStatus")
        case .paused:
            stage = .paused
            phase = String(localized: "task.status.phase.paused", defaultValue: "Open Eiscue to continue", table: "TaskStatus")
        case .outcomeUnknown:
            stage = .interrupted
            phase = String(localized: "run.outcome_unknown", table: "Runtime")
        case .interrupted:
            stage = .interrupted
            phase = String(localized: "task.status.phase.interrupted", defaultValue: "Open Eiscue to review the task", table: "TaskStatus")
        case .failed:
            stage = .failed
            phase = String(localized: "task.status.phase.failed", defaultValue: "Open Eiscue to see what happened", table: "TaskStatus")
        case .preparing:
            stage = isFinishing ? .finishing : .preparing
            phase = isFinishing
                ? String(localized: "task.status.phase.finishing", defaultValue: "Saving results and ending device control", table: "TaskStatus")
                : String(localized: "task.status.phase.preparing", defaultValue: "Preparing device access", table: "TaskStatus")
        case .running:
            if isFinishing {
                stage = .finishing
                phase = String(localized: "task.status.phase.finishing", defaultValue: "Saving results and ending device control", table: "TaskStatus")
            } else if devicePhase == .verifying {
                stage = .verifying
                phase = String(localized: "task.status.phase.verifying", defaultValue: "Checking the screen after the action", table: "TaskStatus")
            } else if devicePhase == .observing {
                stage = .observing
                phase = DeviceToolSpec.screenshot.operationSummary
            } else if devicePhase == .paused {
                stage = .paused
                phase = String(localized: "task.status.phase.paused", defaultValue: "Open Eiscue to continue", table: "TaskStatus")
            } else if devicePhase == .stopped {
                stage = .interrupted
                phase = String(localized: "task.status.phase.interrupted", defaultValue: "Open Eiscue to review the task", table: "TaskStatus")
            } else if devicePhase == .deciding {
                stage = isReceivingResponse ? .responding : .waiting
                phase = isReceivingResponse
                    ? String(localized: "task.status.phase.analyzing", defaultValue: "Receiving the response", table: "TaskStatus")
                    : String(localized: "task.status.phase.waiting", defaultValue: "Waiting for the next response", table: "TaskStatus")
            } else if let currentTool, !currentTool.isEmpty {
                stage = DeviceToolSpec(rawValue: currentTool)?.isVerification == true ? .observing : .executing
                phase = operationSummary(currentTool)
            } else {
                stage = isReceivingResponse ? .responding : .waiting
                phase = isReceivingResponse
                    ? String(localized: "task.status.phase.analyzing", defaultValue: "Receiving the response", table: "TaskStatus")
                    : String(localized: "task.status.phase.waiting", defaultValue: "Waiting for the next response", table: "TaskStatus")
            }
        }

        return Self(
            title: stage.title,
            subtitle: phase,
            completedToolCalls: endedCalls,
            // The host exposes .completed only after cleanup and journal save.
            // Neither an unfinished task nor a failed task may fill the ring.
            completedWorkUnits: run.state == .completed ? progressTotalUnitCount
                : min(preparationUnits + Int64(endedCalls), progressTotalUnitCount - 1),
            totalWorkUnits: progressTotalUnitCount
        )
    }

    // The system may omit the subtitle in smaller presentations. Keep the
    // phase in the primary field, without claiming control of its layout.
    private enum Stage {
        case preparing, waiting, responding, observing, executing, verifying, finishing
        case completed, paused, interrupted, failed

        var title: String {
            switch self {
            case .preparing: String(localized: "task.status.title.preparing", defaultValue: "Preparing", table: "TaskStatus")
            case .waiting: String(localized: "task.status.title.waiting", defaultValue: "Waiting for AI", table: "TaskStatus")
            case .responding: String(localized: "task.status.title.responding", defaultValue: "Receiving reply", table: "TaskStatus")
            case .observing: String(localized: "task.status.title.observing", defaultValue: "Viewing screen", table: "TaskStatus")
            case .executing: String(localized: "task.status.title.executing", defaultValue: "Running a step", table: "TaskStatus")
            case .verifying: String(localized: "task.status.title.verifying", defaultValue: "Checking result", table: "TaskStatus")
            case .finishing: String(localized: "task.status.title.finishing", defaultValue: "Finishing up", table: "TaskStatus")
            case .completed: String(localized: "task.status.title.completed", defaultValue: "Task complete", table: "TaskStatus")
            case .paused: String(localized: "task.status.title.paused", defaultValue: "Task paused", table: "TaskStatus")
            case .interrupted: String(localized: "task.status.title.interrupted", defaultValue: "Task stopped", table: "TaskStatus")
            case .failed: String(localized: "task.status.title.failed", defaultValue: "Task failed", table: "TaskStatus")
            }
        }
    }

    private static func operationSummary(_ name: String) -> String {
        DeviceToolSpec(rawValue: name)?.operationSummary
            ?? String(localized: "task.status.operation.other", defaultValue: "Running the next step", table: "TaskStatus")
    }
}

/// Fixed pairing phases keep PINs and pairing records off the system activity.
enum PairingStatusPresentation: CaseIterable {
    case preparing, waitingForDevice, confirming, identitySaved, completed

    static let totalWorkUnits: Int64 = 4

    var completedWorkUnits: Int64 {
        switch self {
        case .preparing: 0
        case .waitingForDevice: 1
        case .confirming: 2
        case .identitySaved: 3
        case .completed: 4
        }
    }

    var subtitle: String {
        switch self {
        case .preparing:
            String(localized: "background.pairing.preparing", defaultValue: "Preparing to pair", table: "BackgroundStatus")
        case .waitingForDevice:
            String(localized: "background.pairing.waiting", defaultValue: "Open pairing in Settings", table: "BackgroundStatus")
        case .confirming:
            String(localized: "background.pairing.confirming", defaultValue: "Confirm pairing in Settings", table: "BackgroundStatus")
        case .identitySaved:
            String(localized: "background.pairing.saved", defaultValue: "Finishing pairing", table: "BackgroundStatus")
        case .completed:
            String(localized: "background.pairing.completed", defaultValue: "Pairing complete", table: "BackgroundStatus")
        }
    }
}
