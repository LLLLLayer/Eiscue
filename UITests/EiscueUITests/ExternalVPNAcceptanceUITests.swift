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
    func testChangeOnlyTheSelectedEiscueVPN() async throws {
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
        let namedStatus = settings.switches.matching(NSPredicate(format: "label IN %@", ["Status", "状态"]))
        // Some OS builds label this control with its connection state. Only
        // use the page's unique switch after the exact Eiscue row and VPN
        // navigation bar have been verified; never choose among several.
        let switches = namedStatus.count == 1 ? namedStatus : settings.switches
        try require(settings.navigationBars["VPN"].exists && switches.count == 1,
                    "The selected Eiscue VPN page must expose one unambiguous status switch.")
        let status = switches.element(boundBy: 0)
        evidence.initialConnected = try connectedValue(status)
        let expectedBefore = action == "disconnect"
        evidence.phase = "waitingForStableBefore"
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var matchingSince: ContinuousClock.Instant?
        var stableBefore: Bool?
        // Settings may expose an initial value while its page loads. Observe
        // the same selected configuration twice, at least 300 ms apart; this
        // wait never selects a configuration or changes its connection state.
        while ContinuousClock.now < deadline {
            try require(settings.state == .runningForeground && settings.navigationBars["VPN"].exists
                        && settings.alerts.count == 0 && springboard.alerts.count == 0
                        && matchingRowCount() == 1 && row.isSelected
                        && name.count == 1 && name.element(boundBy: 0).label == evidence.matchedTitle
                        && switches.count == 1 && status.exists,
                        "The original selected Eiscue configuration and unique Status switch must remain visible while waiting.")
            let value = try connectedValue(status)
            let enabled = status.isEnabled
            let now = ContinuousClock.now
            guard now < deadline else { break }
            if enabled && value == expectedBefore {
                if let matchingSince, matchingSince.duration(to: now) >= .milliseconds(300) {
                    stableBefore = value
                    break
                }
                if matchingSince == nil { matchingSince = now }
            } else { matchingSince = nil }
            try await Task.sleep(until: min(deadline, now.advanced(by: .milliseconds(300))), clock: .continuous)
        }
        evidence.stableBefore = stableBefore
        evidence.beforeConnected = stableBefore
        try require(stableBefore != nil,
                    "The requested initial state did not stabilize within 10 seconds; nothing was toggled.")
        evidence.stableBeforeAt = Date().timeIntervalSince1970
        try require(status.isEnabled && status.isHittable && switches.count == 1
                    && row.isSelected && matchingRowCount() == 1
                    && name.count == 1 && name.element(boundBy: 0).label == evidence.matchedTitle
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
        let completion = await XCTWaiter.fulfillment(of: [changed], timeout: 15)
        try require(completion == .completed,
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
        var initialConnected: Bool?
        var stableBefore: Bool?
        var stableBeforeAt: TimeInterval?
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
                "initialConnected": initialConnected as Any? ?? NSNull(),
                "stableBefore": stableBefore as Any? ?? NSNull(),
                "stableBeforeAt": stableBeforeAt as Any? ?? NSNull(),
                "baselineWaitLimitSeconds": 10, "baselineMinimumStableSeconds": 0.3,
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

/// A separately gated Settings action on Eiscue's named permission only.
/// Denial and restoration are separate invocations around the normal D7 check.
/// A permission change can end the App process; this helper does not attribute
/// an observed exit to the OS, a crash, or a product defect.
final class EiscueSystemPermissionAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("System permission acceptance requires a prepared physical iPhone.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_SYSTEM_PERMISSION_TEST"] == "1",
              Permission(rawValue: environment["EISCUE_SYSTEM_PERMISSION"] ?? "") != nil,
              Action(rawValue: environment["EISCUE_SYSTEM_PERMISSION_ACTION"] ?? "") != nil
                || environment["EISCUE_SYSTEM_PERMISSION_ACTION"] == "inspect" else {
            throw XCTSkip("Set TEST_RUNNER_EISCUE_SYSTEM_PERMISSION_TEST=1, EISCUE_SYSTEM_PERMISSION=microphone|speech and EISCUE_SYSTEM_PERMISSION_ACTION=deny|restore|inspect (all with TEST_RUNNER_ prefixes).")
        }
        #endif
    }

    @MainActor
    func testDenyOnlyTheNamedEiscuePermission() throws {
        try changePermission(action: .deny)
    }

    @MainActor
    func testRestoreOnlyTheNamedEiscuePermission() throws {
        try changePermission(action: .restore)
    }

    /// Attaches only to the already visible own-App Settings page. The exact
    /// named switch may include its row, so bound its crop before capturing.
    @MainActor
    func testInspectOnlyTheNamedEiscuePermission() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_SYSTEM_PERMISSION_TEST"] == "1",
              environment["EISCUE_SYSTEM_PERMISSION_ACTION"] == "inspect",
              let permission = Permission(rawValue: environment["EISCUE_SYSTEM_PERMISSION"] ?? "") else {
            throw XCTSkip("This read-only helper requires the matching explicit inspect permission action.")
        }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let evidence = PermissionEvidence(testCase: self, app: XCUIApplication(bundleIdentifier: "org.eiscue.app"),
                                          permission: permission.rawValue, action: "inspect")
        addTeardownBlock { await evidence.attach() }
        defer { evidence.attach() }
        try require(ownSettingsPage(settings) && settings.alerts.count == 0 && springboard.alerts.count == 0,
                    "Keep the exact Eiscue Settings page foreground without alerts; inspection never navigates.")
        evidence.ownSettingsPageVerified = true
        evidence.phase = "inspectingNamedPermission"
        guard let target = try permissionSwitch(permission, in: settings, evidence: evidence) else {
            try require(false, "The named Eiscue permission has no unique exposed switch; nothing was captured.")
            return
        }
        let allowed = try booleanValue(target)
        let frame = target.frame, bounds = settings.frame
        let hittable = target.isHittable
        let finite = [frame.minX, frame.minY, frame.width, frame.height,
                      bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite)
        let singleVisibleRow = finite && bounds.width > 0 && bounds.height > 0 && bounds.contains(frame)
            && frame.width >= 20 && frame.width <= 600 && frame.height >= 20 && frame.height <= 80
        let screenshotEligible = singleVisibleRow && hittable && target.elementType == .switch
        func rectangle(_ rect: CGRect) -> [String: Any] {
            func number(_ value: CGFloat) -> Any { value.isFinite ? Double(value) : NSNull() }
            return ["x": number(rect.minX), "y": number(rect.minY),
                    "width": number(rect.width), "height": number(rect.height)]
        }
        evidence.beforeAllowed = allowed
        evidence.inspection = [
            "observedAt": Date().timeIntervalSince1970, "frame": rectangle(frame), "currentBounds": rectangle(bounds),
            "type": target.elementType.rawValue, "isHittable": hittable, "isEnabled": target.isEnabled,
            "allowed": allowed, "singleVisibleRow": singleVisibleRow, "screenshotEligible": screenshotEligible,
            "maximumCropWidth": 600, "maximumCropHeight": 80, "captureScope": "namedSwitchElementOnly"
        ]
        if screenshotEligible {
            try require(ownSettingsPage(settings) && settings.alerts.count == 0 && springboard.alerts.count == 0,
                        "The exact Eiscue page changed before its named switch capture.")
            guard let current = try permissionSwitch(permission, in: settings, evidence: evidence) else {
                try require(false, "The named permission disappeared before capture.")
                return
            }
            try require(current.elementType == .switch && current.frame == frame && settings.frame == bounds
                        && current.isHittable && (try booleanValue(current)) == allowed,
                        "The named permission bounds or Boolean changed before capture; nothing was captured.")
            let attachment = XCTAttachment(screenshot: current.screenshot())
            attachment.name = "Eiscue named system permission — \(permission.rawValue) — switch only"
            attachment.lifetime = .keepAlways
            add(attachment)
            evidence.explicitScreenshotsCaptured = 1
        }
        evidence.phase = "namedPermissionInspectionCompleted"
    }

    private enum Permission: String {
        case microphone, speech
        var titles: [String] {
            switch self {
            case .microphone: ["Microphone", "麦克风"]
            case .speech: ["Speech Recognition", "语音识别"]
            }
        }
    }
    private enum Action: String {
        case deny, restore
        var expectedBefore: Bool { self == .deny }
        var expectedAfter: Bool { !expectedBefore }
    }
    private enum Failure: Error { case blocked }

    @MainActor
    private func changePermission(action: Action) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_SYSTEM_PERMISSION_TEST"] == "1",
              environment["EISCUE_SYSTEM_PERMISSION_ACTION"] == action.rawValue,
              let permission = Permission(rawValue: environment["EISCUE_SYSTEM_PERMISSION"] ?? "") else {
            throw XCTSkip("This separate helper requires its matching explicit permission action.")
        }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let evidence = PermissionEvidence(testCase: self, app: app, permission: permission.rawValue, action: action.rawValue)
        addTeardownBlock { await evidence.attach() }
        defer { evidence.attach() }
        try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Keep normal Eiscue foreground and resolve dialogs separately; this helper never launches it.")
        try require(!app.staticTexts["networkRunAcceptanceState"].exists
                    && !app.staticTexts["Input check"].exists && !app.buttons["Tap to count"].exists,
                    "Only the normal App is eligible; isolated device diagnostics cannot change permissions.")
        try require(!app.buttons["stopRunButton"].exists && !app.buttons["cancelDictationButton"].exists
                    && !app.buttons["holdToTalkButton"].exists
                    && !app.staticTexts["speechDeviceRestorationStatus"].exists,
                    "Finish tasks, speech and restoration before navigating to system permissions.")
        evidence.phase = "checkingIdleDeviceControls"
        openDevice(in: app)
        let control = app.switches["deviceControlToggle"]
        let route = app.buttons["deviceConnectionMethodPicker"]
        try require(control.exists && control.isEnabled && route.exists && route.isEnabled
                    && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Device ownership, recovery and connection work must be idle; no connection is changed here.")
        evidence.phase = "openingOwnSystemSettings"
        openSettings(in: app)
        let openOwnSettings = app.buttons["appLanguageSettingsButton"]
        try require(openOwnSettings.exists && openOwnSettings.isEnabled && openOwnSettings.isHittable
                    && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "The normal App's system-settings link is unavailable; its language preference is never changed.")
        evidence.settingsOpenRequestedAt = Date().timeIntervalSince1970
        openOwnSettings.tap()
        try require(wait(seconds: 8) { self.ownSettingsPage(settings) },
                    "The App's own Settings link did not reach an exact Eiscue navigation page.")
        evidence.ownSettingsPageVerified = true
        evidence.phase = "findingNamedPermission"
        var target: XCUIElement?
        for step in 0..<6 {
            try require(ownSettingsPage(settings) && settings.alerts.count == 0 && springboard.alerts.count == 0,
                        "Only the exact Eiscue Settings page may be inspected or scrolled.")
            target = try permissionSwitch(permission, in: settings, evidence: evidence)
            if let target, target.isEnabled && target.isHittable { break }
            if step == 5 { break }
            if step < 2 { settings.swipeDown() } else { settings.swipeUp() }
        }
        guard let target else {
            try require(false, "The named Eiscue permission has no unique exposed switch; no action was sent.")
            return
        }
        let before = try booleanValue(target)
        evidence.beforeAllowed = before
        evidence.appStateBeforeToggle = Int(app.state.rawValue)
        try require(before == action.expectedBefore,
                    "Deny requires an enabled permission and restore requires a disabled permission; no action was sent.")
        try require(app.state != .notRunning && ownSettingsPage(settings)
                    && settings.alerts.count == 0 && springboard.alerts.count == 0
                    && target.isEnabled && target.isHittable
                    && (try booleanValue(target)) == action.expectedBefore,
                    "The exact own-App permission page, process or Boolean state changed before the single action.")
        // Re-resolve the same named control immediately before dispatch. No
        // default switch, coordinate, other permission or language is used.
        guard let current = try permissionSwitch(permission, in: settings, evidence: evidence) else {
            try require(false, "The named permission disappeared before dispatch; no action was sent.")
            return
        }
        try require(current.isEnabled && current.isHittable && (try booleanValue(current)) == action.expectedBefore,
                    "The named permission must remain unique and unchanged before dispatch.")
        evidence.phase = "singlePermissionActionRequested"
        evidence.toggleAttempts = 1
        evidence.requestedAt = Date().timeIntervalSince1970
        current.tap()
        let confirmed = wait(seconds: 8) {
            if app.state == .notRunning { evidence.appNotRunningObservedAfterAction = true }
            guard self.ownSettingsPage(settings), settings.alerts.count == 0, springboard.alerts.count == 0,
                  let control = try? self.permissionSwitch(permission, in: settings, evidence: evidence),
                  control.isHittable,
                  let allowed = try? self.booleanValue(control) else { return false }
            evidence.afterAllowed = allowed
            return allowed == action.expectedAfter
        }
        try require(confirmed, "The named permission did not reach its requested Boolean state; no retry or automatic reverse action is sent.")
        evidence.confirmedAt = Date().timeIntervalSince1970
        // Observe process state briefly without activating/relaunching Eiscue.
        _ = wait(seconds: 2) {
            if app.state == .notRunning { evidence.appNotRunningObservedAfterAction = true }
            return false
        }
        try require(ownSettingsPage(settings) && settings.alerts.count == 0 && springboard.alerts.count == 0,
                    "The exact Eiscue page must remain available for the final independent Boolean check.")
        guard let final = try permissionSwitch(permission, in: settings, evidence: evidence) else {
            try require(false, "The named permission disappeared after confirmation; no further action is sent.")
            return
        }
        try require((try booleanValue(final)) == action.expectedAfter,
                    "The permission changed again after confirmation; no further action is sent.")
        evidence.afterAllowed = action.expectedAfter
        evidence.phase = "namedPermissionActionConfirmed"
        // Intentionally leave Settings foreground. Root separately restarts or
        // reconnects Eiscue, runs D7, then invokes the explicit restore helper.
    }

    @MainActor
    private func ownSettingsPage(_ settings: XCUIApplication) -> Bool {
        let bars = settings.navigationBars.matching(NSPredicate(format: "label == %@ OR identifier == %@", "Eiscue", "Eiscue"))
        return settings.state == .runningForeground && bars.count == 1 && bars.firstMatch.isHittable
    }

    @MainActor
    private func permissionSwitch(_ permission: Permission, in settings: XCUIApplication,
                                  evidence: PermissionEvidence) throws -> XCUIElement? {
        let predicate = NSPredicate(format: "label IN %@ OR identifier IN %@", permission.titles, permission.titles)
        let named = settings.switches.matching(predicate)
        evidence.namedSwitchMatches = min(20, named.count)
        try require(named.count <= 1, "The exact named permission switch is ambiguous; no action is sent.")
        if named.count == 1 { evidence.selector = "exactNamedSwitch"; return named.firstMatch }
        let rows = permission.titles.map { settings.cells.containing(.staticText, identifier: $0) }
        let count = rows.reduce(0) { $0 + $1.count }
        evidence.namedCellMatches = min(20, count)
        try require(count <= 1, "The exact named permission row is ambiguous; no action is sent.")
        guard let row = rows.first(where: { $0.count == 1 })?.firstMatch else { return nil }
        let labels = row.staticTexts.matching(predicate)
        try require(labels.count == 1 && row.switches.count <= 1,
                    "The exact named row must expose one matching label and at most one switch.")
        guard row.switches.count == 1 else { return nil }
        evidence.selector = "uniqueSwitchInExactNamedCell"
        return row.switches.firstMatch
    }

    @MainActor
    private func booleanValue(_ control: XCUIElement) throws -> Bool {
        switch control.value as? String {
        case "1": return true
        case "0": return false
        default: throw Failure.blocked
        }
    }

    @MainActor
    private func wait(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.15)
        } while true
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { XCTFail(message); throw Failure.blocked }
    }

    @MainActor private final class PermissionEvidence {
        weak var testCase: XCTestCase?
        let app: XCUIApplication
        let permission: String
        let action: String
        let startedAt = Date().timeIntervalSince1970
        let appStateAtStart: Int
        var phase = "preflight"
        var ownSettingsPageVerified = false
        var namedSwitchMatches = 0
        var namedCellMatches = 0
        var selector: String?
        var beforeAllowed: Bool?
        var afterAllowed: Bool?
        var settingsOpenRequestedAt: TimeInterval?
        var requestedAt: TimeInterval?
        var confirmedAt: TimeInterval?
        var toggleAttempts = 0
        var appStateBeforeToggle: Int?
        var appNotRunningObservedAfterAction = false
        var inspection: [String: Any]?
        var explicitScreenshotsCaptured = 0
        private var attached = false
        init(testCase: XCTestCase, app: XCUIApplication, permission: String, action: String) {
            self.testCase = testCase; self.app = app; self.permission = permission; self.action = action
            appStateAtStart = Int(app.state.rawValue)
        }
        func attach() {
            guard !attached else { return }; attached = true
            if toggleAttempts > 0 && app.state == .notRunning { appNotRunningObservedAfterAction = true }
            let metadata: [String: Any] = [
                "helper": "externalNamedEiscuePermission", "permission": permission, "action": action, "phase": phase,
                "startedAt": startedAt, "finishedAt": Date().timeIntervalSince1970,
                "ownSettingsPageVerified": ownSettingsPageVerified,
                "namedSwitchMatches": namedSwitchMatches, "namedCellMatches": namedCellMatches,
                "selector": selector as Any? ?? NSNull(),
                "beforeAllowed": beforeAllowed as Any? ?? NSNull(), "afterAllowed": afterAllowed as Any? ?? NSNull(),
                "settingsOpenRequestedAt": settingsOpenRequestedAt as Any? ?? NSNull(),
                "requestedAt": requestedAt as Any? ?? NSNull(), "confirmedAt": confirmedAt as Any? ?? NSNull(),
                "toggleAttempts": toggleAttempts, "appStateAtStart": appStateAtStart,
                "appStateBeforeToggle": appStateBeforeToggle as Any? ?? NSNull(), "appStateAtEnd": Int(app.state.rawValue),
                "appNotRunningObservedAfterAction": appNotRunningObservedAfterAction,
                "permissionChangeCanTerminateApp": true, "osTerminationAttributionVerified": false,
                "appAcceptanceVerified": false, "modelRequests": 0, "connectionChangeRequested": false,
                "inspection": inspection as Any? ?? NSNull(),
                "explicitScreenshotsCaptured": explicitScreenshotsCaptured, "chatOrDraftTextRead": false, "otherPermissionValuesRead": false,
                "automaticRestoreAttempted": false, "separateRestoreRequiredAfterDeny": action == "deny"
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted]),
                  let text = String(data: data, encoding: .utf8) else { return }
            let attachment = XCTAttachment(string: text)
            attachment.name = "Eiscue named system permission — \(permission) — \(action) — metadata only"
            attachment.lifetime = .keepAlways; testCase?.add(attachment)
        }
    }
}
