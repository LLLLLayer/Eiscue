import EiscueDeviceCore
import Foundation

/// App-owned device tool catalog. Persisted names are decoded only at the edge;
/// the runner and presentations share exhaustive, typed operation metadata.
enum DeviceToolSpec: String, CaseIterable, Sendable {
    case screenshot = "device_screenshot"
    case listApplications = "device_list_apps"
    case tap = "device_tap"
    case swipe = "device_swipe"
    case typeText = "device_type_text"
    case launchApplication = "device_launch_app"
    case home = "device_home"
    case pressKey = "device_press_key"

    enum Behavior { case observation, applicationList, action }
    enum Marker { case none, tap, swipe }

    private struct Metadata {
        let capability: DeviceCapability
        let behavior: Behavior
        let title: String.LocalizationValue
        let runningTitle: String.LocalizationValue
        let finishedTitle: String.LocalizationValue
        let operationSummary: StaticString
        let operationFallback: String.LocalizationValue
        let symbol: String
        let marker: Marker
    }

    private var metadata: Metadata {
        switch self {
        case .screenshot:
            Metadata(capability: .screenshot, behavior: .observation, title: "scope.observe",
                     runningTitle: "chat.activity.observing", finishedTitle: "chat.activity.observedImage",
                     operationSummary: "task.status.operation.screenshot", operationFallback: "Reading the current screen",
                     symbol: "photo.on.rectangle.angled", marker: .none)
        case .listApplications:
            Metadata(capability: .listApplications, behavior: .applicationList, title: "tool.listApps",
                     runningTitle: "chat.activity.listingApps", finishedTitle: "chat.activity.listedApps",
                     operationSummary: "task.status.operation.list-apps", operationFallback: "Finding apps",
                     symbol: "app", marker: .none)
        case .tap:
            Metadata(capability: .tap, behavior: .action, title: "tool.tap",
                     runningTitle: "chat.activity.tapping", finishedTitle: "chat.activity.tapped",
                     operationSummary: "task.status.operation.tap", operationFallback: "Tapping the screen",
                     symbol: "hand.tap", marker: .tap)
        case .swipe:
            Metadata(capability: .swipe, behavior: .action, title: "tool.swipe",
                     runningTitle: "chat.activity.swiping", finishedTitle: "chat.activity.swiped",
                     operationSummary: "task.status.operation.swipe", operationFallback: "Swiping the screen",
                     symbol: "hand.draw", marker: .swipe)
        case .typeText:
            Metadata(capability: .textInput, behavior: .action, title: "tool.typeText",
                     runningTitle: "chat.activity.typing", finishedTitle: "chat.activity.typed",
                     operationSummary: "task.status.operation.type-text", operationFallback: "Entering text",
                     symbol: "keyboard", marker: .none)
        case .launchApplication:
            Metadata(capability: .launchApplication, behavior: .action, title: "tool.launchApp",
                     runningTitle: "chat.activity.launchingApp", finishedTitle: "chat.activity.sentAppLaunch",
                     operationSummary: "task.status.operation.launch-app", operationFallback: "Opening an app",
                     symbol: "app", marker: .none)
        case .home:
            Metadata(capability: .home, behavior: .action, title: "tool.home",
                     runningTitle: "chat.activity.goingHome", finishedTitle: "chat.activity.sentHome",
                     operationSummary: "task.status.operation.home", operationFallback: "Returning to Home Screen",
                     symbol: "house", marker: .none)
        case .pressKey:
            Metadata(capability: .keyboardNavigation, behavior: .action, title: "tool.pressKey",
                     runningTitle: "chat.activity.pressingKey", finishedTitle: "chat.activity.pressedKey",
                     operationSummary: "task.status.operation.press-key", operationFallback: "Using the keyboard",
                     symbol: "keyboard", marker: .none)
        }
    }

    var capability: DeviceCapability { metadata.capability }
    var mayHaveSideEffects: Bool { metadata.behavior == .action }
    var isVerification: Bool { metadata.behavior == .observation }
    var executionCost: Int { mayHaveSideEffects ? 2 : 1 }
    var verifiesSideEffects: Bool { mayHaveSideEffects }
    var returnsImage: Bool { metadata.behavior != .applicationList }
    var marker: Marker { metadata.marker }
    var symbol: String { metadata.symbol }
    var title: String { String(localized: metadata.title) }
    var operationSummary: String {
        String(localized: metadata.operationSummary, defaultValue: metadata.operationFallback, table: "TaskStatus")
    }
    var companionPhase: BluetoothCompanionStatus.Phase { mayHaveSideEffects ? .acting : .observing }

    func activityTitle(isRunning: Bool) -> String {
        String(localized: isRunning ? metadata.runningTitle : metadata.finishedTitle, table: "Chat")
    }

    func isAvailable(scope: TaskScope, capabilities: Set<DeviceCapability>) -> Bool {
        scope != .chat && (!mayHaveSideEffects || scope == .control)
            && capabilities.contains(capability)
            && (!mayHaveSideEffects || capabilities.contains(.screenshot))
    }
}
