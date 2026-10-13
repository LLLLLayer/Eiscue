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
        isFinishing: Bool = false
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

        let phase: String
        switch run.state {
        case .completed:
            phase = String(localized: "task.status.phase.completed", defaultValue: "This turn has ended", table: "TaskStatus")
        case .paused:
            phase = String(localized: "task.status.phase.paused", defaultValue: "Open Eiscue to continue", table: "TaskStatus")
        case .interrupted:
            phase = String(localized: "task.status.phase.interrupted", defaultValue: "Interrupted", table: "TaskStatus")
        case .failed:
            phase = String(localized: "task.status.phase.failed", defaultValue: "Not completed", table: "TaskStatus")
        case .preparing:
            phase = isFinishing
                ? String(localized: "task.status.phase.finishing", defaultValue: "Saving results", table: "TaskStatus")
                : String(localized: "task.status.phase.preparing", defaultValue: "Preparing", table: "TaskStatus")
        case .running:
            if isFinishing {
                phase = String(localized: "task.status.phase.finishing", defaultValue: "Saving results", table: "TaskStatus")
            } else if let currentTool, !currentTool.isEmpty {
                phase = operationSummary(currentTool)
            } else {
                phase = isReceivingResponse
                    ? String(localized: "task.status.phase.analyzing", defaultValue: "Preparing a response", table: "TaskStatus")
                    : String(localized: "task.status.phase.waiting", defaultValue: "Waiting for AI", table: "TaskStatus")
            }
        }

        return Self(
            title: run.state == .paused
                ? String(localized: "task.status.title.paused", defaultValue: "Task paused", table: "TaskStatus")
                : String(localized: "task.status.title", defaultValue: "Eiscue is working", table: "TaskStatus"),
            subtitle: phase,
            completedToolCalls: endedCalls,
            completedWorkUnits: preparationUnits + Int64(endedCalls) + finishingUnits,
            totalWorkUnits: Int64(discoveredCalls) + 2
        )
    }

    private static func operationSummary(_ name: String) -> String {
        switch name {
        case "device_screenshot": String(localized: "task.status.operation.screenshot", defaultValue: "Viewing the screen", table: "TaskStatus")
        case "device_tap": String(localized: "task.status.operation.tap", defaultValue: "Tapping the screen", table: "TaskStatus")
        case "device_swipe": String(localized: "task.status.operation.swipe", defaultValue: "Swiping the screen", table: "TaskStatus")
        case "device_type_text": String(localized: "task.status.operation.type-text", defaultValue: "Entering text", table: "TaskStatus")
        case "device_launch_app": String(localized: "task.status.operation.launch-app", defaultValue: "Opening an app", table: "TaskStatus")
        case "device_home": String(localized: "task.status.operation.home", defaultValue: "Returning to the Home Screen", table: "TaskStatus")
        case "device_list_apps": String(localized: "task.status.operation.list-apps", defaultValue: "Finding apps", table: "TaskStatus")
        default: String(localized: "task.status.operation.other", defaultValue: "Performing the next step", table: "TaskStatus")
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
            String(localized: "background.pairing.preparing", defaultValue: "Preparing device setup", table: "BackgroundStatus")
        case .waitingForDevice:
            String(localized: "background.pairing.waiting", defaultValue: "Open pairing in Settings", table: "BackgroundStatus")
        case .confirming:
            String(localized: "background.pairing.confirming", defaultValue: "Confirm pairing in Settings", table: "BackgroundStatus")
        case .identitySaved:
            String(localized: "background.pairing.saved", defaultValue: "Finishing device setup", table: "BackgroundStatus")
        case .completed:
            String(localized: "background.pairing.completed", defaultValue: "Device setup complete", table: "BackgroundStatus")
        }
    }
}
