import XCTest

/// Explicit observation only: retain the installed app, its data and current page.
final class DeviceScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Current-device capture requires an explicitly selected physical device.")
        #else
        guard ProcessInfo.processInfo.environment["EISCUE_DEVICE_SCREENSHOT"] == "1" else {
            throw XCTSkip("Run explicitly with TEST_RUNNER_EISCUE_DEVICE_SCREENSHOT=1.")
        }
        #endif
    }

    @MainActor
    func testCaptureCurrentPage() throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        guard app.state != .notRunning else {
            throw XCTSkip("Open Eiscue to the page being inspected first; this test does not relaunch it.")
        }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Eiscue-current-device-page"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

/// Targets only an identified Eiscue system activity. Cancellation is a separate
/// explicit opt-in; no mode opens the App or Notification Center.
final class SystemTaskAcceptanceUITests: XCTestCase {
    private enum Action: String { case inspectTerminal, inspectRunning, cancel }
    private enum Failure: Error { case blocked }
    // These are the App's fixed TaskStatus/Runtime catalog values, not generic
    // "Eiscue" icon labels or pairing activity phases.
    private let terminalStatuses = ["Task complete", "Task failed", "Task stopped", "Task paused",
                                    "任务已完成", "任务未完成", "任务已停止", "任务已暂停"]
    private let runningStatuses = [
        "Preparing device control", "Preparing device access", "Waiting for AI", "Receiving reply",
        "Viewing screen", "Running a step", "Checking result", "Waiting for the next response",
        "Receiving the response", "Reading the current screen", "Checking the screen after the action",
        "准备操作设备", "准备连接设备", "等待 AI", "接收回复", "查看屏幕", "执行操作", "确认结果",
        "等待下一步回复", "正在接收回复", "读取当前画面", "检查操作后的画面"
    ]
    private let stopLabels = ["Stop", "Stop Task", "Stop task", "Cancel", "Cancel Task", "Cancel task",
                              "停止", "停止任务", "取消", "取消任务"]

