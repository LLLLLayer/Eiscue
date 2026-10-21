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
    @MainActor private var activityEvidence: ActivityEvidence?

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
        let evidence = ActivityEvidence(testCase: self, app: app, metadata: [
            "action": action.rawValue, "startedAt": start, "waitLimitSeconds": 120,
            "appStateBefore": app.state.rawValue, "phase": "waitingForIdentifiedCard",
            "boundedImageAttached": false, "interactionAttempted": false, "tapAttempts": 0,
            "appAcceptanceVerified": false, "matchingRunVerified": false,
            "systemCompletionVerified": false
        ])
        activityEvidence = evidence
        addTeardownBlock { await evidence.attach() }
        defer { evidence.attach() }
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
            _ = matchingActivities(in: springboard, running: wantsRunning, diagnosticBoundary: "timeout")
            try require(false, "No unique bounded Eiscue card with a known \(wantsRunning ? "running" : "terminal") phase appeared within 120 seconds.")
            return
        }
        _ = matchingActivities(in: springboard, running: wantsRunning, diagnosticBoundary: "identified")
        try require(isBackground(app), "The identified system card must be observed while Eiscue is still in the background.")
        evidence.metadata["phase"] = "identifiedCard"
        evidence.metadata["observedAt"] = Date().timeIntervalSince1970
        evidence.metadata["card"] = cardMetadata(card)
        let buttons = knownStopButtons(in: card)
        evidence.metadata["knownCardControls"] = buttons.map(controlMetadata)
        evidence.metadata["uniqueKnownStopControl"] = buttons.count == 1
        let screenshot = XCTAttachment(screenshot: card.element.screenshot())
        screenshot.name = "Eiscue system activity — bounded \(wantsRunning ? "running" : "terminal") card"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        evidence.metadata["boundedImageAttached"] = true
        guard action == .cancel else {
            evidence.metadata["phase"] = wantsRunning ? "runningCardObserved" : "terminalCardObserved"
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
        evidence.metadata["phase"] = "systemCancelRequested"
        evidence.metadata["requestedAt"] = Date().timeIntervalSince1970
        evidence.metadata["interactionAttempted"] = true
        evidence.metadata["tapAttempts"] = 1
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
        evidence.metadata["runningCardEndedOrDisappeared"] = runningCardEnded
        try require(runningCardEnded, "The inspected activity still shows a running phase; no repeat action is sent.")
        evidence.metadata["phase"] = "systemCancelActionObserved"
        evidence.metadata["confirmedAt"] = Date().timeIntervalSince1970
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
        let nested = candidates.allSatisfy({ first in
            candidates.allSatisfy { second in
                first.frame.contains(second.frame) || second.frame.contains(first.frame)
            }
        })
        activityEvidence?.candidateDiagnostics["latestSelection"] = [
            "observedAt": Date().timeIntervalSince1970, "eligibleCount": candidates.count,
            "singleNestedGroup": !candidates.isEmpty && nested,
            "rejectionReasons": candidates.isEmpty ? ["noEligibleCard"] : (nested ? [] : ["disjointEligibleCards"])
        ]
        guard nested else { return nil }
        return candidates.max {
            let firstArea = $0.frame.width * $0.frame.height, secondArea = $1.frame.width * $1.frame.height
            if firstArea == secondArea {
                return $0.element.elementType != .other && $1.element.elementType == .other
            }
            return firstArea < secondArea
        }
    }

    @MainActor
    private func matchingActivities(in springboard: XCUIApplication, running: Bool,
                                    diagnosticBoundary: String? = nil) -> [ActivityCard]? {
        let name = NSPredicate(format: "label CONTAINS[c] %@", "Eiscue")
        let descendants = springboard.descendants(matching: .any)
        let named = descendants.matching(name)
        let containingName = descendants.containing(NSPredicate(format: "label ==[c] %@", "Eiscue"))
        // Query Eiscue only. No hierarchy dump, unrelated text enumeration,
        // passcode field lookup or global Stop/Cancel-button search.
        let namedCount = named.count, containingCount = containingName.count
        let overLimit = namedCount > 20 || containingCount > 20
        let scan: [String: Any] = [
            "observedAt": Date().timeIntervalSince1970, "uptime": ProcessInfo.processInfo.systemUptime,
            "runningRequested": running, "namedCount": min(namedCount, 21),
            "containingNameCount": min(containingCount, 21), "queryLimitExceeded": overLimit
        ]
        if activityEvidence?.candidateDiagnostics["firstScan"] == nil { activityEvidence?.candidateDiagnostics["firstScan"] = scan }
        activityEvidence?.candidateDiagnostics["latestScan"] = scan
        if overLimit {
            activityEvidence?.candidateDiagnostics["lastOverLimitScan"] = scan
            activityEvidence?.candidateDiagnostics["latestSelection"] = ["rejectionReasons": ["queryLimitExceeded"]]
            return nil
        }
        let screen = springboard.frame
        let statuses = running ? runningStatuses : terminalStatuses
        let elements = named.allElementsBoundByIndex + containingName.allElementsBoundByIndex
        let cards = elements.compactMap { element -> ActivityCard? in
            guard [.other, .button, .cell].contains(element.elementType), element.isHittable else { return nil }
            let frame = element.frame
            guard frame.width > 120, frame.height > 35, frame.height < 350, screen.contains(frame) else { return nil }
            let label = element.label
            let matched = statuses.filter { label.localizedCaseInsensitiveContains($0) || element.staticTexts[$0].exists }
            guard !matched.isEmpty else { return nil }
            if running, terminalStatuses.contains(where: { label.localizedCaseInsensitiveContains($0) || element.staticTexts[$0].exists }) { return nil }
            return ActivityCard(element: element, frame: frame, statuses: matched)
        }
        if let evidence = activityEvidence,
           let reason = evidence.candidateSnapshotReason(hasCandidates: !elements.isEmpty, boundary: diagnosticBoundary) {
            // Detailed AX reads run at most three times: first nonempty,
            // approximately 30 seconds, and identified/timeout. A transient
            // first candidate survives a later empty scan. These rows never
            // participate in card selection or cancellation authority.
            let snapshot: [String: Any] = [
                "observedAt": Date().timeIntervalSince1970, "uptime": ProcessInfo.processInfo.systemUptime,
                "reason": reason, "candidateCount": elements.count, "truncated": elements.count > 20,
                "candidates": elements.suffix(20).map { candidateMetadata($0, screen: screen, running: running) }
            ]
            evidence.candidateSnapshots.append(snapshot)
            evidence.candidateDiagnostics["snapshots"] = evidence.candidateSnapshots
        }
        return cards
    }

    @MainActor
    private func candidateMetadata(_ element: XCUIElement, screen: CGRect, running: Bool) -> [String: Any] {
        let type = element.elementType, frame = element.frame, hittable = element.isHittable
        let label = element.label
        let nameMatch = label.localizedCaseInsensitiveContains("Eiscue")
        let containsName = element.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@", "Eiscue")).count > 0
        let known = runningStatuses + terminalStatuses
        let texts = element.staticTexts.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", known, known))
        let textCount = texts.count
        var knownValues = Set<String>()
        for index in 0..<min(textCount, 8) {
            let text = texts.element(boundBy: index)
            // Only fixed allowlisted values survive this read. No arbitrary
            // label, identifier, subtree or notification body is exported.
            for value in [text.label, text.identifier] where known.contains(value) { knownValues.insert(value) }
        }
        let matchedRunning = runningStatuses.filter { label.localizedCaseInsensitiveContains($0) || knownValues.contains($0) }
        let matchedTerminal = terminalStatuses.filter { label.localizedCaseInsensitiveContains($0) || knownValues.contains($0) }
        let typeAccepted = [.other, .button, .cell].contains(type)
        let finite = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
        let phaseMatched = !(running ? matchedRunning : matchedTerminal).isEmpty
        let terminalConflict = running && !matchedTerminal.isEmpty
        var rejected: [String] = []
        if !typeAccepted { rejected.append("elementType") }
        if !hittable { rejected.append("notHittable") }
        if !finite { rejected.append("nonfiniteRect") }
        if !(frame.width > 120) { rejected.append("widthTooSmall") }
        if !(frame.height > 35) { rejected.append("heightTooSmall") }
        if !(frame.height < 350) { rejected.append("heightTooLarge") }
        if !screen.contains(frame) { rejected.append("outsideScreen") }
        if !phaseMatched { rejected.append("requestedKnownPhaseMissing") }
        if terminalConflict { rejected.append("terminalDuringRunningCheck") }
        if textCount > 8 { rejected.append("diagnosticKnownTextLimitExceeded") }
        func number(_ value: CGFloat) -> Any { value.isFinite ? value as Any : NSNull() }
        return [
            "type": type.rawValue, "isStaticText": type == .staticText,
            "x": number(frame.minX), "y": number(frame.minY), "width": number(frame.width), "height": number(frame.height),
            "hittable": hittable, "nameMatch": nameMatch, "containsExactName": containsName,
            "knownRunningPhases": matchedRunning, "knownTerminalPhases": matchedTerminal,
            "knownTextCount": min(textCount, 9), "knownTextLimit": 8, "typeAccepted": typeAccepted, "finiteRect": finite,
            "widthAccepted": frame.width > 120, "heightAccepted": frame.height > 35 && frame.height < 350,
            "insideScreen": screen.contains(frame), "requestedKnownPhaseMatched": phaseMatched,
            "terminalConflict": terminalConflict, "rejectionReasons": rejected
        ]
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
        return ["knownLabel": stopLabels.first(where: { $0 == control.label }) as Any? ?? NSNull(),
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

    @MainActor private final class ActivityEvidence {
        weak var testCase: XCTestCase?
        let app: XCUIApplication
        var metadata: [String: Any]
        var candidateDiagnostics: [String: Any] = ["candidateLimit": 20, "queryCountCap": 21, "snapshotLimit": 3]
        var candidateSnapshots: [[String: Any]] = []
        private let startedUptime = ProcessInfo.processInfo.systemUptime
        private var capturedFirstNonempty = false
        private var capturedTimed = false
        private var capturedBoundary = false
        private var attached = false
        init(testCase: XCTestCase, app: XCUIApplication, metadata: [String: Any]) {
            self.testCase = testCase; self.app = app; self.metadata = metadata
        }
        func candidateSnapshotReason(hasCandidates: Bool, boundary: String?) -> String? {
            guard candidateSnapshots.count < 3 else { return nil }
            if let boundary {
                guard !capturedBoundary else { return nil }
                capturedBoundary = true
                return boundary
            }
            if hasCandidates && !capturedFirstNonempty {
                capturedFirstNonempty = true
                return "firstNonempty"
            }
            if !capturedTimed, ProcessInfo.processInfo.systemUptime - startedUptime >= 30 {
                capturedTimed = true
                return "after30Seconds"
            }
            return nil
        }
        func attach() {
            guard !attached else { return }
            metadata["finishedAt"] = Date().timeIntervalSince1970
            metadata["appStateAfter"] = app.state.rawValue
            metadata["candidateDiagnostics"] = candidateDiagnostics
            guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) else { return }
            attached = true
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Eiscue system activity — metadata"
            attachment.lifetime = .keepAlways
            testCase?.add(attachment)
        }
    }
}
