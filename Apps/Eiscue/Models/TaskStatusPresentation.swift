import Foundation

/// Privacy-safe presentation for the system's continued-processing activity.
/// Counts reflect observed execution stages, not progress toward the user's
/// goal. The denominator can grow as new tool calls are actually discovered.
struct TaskStatusPresentation: Equatable, Sendable {
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
        var startedCalls = 0
        var endedCalls = 0
        var hasStarted = run.state == .running || run.state == .completed

        // A journal entry may be replayed, but the same entry is not new work.
        // Do not read summaries: they can contain private or untrusted text.
        for event in run.events where seen.insert(event.id).inserted {
            switch event.kind {
            case "run.started": hasStarted = true
            case "tool.started": startedCalls += 1
            case "tool.finished", "tool.failed": endedCalls += 1
            default: break
            }
        }
        // A recovered call can return without a new start event in this run.
        // Its result is itself evidence that this unit of work existed.
        let discoveredCalls = max(startedCalls, endedCalls)
        hasStarted = hasStarted || discoveredCalls > 0
        let preparationUnits: Int64 = hasStarted ? 1 : 0
        // The host sets .completed only after cleanup and durable finalization.
        // Merely entering the finishing phase cannot complete this last unit.
        let finishingUnits: Int64 = run.state == .completed ? 1 : 0

        let stage: Stage
        let phase: String
        switch run.state {
        case .completed:
            stage = .completed
            phase = String(localized: "task.status.phase.completed", defaultValue: "Open Eiscue to view the result", table: "TaskStatus")
        case .paused:
            stage = .paused
            phase = String(localized: "task.status.phase.paused", defaultValue: "Open Eiscue to continue", table: "TaskStatus")
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
                phase = operationSummary("device_screenshot")
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
                stage = currentTool == "device_screenshot" ? .observing : .executing
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
            completedWorkUnits: preparationUnits + Int64(endedCalls) + finishingUnits,
            totalWorkUnits: Int64(discoveredCalls) + 2
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
            case .completed: String(localized: "task.status.title.completed", defaultValue: "Turn ended", table: "TaskStatus")
            case .paused: String(localized: "task.status.title.paused", defaultValue: "Task paused", table: "TaskStatus")
            case .interrupted: String(localized: "task.status.title.interrupted", defaultValue: "Task stopped", table: "TaskStatus")
            case .failed: String(localized: "task.status.title.failed", defaultValue: "Task failed", table: "TaskStatus")
            }
        }
    }

    private static func operationSummary(_ name: String) -> String {
        switch name {
        case "device_screenshot": String(localized: "task.status.operation.screenshot", defaultValue: "Reading the current screen", table: "TaskStatus")
        case "device_tap": String(localized: "task.status.operation.tap", defaultValue: "Tapping the screen", table: "TaskStatus")
        case "device_swipe": String(localized: "task.status.operation.swipe", defaultValue: "Swiping the screen", table: "TaskStatus")
        case "device_type_text": String(localized: "task.status.operation.type-text", defaultValue: "Entering text", table: "TaskStatus")
        case "device_press_key": String(localized: "task.status.operation.press-key", defaultValue: "Using the keyboard", table: "TaskStatus")
        case "device_launch_app": String(localized: "task.status.operation.launch-app", defaultValue: "Opening an app", table: "TaskStatus")
        case "device_home": String(localized: "task.status.operation.home", defaultValue: "Returning to Home Screen", table: "TaskStatus")
        case "device_list_apps": String(localized: "task.status.operation.list-apps", defaultValue: "Finding apps", table: "TaskStatus")
        default: String(localized: "task.status.operation.other", defaultValue: "Running the next step", table: "TaskStatus")
        }
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