    @MainActor
    func testInspectEiscueSystemActivity() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System activity acceptance requires the physical test phone.")
        #else
        guard ProcessInfo.processInfo.environment["EISCUE_SYSTEM_TASK_TEST"] == "1" else {
            throw XCTSkip("Opt in with TEST_RUNNER_EISCUE_SYSTEM_TASK_TEST=1.")
        }
        #endif
        continueAfterFailure = false
        let requestedAction = ProcessInfo.processInfo.environment["EISCUE_SYSTEM_TASK_ACTION"] ?? "inspectTerminal"
        guard let action = Action(rawValue: requestedAction) else {
            try require(false, "EISCUE_SYSTEM_TASK_ACTION must be inspectTerminal, inspectRunning or cancel.")
            return
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let start = Date().timeIntervalSince1970
        var metadata: [String: Any] = [
            "action": action.rawValue, "startedAt": start, "waitLimitSeconds": 120,
            "appStateBefore": app.state.rawValue, "phase": "waitingForIdentifiedCard",
            "boundedImageAttached": false, "interactionAttempted": false, "tapAttempts": 0,
            "appAcceptanceVerified": false, "matchingRunVerified": false,
            "systemCompletionVerified": false
        ]
        defer {
            metadata["finishedAt"] = Date().timeIntervalSince1970
            metadata["appStateAfter"] = app.state.rawValue
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "Eiscue system activity — metadata"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let wantsRunning = action != .inspectTerminal
        try require(wantsRunning ? isBackground(app) : app.state != .notRunning,
                    "Keep Eiscue running, and background it before inspecting/cancelling an active task; this helper never launches or activates it.")
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        var found: ActivityCard?
        repeat {
            try require(wantsRunning ? isBackground(app) : app.state != .notRunning,
                        "Eiscue exited, or an active-task check lost its background state; no action is sent.")
            try require(springboard.alerts.count == 0, "Resolve system dialogs separately; this helper does not inspect or dismiss them.")
            found = findActivity(in: springboard, running: wantsRunning)
            if found != nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard let card = found else {
            try require(false, "No unique bounded Eiscue card with a known \(wantsRunning ? "running" : "terminal") phase appeared within 120 seconds.")
            return
        }
        try require(isBackground(app), "The identified system card must be observed while Eiscue is still in the background.")
        metadata["phase"] = "identifiedCard"
        metadata["observedAt"] = Date().timeIntervalSince1970
        metadata["card"] = cardMetadata(card)
        let buttons = knownStopButtons(in: card)
        metadata["knownCardControls"] = buttons.map(controlMetadata)
        metadata["uniqueKnownStopControl"] = buttons.count == 1
        let screenshot = XCTAttachment(screenshot: card.element.screenshot())
        screenshot.name = "Eiscue system activity — bounded \(wantsRunning ? "running" : "terminal") card"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        metadata["boundedImageAttached"] = true
        guard action == .cancel else {
            metadata["phase"] = wantsRunning ? "runningCardObserved" : "terminalCardObserved"
            return
        }

        // The preceding inspection is read-only. This independent action gate
        // authorizes only one accessible control inside that same activity.
        try require(ProcessInfo.processInfo.environment["EISCUE_SYSTEM_TASK_ACTION"] == "cancel",
                    "System cancellation needs the explicit cancel action.")
        try require(buttons.count == 1, "The identified running activity must contain exactly one known Stop/Cancel button; no coordinate fallback is allowed.")
        guard let current = findActivity(in: springboard, running: true) else {
            try require(false, "The running activity disappeared or became ambiguous before cancellation.")
            return
        }
        let currentButtons = knownStopButtons(in: current)
        try require(current.frame == card.frame && current.element.identifier == card.element.identifier,
                    "The inspected activity changed before cancellation; inspect it again in a separate run.")
        try require(currentButtons.count == 1 && currentButtons[0].label == buttons[0].label
                    && currentButtons[0].identifier == buttons[0].identifier && currentButtons[0].frame == buttons[0].frame,
                    "The unique control changed after inspection.")
        let button = currentButtons[0]
        try require(isBackground(app) && springboard.alerts.count == 0 && button.isEnabled && button.isHittable,
                    "The App must remain backgrounded and its system activity control must still be actionable.")
        metadata["phase"] = "systemCancelRequested"
        metadata["requestedAt"] = Date().timeIntervalSince1970
        metadata["interactionAttempted"] = true
        metadata["tapAttempts"] = 1
        button.tap()
        let cancellationDeadline = ProcessInfo.processInfo.systemUptime + 15
        var runningCardEnded = false
        repeat {
            try require(isBackground(app), "Eiscue did not remain in the background after the single system action.")
            try require(springboard.alerts.count == 0, "The action opened a dialog; no second tap is sent.")
            // Ambiguous or over-limit queries are not evidence of dismissal.
            if matchingActivities(in: springboard, running: true)?.isEmpty == true {
                runningCardEnded = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while ProcessInfo.processInfo.systemUptime < cancellationDeadline
        metadata["runningCardEndedOrDisappeared"] = runningCardEnded
        try require(runningCardEnded, "The inspected activity still shows a running phase; no repeat action is sent.")
        metadata["phase"] = "systemCancelActionObserved"
        metadata["confirmedAt"] = Date().timeIntervalSince1970
        // Correlate with the App's runID, backgroundExpired callback and cleanup
        // evidence. A vanished system card alone does not prove those outcomes.
    }

    private struct ActivityCard {
        let element: XCUIElement
        let frame: CGRect
        let statuses: [String]
    }

    @MainActor
    private func findActivity(in springboard: XCUIApplication, running: Bool) -> ActivityCard? {
        guard let candidates = matchingActivities(in: springboard, running: running) else { return nil }
        // AX may expose nested representations of one card. Disjoint siblings
        // remain ambiguous even if a larger container happens to wrap them.
        guard candidates.allSatisfy({ first in
            candidates.allSatisfy { second in
                first.frame.contains(second.frame) || second.frame.contains(first.frame)
            }
        }) else { return nil }
        return candidates.max {
            let firstArea = $0.frame.width * $0.frame.height, secondArea = $1.frame.width * $1.frame.height
            if firstArea == secondArea {
                return $0.element.elementType != .other && $1.element.elementType == .other
            }
            return firstArea < secondArea
        }
    }

    @MainActor
    private func matchingActivities(in springboard: XCUIApplication, running: Bool) -> [ActivityCard]? {
        let name = NSPredicate(format: "label CONTAINS[c] %@", "Eiscue")
        let descendants = springboard.descendants(matching: .any)
        let named = descendants.matching(name)
        let containingName = descendants.containing(NSPredicate(format: "label ==[c] %@", "Eiscue"))
        // Query Eiscue only. No hierarchy dump, unrelated text enumeration,
        // passcode field lookup or global Stop/Cancel-button search.
        guard named.count <= 20, containingName.count <= 20 else { return nil }
        let screen = springboard.frame
        let statuses = running ? runningStatuses : terminalStatuses
        return (named.allElementsBoundByIndex + containingName.allElementsBoundByIndex).compactMap { element -> ActivityCard? in
            guard [.other, .button, .cell].contains(element.elementType), element.isHittable else { return nil }
            let frame = element.frame
            guard frame.width > 120, frame.height > 35, frame.height < 350, screen.contains(frame) else { return nil }
            let label = element.label
            let matched = statuses.filter { label.localizedCaseInsensitiveContains($0) || element.staticTexts[$0].exists }
            guard !matched.isEmpty else { return nil }
            if running, terminalStatuses.contains(where: { label.localizedCaseInsensitiveContains($0) || element.staticTexts[$0].exists }) { return nil }
            return ActivityCard(element: element, frame: frame, statuses: matched)
        }
    }

    @MainActor
    private func knownStopButtons(in card: ActivityCard) -> [XCUIElement] {
        let query = card.element.buttons.matching(NSPredicate(format: "label IN %@", stopLabels))
        guard query.count <= 10 else { return [] }
        return query.allElementsBoundByIndex.filter { card.frame.contains($0.frame) && !$0.frame.isEmpty }
    }

    @MainActor
    private func cardMetadata(_ card: ActivityCard) -> [String: Any] {
        [
            "matchedAppName": "Eiscue", "knownPhases": card.statuses,
            "type": card.element.elementType.rawValue, "hittable": card.element.isHittable,
            "x": card.frame.minX, "y": card.frame.minY, "width": card.frame.width, "height": card.frame.height
        ]
    }

    @MainActor
    private func controlMetadata(_ control: XCUIElement) -> [String: Any] {
        let frame = control.frame
        return ["identifier": String(control.identifier.prefix(160)), "label": control.label,
                "enabled": control.isEnabled, "hittable": control.isHittable,
                "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }

    @MainActor
    private func isBackground(_ app: XCUIApplication) -> Bool {
        app.state == .runningBackground || app.state == .runningBackgroundSuspended
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { XCTFail(message); throw Failure.blocked }
    }
}
