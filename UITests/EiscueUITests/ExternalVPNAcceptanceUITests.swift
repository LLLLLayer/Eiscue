import XCTest

/// An external fault/recovery action on the selected Eiscue VPN only. A pass
/// proves the Settings action, not the App's cancellation or cleanup outcome;
/// correlate its timestamps with the App's independent acceptance metadata.
final class ExternalVPNAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("External VPN acceptance requires a physical iPhone.")
        #else
        guard ["disconnect", "reconnect"].contains(ProcessInfo.processInfo.environment["EISCUE_VPN_ACTION"] ?? "") else {
            throw XCTSkip("Opt in with TEST_RUNNER_EISCUE_VPN_ACTION=disconnect or reconnect.")
        }
        #endif
    }

    @MainActor
    func testChangeOnlyTheSelectedEiscueVPN() throws {
        let action = ProcessInfo.processInfo.environment["EISCUE_VPN_ACTION"] ?? ""
        try require(["disconnect", "reconnect"].contains(action), "An explicit VPN action is required.")
        let evidence = Evidence(testCase: self, action: action)
        addTeardownBlock { await evidence.attach() }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try require(app.state != .notRunning, "Keep the existing Eiscue process running; this helper never launches or activates it.")
        try require(springboard.alerts.count == 0, "Resolve existing system dialogs separately.")
        evidence.phase = "openingVPNSettings"
        // This can launch Settings. It never launches, terminates or foregrounds
        // Eiscue, so the running App's own background path remains under test.
        settings.open(URL(string: "prefs:root=General&path=VPN")!)
        try require(settings.state == .runningForeground && settings.alerts.count == 0
                    && springboard.alerts.count == 0, "Settings must be foreground with no pending authorization.")
        try openVPNPageIfNeeded(settings)
        evidence.phase = "checkingSelectedEiscueConfiguration"
        let titles = ["Eiscue Local VPN", "Eiscue 本地 VPN", "Eiscue本地VPN"]
        // Query only exact known titles. Never dump the Settings hierarchy,
        // profile details, unrelated configuration names or screenshots.
        let namedRows = titles.map { settings.cells.containing(.staticText, identifier: $0) }
        func matchingRowCount() -> Int { namedRows.reduce(0) { $0 + $1.count } }
        try require(matchingRowCount() == 1, "Exactly one known Eiscue VPN configuration must be visible.")
        let row = namedRows.first(where: { $0.count == 1 })!.element(boundBy: 0)
        let name = row.staticTexts.matching(NSPredicate(format: "label IN %@", titles))
        try require(name.count == 1 && row.isSelected,
                    "Settings must identify the Eiscue configuration as selected; an unexposed or ambiguous selection is not guessed.")
        evidence.matchedTitle = name.element(boundBy: 0).label
        let switches = settings.switches.matching(NSPredicate(format: "label IN %@", ["Status", "状态"]))
        try require(switches.count == 1, "The VPN page must expose exactly one Status switch.")
        let status = switches.element(boundBy: 0)
        let before = try connectedValue(status)
        evidence.beforeConnected = before
        let expectedBefore = action == "disconnect"
        try require(before == expectedBefore,
                    "The requested action requires its exact initial connection state; nothing is toggled otherwise.")
        try require(status.isEnabled && status.isHittable && row.isSelected && matchingRowCount() == 1
                    && settings.navigationBars["VPN"].exists && settings.alerts.count == 0 && springboard.alerts.count == 0
                    && (try connectedValue(status)) == expectedBefore,
                    "The selected Eiscue configuration or Status control changed before the single action.")
        evidence.phase = "toggleRequested"
        evidence.toggleAttempts = 1
        evidence.requestedAt = Date().timeIntervalSince1970
        status.tap()
        let expectedAfter = !expectedBefore
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && (status.value as? String) == (expectedAfter ? "1" : "0")
        }, object: nil)
        try require(XCTWaiter.wait(for: [changed], timeout: 15) == .completed,
                    "The Status switch did not reach the requested state; no repeat action is sent.")
        evidence.afterConnected = try connectedValue(status)
        try require(settings.navigationBars["VPN"].exists && matchingRowCount() == 1 && row.isSelected
                    && name.count == 1 && name.element(boundBy: 0).label == evidence.matchedTitle
                    && settings.alerts.count == 0 && springboard.alerts.count == 0,
                    "The original Eiscue selection must remain unambiguous after the action.")
        evidence.phase = "settingsActionConfirmed"
        evidence.confirmedAt = Date().timeIntervalSince1970
    }

    @MainActor
    private func openVPNPageIfNeeded(_ settings: XCUIApplication) throws {
        if settings.navigationBars["VPN"].waitForExistence(timeout: 3) { return }
        let management = ["VPN & Device Management", "VPN与设备管理", "VPN 与设备管理"]
        if !settings.navigationBars.matching(NSPredicate(format: "identifier IN %@", management)).firstMatch.exists
            && !settings.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["General", "通用"])).firstMatch.exists {
            try tapKnownRow(["General", "通用"], in: settings)
        }
        if !settings.navigationBars.matching(NSPredicate(format: "identifier IN %@", management)).firstMatch.exists {
            try tapKnownRow(management, in: settings)
        }
        if !settings.navigationBars["VPN"].exists { try tapKnownRow(["VPN"], in: settings) }
        try require(settings.navigationBars["VPN"].waitForExistence(timeout: 5),
                    "The bounded General → VPN navigation did not reach the VPN page.")
    }

    @MainActor
    private func tapKnownRow(_ titles: [String], in settings: XCUIApplication) throws {
        // A bounded exact-label query also covers the current App language;
        // no language preference or unrelated settings are changed.
        let labels = settings.staticTexts.matching(NSPredicate(format: "label IN %@", titles))
        for _ in 0..<2 {
            if labels.count == 1, labels.element(boundBy: 0).isHittable { break }
            try require(labels.count <= 1, "The expected Settings navigation row is ambiguous.")
            settings.swipeUp()
        }
        try require(labels.count == 1, "A unique expected Settings navigation row is unavailable.")
        let label = labels.element(boundBy: 0)
        try require(label.isEnabled && label.isHittable && settings.alerts.count == 0,
                    "The expected Settings navigation row cannot be tapped safely.")
        label.tap()
    }

    @MainActor
    private func connectedValue(_ status: XCUIElement) throws -> Bool {
        switch status.value as? String {
        case "1": return true
        case "0": return false
        default: try require(false, "The Status switch does not expose an unambiguous Boolean value."); return false
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { XCTFail(message); throw Failure.blocked }
    }
    private enum Failure: Error { case blocked }

    @MainActor private final class Evidence {
        weak var testCase: XCTestCase?
        let action: String
        let startedAt = Date().timeIntervalSince1970
        var phase = "preflight"
        var matchedTitle: String?
        var beforeConnected: Bool?
        var afterConnected: Bool?
        var requestedAt: TimeInterval?
        var confirmedAt: TimeInterval?
        var toggleAttempts = 0
        init(testCase: XCTestCase, action: String) { self.testCase = testCase; self.action = action }
        func attach() {
            let metadata: [String: Any] = [
                "helper": "externalSelectedEiscueVPN", "action": action, "phase": phase,
                "startedAt": startedAt, "finishedAt": Date().timeIntervalSince1970,
                "matchedTitle": matchedTitle as Any? ?? NSNull(),
                "beforeConnected": beforeConnected as Any? ?? NSNull(),
                "afterConnected": afterConnected as Any? ?? NSNull(),
                "requestedAt": requestedAt as Any? ?? NSNull(), "confirmedAt": confirmedAt as Any? ?? NSNull(),
                "toggleAttempts": toggleAttempts, "appAcceptanceVerified": false
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted]),
                  let text = String(data: data, encoding: .utf8) else { return }
            let attachment = XCTAttachment(string: text)
            attachment.name = "External Eiscue VPN action metadata"
            attachment.lifetime = .keepAlways
            testCase?.add(attachment)
        }
    }
}
