import XCTest

/// Opt-in checks use the saved model once, or prepare/recover without sending.
/// Host-flow success still needs the scenario's independent visual/report review.
final class RealModelCalculatorAcceptanceUITests: XCTestCase {
    @MainActor private var failureEvidence: (@MainActor () -> Void)?

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Real-model acceptance and read-only preparation require an explicitly prepared physical iPhone.")
        #else
        let environment = ProcessInfo.processInfo.environment
        let modes = ["EISCUE_REAL_MODEL_TEST", "EISCUE_REAL_MODEL_RECOVERY", "EISCUE_APPEARANCE_PREPARE"]
        guard modes.filter({ environment[$0] == "1" }).count == 1 else {
            throw XCTSkip("Enable exactly one real-model, recovery or read-only preparation mode; conflicting opt-ins perform no action.")
        }
        #endif
    }

    /// Read-only preparation, with a separate gate that never authorizes a model request.
    @MainActor
    func testPrepareAppearanceBaselinePage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_APPEARANCE_PREPARE"] == "1",
              environment["EISCUE_REAL_MODEL_TEST"] != "1", environment["EISCUE_REAL_MODEL_RECOVERY"] != "1" else {
            throw XCTSkip("Use only TEST_RUNNER_EISCUE_APPEARANCE_PREPARE=1 for read-only preparation.")
        }
        let evidence = AppearanceEvidence(testCase: self, helper: "prepareAppearanceBaselinePage")
        failureEvidence = { evidence.finish() }
        defer { evidence.finish() }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Prepare the normal foreground Eiscue App and resolve dialogs separately.")
        if app.buttons["deviceConnectionMethodPicker"].exists { returnToAssistant(in: app) }
        let baseline = try readMetadata(in: app, appearance: evidence)
        try require(baseline.isIdle && !baseline.ownerHeld && baseline.activeRunID == nil && baseline.keyboardModeIdle
                    && !baseline.needsRecovery && !baseline.hasDeviceContinuation,
                    "Preparation requires no active task, device owner, speech or recovery work.")
        do {
            try openAppearancePage(in: settings, evidence: evidence)
            evidence.report.before = try readAppearance(in: settings, wait: true)
            recordAppearanceTarget(in: settings, phase: "preparedAppearance", evidence: evidence)
        } catch {
            recordAppearanceTarget(in: settings, phase: "preparationFailed", evidence: evidence)
            if app.state != .notRunning { app.activate() }
            try require(false, "The system appearance page with one selected Light/Dark choice was unavailable; no setting was changed.")
            return
        }
        if app.state != .notRunning { app.activate() }
        try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Eiscue did not return normally after read-only Settings preparation.")
        let after = try readMetadata(in: app, appearance: evidence)
        try requireUnchangedConfiguration(after, baseline: baseline)
        try require(after.isIdle && !after.ownerHeld && after.activeRunID == nil && after.keyboardModeIdle,
                    "Read-only preparation must leave Eiscue idle.")
        evidence.report.result = usesSeparateAppearancePage ? "appearancePagePreparedNoModelRequest" : "displayBrightnessPreparedNoModelRequest"
    }

    /// Bounded inspection of known Settings navigation/appearance elements only.
    /// Navigates only to the OS-specific page; no setting is changed or imaged.
    @MainActor
    func testInspectAppearanceTargetMetadata() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_APPEARANCE_PREPARE"] == "1",
              environment["EISCUE_REAL_MODEL_TEST"] != "1", environment["EISCUE_REAL_MODEL_RECOVERY"] != "1" else {
            throw XCTSkip("Use only TEST_RUNNER_EISCUE_APPEARANCE_PREPARE=1 for target-only inspection.")
        }
        let evidence = AppearanceEvidence(testCase: self, helper: "inspectAppearanceTargetOnly")
        failureEvidence = { evidence.finish() }
        defer { evidence.finish() }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        try require(app.state == .runningForeground && settings.state != .notRunning,
                    "Keep Eiscue foreground and the existing Settings process available.")
        if app.buttons["deviceConnectionMethodPicker"].exists { returnToAssistant(in: app) }
        let before = try readMetadata(in: app, appearance: evidence)
        try require(before.isIdle && !before.ownerHeld && before.activeRunID == nil && before.keyboardModeIdle
                    && !before.needsRecovery && !before.hasDeviceContinuation,
                    "Finish tasks, speech and recovery before read-only target inspection.")
        defer { if app.state != .notRunning { app.activate() } }
        try openAppearancePage(in: settings, evidence: evidence)
        recordAppearanceTarget(in: settings, phase: "inspectOSSpecificAppearancePage", evidence: evidence)
        evidence.report.before = try? readAppearance(in: settings, wait: false)
        evidence.report.result = "targetMetadataOnlyNotAcceptance"
    }

    /// Inspect keyword-matched appearance elements of every type, including
    /// images, after navigating to the OS-specific system appearance page.
    /// No setting change, screenshot or model request is performed.
    @MainActor
    func testInspectAppearanceChoiceElements() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_APPEARANCE_PREPARE"] == "1",
              environment["EISCUE_REAL_MODEL_TEST"] != "1", environment["EISCUE_REAL_MODEL_RECOVERY"] != "1" else {
            throw XCTSkip("Use only TEST_RUNNER_EISCUE_APPEARANCE_PREPARE=1 for bounded appearance-element inspection.")
        }
        let evidence = AppearanceEvidence(testCase: self, helper: "inspectAppearanceChoiceElementsOnly")
        failureEvidence = { evidence.finish() }
        defer { evidence.finish() }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try require(app.state == .runningForeground && settings.state != .notRunning
                    && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Keep normal Eiscue foreground and the existing Settings process available.")
        if app.buttons["deviceConnectionMethodPicker"].exists { returnToAssistant(in: app) }
        let before = try readMetadata(in: app, appearance: evidence)
        try require(before.isIdle && !before.ownerHeld && before.activeRunID == nil && before.keyboardModeIdle
                    && !before.needsRecovery && !before.hasDeviceContinuation,
                    "Finish tasks, speech and recovery before the read-only target inspection.")
        defer { if app.state != .notRunning { app.activate() } }
        try openAppearancePage(in: settings, evidence: evidence)
        func exactPage() -> Bool {
            let bars = knownAppearanceElements(in: settings, type: .navigationBar,
                                              titles: appearancePageTitles)
            return settings.state == .runningForeground && bars.count == 1 && bars.firstMatch.isHittable
                && settings.alerts.count == 0 && springboard.alerts.count == 0
        }
        try require(waitForAppearanceCondition(seconds: 5, exactPage),
                    "Only the exact OS-specific system appearance page may be inspected.")
        evidence.report.appearanceElementInspectionPageVerified = true
        recordAppearanceTarget(in: settings, phase: "beforeKeywordElementInspection", evidence: evidence)
        let words = ["Light", "Dark", "浅色", "深色", "Appearance", "外观"]
        let predicates = words.flatMap { word in
            [NSPredicate(format: "label CONTAINS[c] %@", word), NSPredicate(format: "identifier CONTAINS[c] %@", word)]
        }
        let matches = settings.descendants(matching: .any).matching(NSCompoundPredicate(orPredicateWithSubpredicates: predicates))
        let count = matches.count
        evidence.report.appearanceElementMatchCount = count
        evidence.report.appearanceElementListTruncated = count > 40
        for index in 0..<min(count, 40) {
            try require(exactPage(), "The exact target page changed during bounded element inspection.")
            let element = matches.element(boundBy: index)
            let label = element.label, identifier = element.identifier
            // Long aggregate accessibility labels can contain unrelated page
            // contents. Omit them entirely instead of exporting a prefix.
            let labelAllowed = label.count <= 96
            let identifierAllowed = identifier.count <= 120
            let rect = element.frame
            let frame = [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
                ? AppearanceElementFrame(x: Double(rect.minX), y: Double(rect.minY),
                                         width: Double(rect.width), height: Double(rect.height)) : nil
            let selectedValue: Bool?
            if let raw = element.value as? String {
                switch raw.lowercased() {
                case "1", "true", "selected", "已选择", "已选中", "选中": selectedValue = true
                case "0", "false", "not selected", "未选择", "未选中", "未选定": selectedValue = false
                default: selectedValue = nil
                }
            } else { selectedValue = nil }
            evidence.report.appearanceElements.append(.init(type: String(describing: element.elementType),
                typeRawValue: Int(element.elementType.rawValue), label: labelAllowed ? label : nil,
                identifier: identifierAllowed ? identifier : nil, labelOmittedForLength: !labelAllowed,
                identifierOmittedForLength: !identifierAllowed, selected: element.isSelected,
                selectedValue: selectedValue, hittable: element.isHittable, frame: frame))
        }
        try require(exactPage(), "The exact target page changed before inspection completed.")
        evidence.report.result = "boundedAppearanceElementsOnlyNotAcceptance"
    }

    /// Locate visible appearance/theme/wallpaper navigation labels on the
    /// exact Settings root. Candidate rows are never opened or screenshotted.
    @MainActor
    func testInspectSettingsRootAppearanceRows() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_APPEARANCE_PREPARE"] == "1",
              environment["EISCUE_REAL_MODEL_TEST"] != "1", environment["EISCUE_REAL_MODEL_RECOVERY"] != "1" else {
            throw XCTSkip("Use only TEST_RUNNER_EISCUE_APPEARANCE_PREPARE=1 for read-only Settings-root discovery.")
        }
        let evidence = AppearanceEvidence(testCase: self, helper: "inspectSettingsRootAppearanceRowsOnly")
        failureEvidence = { evidence.finish() }
        defer { evidence.finish() }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Keep normal Eiscue foreground without dialogs; no launch or model request is attempted.")
        if app.buttons["deviceConnectionMethodPicker"].exists { returnToAssistant(in: app) }
        let before = try readMetadata(in: app, appearance: evidence)
        try require(before.isIdle && !before.ownerHeld && before.activeRunID == nil && before.keyboardModeIdle
                    && !before.needsRecovery && !before.hasDeviceContinuation,
                    "Finish tasks, speech and recovery before read-only Settings-root discovery.")
        defer { if app.state != .notRunning { app.activate() } }
        if settings.state != .notRunning { settings.activate() }
        @MainActor func exactRoot() -> Bool {
            let bars = knownAppearanceElements(in: settings, type: .navigationBar, titles: ["Settings", "设置"])
            return settings.state == .runningForeground && bars.count == 1 && bars.firstMatch.isHittable
                && settings.alerts.count == 0 && springboard.alerts.count == 0
        }
        if exactRoot() {
            evidence.report.rootInspectionNavigation = "existingSettingsRoot"
        } else {
            let displayBars = knownAppearanceElements(in: settings, type: .navigationBar,
                                                     titles: ["Display & Brightness", "显示与亮度"])
            if settings.state == .runningForeground, displayBars.count == 1,
               displayBars.firstMatch.isHittable, settings.alerts.count == 0, springboard.alerts.count == 0 {
                let back = displayBars.firstMatch.buttons.matching(NSPredicate(
                    format: "label IN %@ OR identifier IN %@", ["Settings", "设置"], ["Settings", "设置"]))
                if back.count == 1 && back.firstMatch.isEnabled && back.firstMatch.isHittable {
                    evidence.report.rootInspectionBackTaps = 1
                    back.firstMatch.tap()
                    if waitForAppearanceCondition(seconds: 5, exactRoot) {
                        evidence.report.rootInspectionNavigation = "knownDisplayBackButton"
                    }
                }
            }
            if !exactRoot() {
                try require((settings.state == .notRunning || settings.alerts.count == 0) && springboard.alerts.count == 0,
                            "Resolve Settings dialogs separately; no dialog is handled by discovery.")
                evidence.report.rootInspectionURLRequests = 1
                settings.open(URL(string: "prefs:root")!)
                try require(waitForAppearanceCondition(seconds: 5, exactRoot),
                            "The root URL did not reach an exact Settings navigation page; nothing else is inspected.")
                evidence.report.rootInspectionNavigation = "settingsRootURL"
            }
        }
        try require(exactRoot(), "Only an exact Settings root may be inspected.")
        evidence.report.rootInspectionPageVerified = true
        // A unique list keeps every scroll within the verified root content.
        // No account header, other row label or setting value is queried.
        @MainActor func rootList() throws -> XCUIElement {
            try require(exactRoot(), "The Settings root changed before list inspection.")
            let choices = [settings.tables, settings.collectionViews, settings.scrollViews]
            for query in choices where query.count == 1 {
                if query.firstMatch.isHittable { return query.firstMatch }
            }
            try require(false, "The exact Settings root has no unique visible list; no scroll is attempted.")
            throw AppearanceReadError.exactTargetUnavailable
        }
        let words = ["Appearance", "外观", "Theme", "主题", "Wallpaper", "墙纸"]
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: words.map {
            NSPredicate(format: "label CONTAINS[c] %@", $0)
        })
        var seen = Set<String>()
        for step in 0...6 {
            let list = try rootList()
            let matches = list.descendants(matching: .any).matching(predicate)
            evidence.report.rootInspectionMatchCounts.append(min(100, matches.count))
            for index in 0..<min(matches.count, 40) {
                try require(exactRoot(), "The root changed during bounded target-label inspection.")
                let element = matches.element(boundBy: index)
                switch element.elementType {
                case .cell, .button, .staticText, .link, .other: break
                default: continue
                }
                guard element.isHittable else { continue }
                let label = element.label
                guard !label.isEmpty && label.count <= 96 else { continue }
                let identifier = element.identifier
                let type = element.elementType
                let key = String(type.rawValue) + "|" + label + "|" + String(identifier.prefix(120))
                guard seen.insert(key).inserted else { continue }
                let rect = element.frame
                guard rect.width > 0 && rect.height > 0,
                      [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { continue }
                evidence.report.rootAppearanceRows.append(.init(scrollStep: step,
                    type: String(describing: type), typeRawValue: Int(type.rawValue), label: label,
                    identifier: identifier.count <= 120 ? identifier : nil,
                    identifierOmittedForLength: identifier.count > 120,
                    frame: .init(x: Double(rect.minX), y: Double(rect.minY),
                                 width: Double(rect.width), height: Double(rect.height))))
                if evidence.report.rootAppearanceRows.count == 40 { break }
            }
            if step == 6 || evidence.report.rootAppearanceRows.count == 40 { break }
            try require(exactRoot(), "The exact Settings root must remain visible before a bounded scroll.")
            // Revisit the preceding root rows, then inspect later rows. These
            // are scrolling gestures only; no matching navigation row is tapped.
            let direction = step < 2 ? "down" : "up"
            evidence.report.rootInspectionScrollDirections.append(direction)
            if step < 2 { list.swipeDown() } else { list.swipeUp() }
        }
        try require(exactRoot(), "The exact Settings root changed before discovery completed.")
        evidence.report.result = "boundedSettingsRootTargetRowsOnlyNotAcceptance"
    }

    /// Separate, image-only opt-in for diagnosing OS changes to this exact page.
    @MainActor
    func testCaptureAppearanceTarget() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_APPEARANCE_PREPARE"] == "1",
              environment["EISCUE_APPEARANCE_IMAGE"] == "1",
              environment["EISCUE_REAL_MODEL_TEST"] != "1",
              environment["EISCUE_REAL_MODEL_RECOVERY"] != "1" else {
            throw XCTSkip("Explicitly opt in to a local image of the identified OS-specific system appearance page.")
        }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let evidence = AppearanceEvidence(testCase: self, helper: "captureAppearanceTarget")
        defer { evidence.finish(); if app.state != .notRunning { app.activate() } }
        try require(app.state == .runningForeground && app.alerts.count == 0,
                    "Keep normal Eiscue foreground without a dialog.")
        if app.buttons["deviceConnectionMethodPicker"].exists { returnToAssistant(in: app) }
        let before = try readMetadata(in: app, appearance: evidence)
        try require(before.isIdle && !before.ownerHeld && before.activeRunID == nil && before.keyboardModeIdle,
                    "Finish tasks and speech before inspecting Settings.")
        try openAppearancePage(in: settings, evidence: evidence)
        try require(appearancePageIdentified(in: settings) && settings.alerts.count == 0
                    && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0,
                    "Capture only the identified OS-specific system appearance page without a dialog.")
        let attachment = XCTAttachment(screenshot: settings.screenshot())
        attachment.name = "\(appearancePageName) — explicit local inspection"
        attachment.lifetime = .keepAlways
        add(attachment)
        evidence.report.explicitScreenshotsCaptured = 1
        evidence.report.result = "appearanceTargetImageOnlyNoModelRequest"
    }

    /// Uses the saved profile once. Settings screenshots, other settings values and
    /// message bodies are never attached; the final model report needs live review.
    @MainActor
    func testCurrentSavedModelReadOnlyAppearanceFlow() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_REAL_MODEL_TEST"] == "1", environment["EISCUE_REAL_MODEL_RECOVERY"] != "1",
              environment["EISCUE_APPEARANCE_PREPARE"] != "1" else {
            throw XCTSkip("Use only TEST_RUNNER_EISCUE_REAL_MODEL_TEST=1 for the single appearance request.")
        }
        let evidence = AppearanceEvidence(testCase: self, helper: "realModelReadOnlyAppearanceHostFlow")
        failureEvidence = { evidence.finish() }
        defer { evidence.finish() }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Prepare normal foreground Eiscue; no authorization is automated.")
        if app.buttons["deviceConnectionMethodPicker"].exists { returnToAssistant(in: app) }
        let baseline = try readMetadata(in: app, appearance: evidence)
        try requireReadyEmptyComposer(baseline)
        try require(baseline.timeoutSeconds > 0 && baseline.timeoutSeconds <= 3_600,
                    "The saved deadline must be positive and no longer than one hour; no setting is changed.")
        try require(settings.state != .notRunning,
                    "Run the read-only appearance preparation helper first; this check never launches Settings before its model request.")

        // The separate preparation helper must have left this exact page available.
        // A unique known back button can return to Settings root, without touching a preference.
        do {
            settings.activate()
            evidence.report.before = try readAppearance(in: settings, wait: true)
            recordAppearanceTarget(in: settings, phase: "beforeModel", evidence: evidence)
            let page = knownAppearanceElements(in: settings, type: .navigationBar, titles: appearancePageTitles)
            let back = page.firstMatch.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
                ["Settings", "设置"], ["Settings", "设置"]))
            if back.count == 1 && back.firstMatch.isEnabled && back.firstMatch.isHittable {
                back.firstMatch.tap()
                evidence.report.settingsRootBeforeSend = waitForAppearanceCondition(seconds: 5) {
                    settingsRootIdentified(in: settings)
                }
            }
            if evidence.report.settingsRootBeforeSend {
                evidence.report.navigationCoverage = usesSeparateAppearancePage ? "settingsRootToAppearance" : "settingsRootToDisplayBrightness"
            }
        } catch {
            recordAppearanceTarget(in: settings, phase: "beforeModelFailed", evidence: evidence)
            if app.state != .notRunning { app.activate() }
            try require(false, "Run the read-only appearance preparation helper first; no model request was sent.")
            return
        }
        if app.state != .notRunning { app.activate() }
        try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Eiscue must be foreground before composing the new request.")
        try requireReadyEmptyComposer(try readMetadata(in: app, appearance: evidence))
        let newConversation = app.buttons["newConversationButton"]
        if !newConversation.isHittable {
            let history = app.buttons["historyButton"]
            try require(history.isEnabled && history.isHittable, "The normal Assistant sidebar is unavailable.")
            history.tap()
        }
        try require(newConversation.waitForExistence(timeout: 5) && newConversation.isEnabled && newConversation.isHittable,
                    "The ordinary New conversation action is unavailable.")
        newConversation.tap()
        let input = app.textFields["messageInput"].exists ? app.textFields["messageInput"] : app.textViews["messageInput"]
        try require(input.waitForExistence(timeout: 5) && input.isEnabled && input.isHittable,
                    "The new conversation requires the normal keyboard composer.")
        let fresh = try readMetadata(in: app, appearance: evidence)
        try requireReadyEmptyComposer(fresh)
        try requireUnchangedConfiguration(fresh, baseline: baseline)
        try require(fresh.selectedConversationID == nil && fresh.selectedMessageCount == 0 && fresh.run == nil,
                    "Existing conversation history must not be reused.")
        let nonce = UUID()
        evidence.report.acceptanceID = nonce
        let prompt = """
        [Real-model read-only appearance acceptance \(nonce.uuidString)] Open the system Settings app, navigate to \(appearancePageName), and observe which Appearance option is currently selected: Light or Dark. Do not tap either appearance option, change any setting, or operate other apps. Return to Eiscue and report only the appearance selection you actually observed.
        """
        input.tap(); input.typeText(prompt)
        try require(input.value as? String == prompt, "The exact new request was not composed; nothing is sent.")
        let beforeSend = try readMetadata(in: app, appearance: evidence)
        try requireUnchangedConfiguration(beforeSend, baseline: baseline)
        try require(beforeSend.isIdle && !beforeSend.ownerHeld && beforeSend.keyboardModeIdle && beforeSend.activeRunID == nil
                    && beforeSend.selectedConversationID == nil && beforeSend.selectedMessageCount == 0 && beforeSend.run == nil
                    && beforeSend.attachmentCount == 0 && !beforeSend.draftEmpty && beforeSend.hasConfiguredModel
                    && beforeSend.isDeviceReady && beforeSend.newRunScope == "control"
                    && !beforeSend.needsRecovery && !beforeSend.hasDeviceContinuation,
                    "The prepared model, device or new composer changed before sending.")
        let send = app.buttons["sendMessageButton"]
        try require(send.isEnabled && send.isHittable && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Normal Send is unavailable or a dialog needs separate attention.")
        evidence.report.sentAt = Date().timeIntervalSince1970
        evidence.report.sendAttempts = 1
        evidence.report.waitLimitSeconds = min(baseline.timeoutSeconds, 600) + 60
        send.tap()
        let deadline = ContinuousClock.now + .seconds(evidence.report.waitLimitSeconds!)
        var nextAppearanceCheck = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try require(app.state != .notRunning, "Eiscue exited; no relaunch or retry is automated.")
            if settings.state == .runningForeground {
                evidence.report.settingsForegroundObserved = true
                if ContinuousClock.now >= nextAppearanceCheck && evidence.report.appearanceChecks < 120 {
                    if let observed = try? readAppearance(in: settings, wait: false) {
                        evidence.report.appearancePageObservedDuringRun = true
                        if !usesSeparateAppearancePage { evidence.report.displayBrightnessObservedDuringRun = true }
                        evidence.report.appearanceChecks += 1
                        if observed != evidence.report.before { evidence.report.appearanceChangedAtCheck = true }
                    }
                    nextAppearanceCheck = .now + .seconds(1)
                }
            }
            if app.state == .runningForeground {
                if evidence.report.settingsForegroundObserved { evidence.report.autonomousReturnObserved = true }
                try require(app.alerts.count == 0 && springboard.alerts.count == 0,
                            "A dialog interrupted the run; no permission or retry is automated.")
                let snapshot = try readMetadata(in: app, appearance: evidence)
                try requireUnchangedConfiguration(snapshot, baseline: baseline)
                if let run = snapshot.run {
                    try require(run.startedAt >= (evidence.report.sentAt ?? .greatestFiniteMagnitude) - 1
                                && run.conversationID == snapshot.selectedConversationID && run.conversationID != baseline.selectedConversationID,
                                "The projected record does not belong to this new request.")
                    if let id = evidence.report.runID {
                        try require(run.id == id && run.requestID == evidence.report.requestID && run.conversationID == evidence.report.conversationID,
                                    "The bound run changed; no replacement run is followed.")
                    } else {
                        evidence.report.runID = run.id; evidence.report.requestID = run.requestID
                        evidence.report.conversationID = run.conversationID
                    }
                    try require(snapshot.activeRunID == nil || snapshot.activeRunID == run.id, "Another active run appeared.")
                    if run.endedAt != nil && snapshot.activeRunID == nil && snapshot.isIdle && !snapshot.ownerHeld {
                        try require(run.scope == "control" && run.submission == "accepted" && run.state == "completed"
                                    && !run.stopped && !run.unknownOutcome && !run.cleanupFailed && run.activities.allSatisfy { $0.endedAt != nil },
                                    "The bound run did not complete cleanly; it is not continued or retried.")
                        evidence.report.successfulInputs = run.activities.filter {
                            !$0.isError && ["device_tap", "device_press_key", "device_launch_app"].contains($0.name ?? "")
                        }.count
                        evidence.report.observations = run.events.filter { $0.kind == "observation.captured" }.count
                        try require(evidence.report.successfulInputs > 0 && evidence.report.observations > 0
                                    && run.events.contains { $0.kind == "action.acknowledged" }
                                    && evidence.report.appearancePageObservedDuringRun && evidence.report.autonomousReturnObserved,
                                    "Actual Settings target observation, device input and autonomous return are required.")
                        // This independent after-check starts only after autonomous return and settlement.
                        do {
                            try openAppearancePage(in: settings, evidence: evidence)
                            evidence.report.after = try readAppearance(in: settings, wait: true)
                            recordAppearanceTarget(in: settings, phase: "afterModel", evidence: evidence)
                        } catch {
                            recordAppearanceTarget(in: settings, phase: "afterModelFailed", evidence: evidence)
                            if app.state != .notRunning { app.activate() }
                            try require(false, "The independent read-only appearance after-check was unavailable.")
                            return
                        }
                        if app.state != .notRunning { app.activate() }
                        try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                                    "Eiscue must return normally after the independent verification.")
                        let final = try readMetadata(in: app, appearance: evidence)
                        try requireUnchangedConfiguration(final, baseline: baseline)
                        try require(final.isIdle && !final.ownerHeld && final.activeRunID == nil && final.run?.id == run.id,
                                    "The completed run changed during independent verification.")
                        evidence.report.appearanceUnchangedAtChecks = evidence.report.before == evidence.report.after
                            && !evidence.report.appearanceChangedAtCheck
                        try require(evidence.report.appearanceUnchangedAtChecks,
                                    "Appearance changed at an observed boundary; this helper never restores a setting.")
                        evidence.report.hostFlowCompleted = true
                        evidence.report.result = "hostFlowCompletedNeedsLiveAppearanceReportReview"
                        return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        try require(false, "The bounded appearance check expired; the run is left intact without stop, continuation or retry.")
    }

    @MainActor
    func testCurrentSavedModelCalculatorFlow() async throws {
        guard ProcessInfo.processInfo.environment["EISCUE_REAL_MODEL_TEST"] == "1",
              ProcessInfo.processInfo.environment["EISCUE_REAL_MODEL_RECOVERY"] != "1",
              ProcessInfo.processInfo.environment["EISCUE_APPEARANCE_PREPARE"] != "1" else {
            throw XCTSkip("Recovery and preparation opt-ins never start a model request.")
        }
        let evidence = Evidence(testCase: self)
        failureEvidence = { evidence.finish() }
        // Attach before our explicit assertion failures as well as on ordinary
        // return/throw. Teardown must neither await MainActor nor assume its executor.
        defer { evidence.finish() }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let calculator = XCUIApplication(bundleIdentifier: "com.apple.calculator")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        try require(app.state == .runningForeground,
                    "Prepare the normal foreground Eiscue App first; this helper never launches or activates it.")
        try require(app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Resolve existing dialogs separately; this helper handles no authorization.")
        // Connection preparation ends on the normal device page. Return via
        // the existing navigation control without changing its connection.
        if app.buttons["deviceConnectionMethodPicker"].exists {
            returnToAssistant(in: app)
        }
        let baseline = try readMetadata(in: app, evidence: evidence)
        try requireReadyEmptyComposer(baseline)
        try require(baseline.normalAppMode,
                    "Launch the normal App with only --real-model-acceptance-diagnostics, without fixtures or other automation flags.")
        try require(baseline.timeoutSeconds > 0 && baseline.timeoutSeconds <= 3_600,
                    "The saved run deadline must be positive and no longer than one hour; this helper changes no settings.")

        // New conversation clears the composer, so refuse even whitespace or
        // attachments before opening the sidebar. No draft is discarded.
        let newConversation = app.buttons["newConversationButton"]
        if !newConversation.isHittable {
            let history = app.buttons["historyButton"]
            try require(history.isHittable && history.isEnabled, "Open the normal Assistant page first.")
            try requireReadyEmptyComposer(try readMetadata(in: app, evidence: evidence))
            history.tap()
        }
        try require(newConversation.waitForExistence(timeout: 5) && newConversation.isHittable && newConversation.isEnabled,
                    "The normal New conversation action is unavailable; no alternate action is attempted.")
        newConversation.tap()
        let input = app.textFields["messageInput"].exists
            ? app.textFields["messageInput"] : app.textViews["messageInput"]
        try require(input.waitForExistence(timeout: 5) && input.isHittable && input.isEnabled,
                    "The new conversation must expose its ordinary keyboard composer.")
        let fresh = try readMetadata(in: app, evidence: evidence)
        try requireReadyEmptyComposer(fresh)
        try requireUnchangedConfiguration(fresh, baseline: baseline)
        try require(fresh.selectedConversationID == nil && fresh.selectedMessageCount == 0 && fresh.run == nil,
                    "A fresh empty conversation is required; existing history is never reused.")

        let nonce = UUID()
        evidence.report.acceptanceID = nonce
        let prompt = """
        [Real-model acceptance \(nonce.uuidString)] Open the system Calculator, clear its current expression, actually enter 17 times 23 and press equals. Observe the Calculator result, then return to Eiscue and report the result you actually saw. Do not change settings or operate other apps.
        """
        input.tap()
        input.typeText(prompt)
        try require(input.value as? String == prompt,
                    "The composer does not contain exactly this new request; it is left untouched and nothing is sent.")
        let beforeSend = try readMetadata(in: app, evidence: evidence)
        try requireUnchangedConfiguration(beforeSend, baseline: baseline)
        try require(beforeSend.isIdle && !beforeSend.ownerHeld && beforeSend.keyboardModeIdle
                    && beforeSend.selectedConversationID == nil && beforeSend.selectedMessageCount == 0
                    && beforeSend.run == nil && beforeSend.attachmentCount == 0 && !beforeSend.draftEmpty
                    && beforeSend.hasConfiguredModel && beforeSend.isDeviceReady && beforeSend.newRunScope == "control"
                    && !beforeSend.needsRecovery && !beforeSend.hasDeviceContinuation,
                    "The new composer changed before submission; nothing is sent.")
        let send = app.buttons["sendMessageButton"]
        try require(send.isEnabled && send.isHittable && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Normal Send is unavailable or a dialog requires separate attention.")
        evidence.report.sentAt = Date().timeIntervalSince1970
        evidence.report.sendAttempts = 1
        send.tap()

        let deadline = ContinuousClock.now + .seconds(baseline.timeoutSeconds + 60)
        var nextFrame = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try require(app.state != .notRunning,
                        "Eiscue exited; this helper will not relaunch it or retry the request.")
            if calculator.state == .runningForeground {
                evidence.report.calculatorForegroundObserved = true
                if ContinuousClock.now >= nextFrame {
                    evidence.frames.append((Date().timeIntervalSince1970, calculator.screenshot()))
                    if evidence.frames.count > 12 { evidence.frames.removeFirst() }
                    nextFrame = ContinuousClock.now + .seconds(1)
                }
            }
            let appIsForeground = app.state == .runningForeground
            if evidence.report.calculatorForegroundObserved && !appIsForeground { evidence.report.leftEiscueForegroundObserved = true }
            if appIsForeground {
                if evidence.report.leftEiscueForegroundObserved { evidence.report.returnedToEiscueObserved = true }
                try require(app.alerts.count == 0 && springboard.alerts.count == 0,
                            "A dialog interrupted the run; no authorization or retry is automated.")
                let snapshot = try readMetadata(in: app, evidence: evidence)
                try requireUnchangedConfiguration(snapshot, baseline: baseline)
                if let run = snapshot.run {
                    try require(run.startedAt >= (evidence.report.sentAt ?? .greatestFiniteMagnitude) - 1
                                && run.conversationID == snapshot.selectedConversationID
                                && run.conversationID != baseline.selectedConversationID,
                                "The projected record is not the newly submitted conversation/run.")
                    if let id = evidence.report.runID {
                        try require(run.id == id && run.requestID == evidence.report.requestID
                                    && run.conversationID == evidence.report.conversationID,
                                    "The run identity changed; this helper never follows a replacement run.")
                    } else {
                        evidence.report.runID = run.id; evidence.report.requestID = run.requestID
                        evidence.report.conversationID = run.conversationID
                    }
                    try require(snapshot.activeRunID == nil || snapshot.activeRunID == run.id,
                                "Another active run appeared while awaiting this request.")
                    if run.endedAt != nil && snapshot.activeRunID == nil && snapshot.isIdle && !snapshot.ownerHeld {
                        try require(run.scope == "control" && run.submission == "accepted" && run.state == "completed"
                                    && !run.stopped && !run.unknownOutcome && !run.cleanupFailed,
                                    "The bound normal run did not complete cleanly; no continuation or retry is attempted.")
                        let successes = run.activities.filter { $0.endedAt != nil && !$0.isError }
                        let inputNames = ["device_tap", "device_type_text", "device_press_key"]
                        try require(run.activities.allSatisfy { $0.endedAt != nil }
                                    && successes.contains { inputNames.contains($0.name ?? "") }
                                    && run.events.contains { $0.kind == "action.acknowledged" }
                                    && run.events.contains { $0.kind == "observation.captured" },
                                    "Completion lacks successful device input and observation evidence; prose alone is insufficient.")
                        try require(evidence.report.calculatorForegroundObserved && evidence.report.returnedToEiscueObserved && !evidence.frames.isEmpty,
                                    "Calculator foreground evidence and Eiscue's autonomous return are both required.")
                        evidence.report.hostFlowCompleted = true
                        evidence.report.result = "hostFlowCompletedNeedsCalculatorScreenshotReview"
                        evidence.returnedAppScreenshot = app.screenshot()
                        return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        try require(false, "The bound run did not settle before its saved deadline plus cleanup allowance. It is left intact; no stop, relaunch or retry is automated.")
    }

    /// Ends only the explicitly named paused run through normal UI. No send,
    /// continuation, launch, activation or authorization action is performed.
    @MainActor
    func testEndExpectedPausedRunAndDisconnect() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_REAL_MODEL_RECOVERY"] == "1", environment["EISCUE_REAL_MODEL_TEST"] != "1",
              environment["EISCUE_APPEARANCE_PREPARE"] != "1" else {
            throw XCTSkip("Use only TEST_RUNNER_EISCUE_REAL_MODEL_RECOVERY=1 for exact-run recovery.")
        }
        let evidence = RecoveryEvidence(testCase: self)
        failureEvidence = { evidence.finish() }
        defer { evidence.finish() }
        let expected = try XCTUnwrap(environment["EISCUE_REAL_MODEL_RECOVERY_RUN_ID"].flatMap(UUID.init(uuidString:)),
                                    "Set TEST_RUNNER_EISCUE_REAL_MODEL_RECOVERY_RUN_ID to the exact authorized run UUID.")
        evidence.report.expectedRunID = expected
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                    "Prepare the foreground normal App without dialogs; this helper never launches or activates it.")
        if app.buttons["deviceConnectionMethodPicker"].exists { returnToAssistant(in: app) }
        let baseline = try readMetadata(in: app, recovery: evidence)
        let original = try XCTUnwrap(baseline.run, "The selected conversation has no run metadata.")
        try require(original.id == expected && original.conversationID == baseline.selectedConversationID
                    && original.state == "paused" && original.submission == "accepted" && original.endedAt != nil
                    && original.scope == "control" && !original.unknownOutcome && !original.cleanupFailed
                    && !baseline.isLoading && baseline.isIdle && baseline.activeRunID == nil && !baseline.ownerHeld
                    && baseline.keyboardModeIdle && !baseline.needsRecovery && baseline.isDeviceReady
                    && baseline.connectionMethod == "localVPN",
                    "Only the exact settled, accepted, control-paused run on its ready local-VPN route is authorized.")
        @MainActor func sameRun(_ value: Snapshot) throws -> Run {
            try requireUnchangedConfiguration(value, baseline: baseline)
            let run = try XCTUnwrap(value.run)
            try require(run.id == expected && run.conversationID == original.conversationID
                        && run.requestID == original.requestID && value.selectedConversationID == original.conversationID
                        && value.draftEmpty == baseline.draftEmpty && value.attachmentCount == baseline.attachmentCount,
                        "The selected run, conversation, request or composer changed; recovery stops here.")
            return run
        }
        let end = app.buttons.matching(identifier: "endPausedRunButton")
        try require(end.count == 1 && end.firstMatch.isEnabled && end.firstMatch.isHittable
                    && !app.buttons["stopRunButton"].exists && !app.buttons["endUnknownRunButton"].exists,
                    "The unique normal End paused task action must be visible and enabled.")
        let beforeEnd = try readMetadata(in: app, recovery: evidence)
        let stillPaused = try sameRun(beforeEnd)
        try require(stillPaused.state == "paused" && beforeEnd.isIdle && beforeEnd.activeRunID == nil && !beforeEnd.ownerHeld,
                    "The authorized paused run changed before its single End action.")
        evidence.report.endAttempts = 1
        end.firstMatch.tap()
        let endDeadline = ContinuousClock.now + .seconds(30)
        var ended = false
        while ContinuousClock.now < endDeadline {
            try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                        "A foreground change or dialog interrupted ending the task; no retry is attempted.")
            let snapshot = try readMetadata(in: app, recovery: evidence)
            let run = try sameRun(snapshot)
            if run.state == "failed" && run.submission == "accepted" && !run.unknownOutcome && !run.cleanupFailed
                && snapshot.isIdle && snapshot.activeRunID == nil && !snapshot.ownerHeld && !snapshot.needsRecovery
                && !app.buttons["endPausedRunButton"].exists && !app.buttons["continuePausedRunButton"].exists {
                ended = true; break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        try require(ended, "The exact paused run did not settle as ended-by-user (failed); no continuation is attempted.")
        evidence.report.pausedRunEnded = true
        openDevice(in: app)
        let disconnect = app.buttons.matching(identifier: "disconnectDeviceButton")
        try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0
                    && ["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                    && disconnect.count == 1 && disconnect.firstMatch.isEnabled && disconnect.firstMatch.isHittable,
                    "The same local-VPN route must expose its unique normal Disconnect action.")
        evidence.report.disconnectAttempts = 1
        disconnect.firstMatch.tap()
        let disconnectDeadline = ContinuousClock.now + .seconds(30)
        var disconnected = false
        while ContinuousClock.now < disconnectDeadline {
            try require(app.state == .runningForeground && app.alerts.count == 0 && springboard.alerts.count == 0,
                        "A dialog or foreground change interrupted disconnection; no retry is attempted.")
            let status = app.staticTexts["devicePairingComplete"]
            let connect = app.buttons["connectDeviceButton"]
            if status.exists && ["Not connected", "未连接"].contains(status.label)
                && !app.buttons["disconnectDeviceButton"].exists && connect.exists && connect.isEnabled {
                disconnected = true; break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        try require(disconnected, "Normal UI did not reach locally disconnected; do not overwrite-install the App.")
        returnToAssistant(in: app)
        let final = try readMetadata(in: app, recovery: evidence)
        let run = try sameRun(final)
        try require(run.state == "failed" && !run.unknownOutcome && !run.cleanupFailed && !final.isDeviceReady
                    && final.isIdle && !final.ownerHeld && final.activeRunID == nil && !final.needsRecovery,
                    "Final exact-run metadata does not confirm ended task and idle local disconnection.")
        evidence.report.locallyDisconnected = true
        evidence.report.result = "endedPausedRunAndLocallyDisconnected"
    }

    @MainActor
    private func readMetadata(in app: XCUIApplication, evidence: Evidence? = nil, recovery: RecoveryEvidence? = nil,
                              appearance: AppearanceEvidence? = nil) throws -> Snapshot {
        let element = app.descendants(matching: .any).matching(identifier: "debugRealModelRunMetadata").firstMatch
        try require(element.waitForExistence(timeout: 5),
                    "The explicit read-only real-model diagnostics projection is unavailable.")
        let value = try XCTUnwrap(element.value as? String, "Run metadata has no accessibility value.")
        let data = try XCTUnwrap(value.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        evidence?.report.lastSnapshot = snapshot
        recovery?.report.lastSnapshot = snapshot
        appearance?.report.lastSnapshot = snapshot
        try require(snapshot.version == 1 && snapshot.normalAppMode, "The App is not in normal real-state mode.")
        return snapshot
    }

    @MainActor
    private func requireReadyEmptyComposer(_ value: Snapshot) throws {
        try require(!value.isLoading && value.isIdle && !value.ownerHeld && value.activeRunID == nil
                    && value.keyboardModeIdle && !value.needsRecovery && !value.hasDeviceContinuation,
                    "The App must be idle with no pending run, recovery, setup or speech work.")
        try require(value.draftEmpty && value.attachmentCount == 0,
                    "A nonempty draft or attachments must be preserved; prepare an empty composer separately.")
        try require(value.hasConfiguredModel && value.isDeviceReady && value.newRunScope == "control",
                    "Prepare the saved model and a ready control connection through the normal UI first.")
    }

    @MainActor
    private func requireUnchangedConfiguration(_ value: Snapshot, baseline: Snapshot) throws {
        try require(value.normalAppMode && value.selectedModelProfileID == baseline.selectedModelProfileID
                    && value.connectionMethod == baseline.connectionMethod && value.controlBackend == baseline.controlBackend
                    && value.timeoutSeconds == baseline.timeoutSeconds,
                    "The selected model profile, route, backend or deadline changed during this check.")
    }

    @MainActor
    private func require(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else {
            failureEvidence?()
            XCTFail(message, file: file, line: line)
            throw CheckFailure.blocked
        }
    }

    private enum CheckFailure: Error { case blocked }

    private enum AppearanceReadError: Error { case exactTargetUnavailable }
    private struct AppearanceSelection: Codable, Equatable {
        let lightSelected: Bool
        let darkSelected: Bool
    }
    private var usesSeparateAppearancePage: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }
    private var appearancePageTitles: [String] {
        usesSeparateAppearancePage ? ["Appearance", "外观"] : ["Display & Brightness", "显示与亮度"]
    }
    private var appearancePageName: String { usesSeparateAppearancePage ? "Appearance" : "Display & Brightness" }

    @MainActor
    private func knownAppearanceElements(in settings: XCUIApplication, type: XCUIElement.ElementType,
                                         titles: [String]) -> XCUIElementQuery {
        settings.descendants(matching: type).matching(NSPredicate(format: "label IN %@ OR identifier IN %@", titles, titles))
    }

    @MainActor
    private func waitForAppearanceCondition(seconds: TimeInterval, _ condition: @MainActor () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.15)
        } while true
    }

    @MainActor
    private func appearancePageIdentified(in settings: XCUIApplication) -> Bool {
        guard settings.state == .runningForeground else { return false }
        let titles = appearancePageTitles
        let bars = knownAppearanceElements(in: settings, type: .navigationBar, titles: titles)
        if bars.count == 1 && bars.firstMatch.isHittable { return true }
        // The newly observed iOS 27 route must expose its exact page title.
        if usesSeparateAppearancePage { return false }
        // A title can be exposed as static text instead of the bar's label.
        // The same text is also a Settings-root row, so require both appearance
        // choices before treating that alternate title as the target page.
        let headings = knownAppearanceElements(in: settings, type: .staticText, titles: titles)
        let light = knownAppearanceElements(in: settings, type: .button, titles: ["Light", "浅色"])
        let dark = knownAppearanceElements(in: settings, type: .button, titles: ["Dark", "深色"])
        return headings.count == 1 && headings.firstMatch.isHittable
            && light.count == 1 && dark.count == 1 && light.firstMatch.isHittable && dark.firstMatch.isHittable
    }

    @MainActor
    private func openAppearancePage(in settings: XCUIApplication, evidence: AppearanceEvidence) throws {
        if usesSeparateAppearancePage {
            if settings.state != .notRunning { settings.activate() }
            if appearancePageIdentified(in: settings) {
                recordAppearanceTarget(in: settings, phase: "existingAppearancePage", evidence: evidence)
                return
            }
            try openObservedSettingsRoot(in: settings, evidence: evidence)
            let button = settings.buttons.matching(NSPredicate(format: "identifier == %@ AND label IN %@",
                "com.apple.settings.appearance", ["Appearance", "外观"]))
            // This identifier and English label were observed on the physical
            // iOS 27 Settings root. No Appearance URL or alternative row is used.
            for step in 0...6 {
                guard settingsRootIdentified(in: settings), button.count <= 1 else {
                    throw AppearanceReadError.exactTargetUnavailable
                }
                if button.count == 1 && button.firstMatch.isEnabled && button.firstMatch.isHittable {
                    evidence.report.appearanceRootEntryIdentifier = "com.apple.settings.appearance"
                    button.firstMatch.tap()
                    let found = waitForAppearanceCondition(seconds: 5) {
                        appearancePageIdentified(in: settings) && settings.alerts.count == 0
                            && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0
                    }
                    recordAppearanceTarget(in: settings, phase: "afterObservedAppearanceRootButton", evidence: evidence)
                    guard found else { throw AppearanceReadError.exactTargetUnavailable }
                    return
                }
                if step == 6 { break }
                let list = try settingsRootList(in: settings)
                evidence.report.appearanceNavigationRootScrolls += 1
                list.swipeDown()
            }
            recordAppearanceTarget(in: settings, phase: "observedAppearanceRootButtonUnavailable", evidence: evidence)
            throw AppearanceReadError.exactTargetUnavailable
        }
        // iOS 26 retains its existing Display & Brightness entry.
        settings.open(URL(string: "prefs:root=DISPLAY")!)
        recordAppearanceTarget(in: settings, phase: "afterDisplayDeepLink", evidence: evidence)
        if waitForAppearanceCondition(seconds: 2, { appearancePageIdentified(in: settings) }) { return }
        let root = knownAppearanceElements(in: settings, type: .navigationBar, titles: ["Settings", "设置"])
        guard settings.state == .runningForeground, root.count == 1, settings.alerts.count == 0 else {
            throw AppearanceReadError.exactTargetUnavailable
        }
        let row = knownAppearanceElements(in: settings, type: .staticText, titles: ["Display & Brightness", "显示与亮度"])
        // Only scroll the identified Settings root. No preference switch or
        // appearance control is tapped, and no unrelated label is exported.
        for step in 0..<6 {
            guard root.count == 1, settings.alerts.count == 0, row.count <= 1 else {
                throw AppearanceReadError.exactTargetUnavailable
            }
            if row.count == 1 && row.firstMatch.isEnabled && row.firstMatch.isHittable {
                row.firstMatch.tap()
                recordAppearanceTarget(in: settings, phase: "afterKnownDisplayRow", evidence: evidence)
                guard waitForAppearanceCondition(seconds: 5, { appearancePageIdentified(in: settings) }) else {
                    throw AppearanceReadError.exactTargetUnavailable
                }
                return
            }
            if step == 5 { break }
            let list = try settingsRootList(in: settings)
            if step < 2 { list.swipeDown() } else { list.swipeUp() }
        }
        recordAppearanceTarget(in: settings, phase: "displayNavigationUnavailable", evidence: evidence)
        throw AppearanceReadError.exactTargetUnavailable
    }

    @MainActor
    private func settingsRootIdentified(in settings: XCUIApplication) -> Bool {
        let bars = knownAppearanceElements(in: settings, type: .navigationBar, titles: ["Settings", "设置"])
        return settings.state == .runningForeground && bars.count == 1 && bars.firstMatch.isHittable
            && settings.alerts.count == 0 && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0
    }

    @MainActor
    private func settingsRootList(in settings: XCUIApplication) throws -> XCUIElement {
        guard settingsRootIdentified(in: settings) else { throw AppearanceReadError.exactTargetUnavailable }
        for query in [settings.tables, settings.collectionViews, settings.scrollViews] where query.count == 1 {
            if query.firstMatch.isHittable { return query.firstMatch }
        }
        throw AppearanceReadError.exactTargetUnavailable
    }

    /// Reuses the observed Display deep link and its observed Settings back
    /// button to reach root when it is not already visible. No new URL is guessed.
    @MainActor
    private func openObservedSettingsRoot(in settings: XCUIApplication, evidence: AppearanceEvidence) throws {
        guard (settings.state == .notRunning || settings.alerts.count == 0),
              XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0 else {
            throw AppearanceReadError.exactTargetUnavailable
        }
        if settingsRootIdentified(in: settings) { return }
        let displayBars = knownAppearanceElements(in: settings, type: .navigationBar,
                                                 titles: ["Display & Brightness", "显示与亮度"])
        if settings.state != .runningForeground || displayBars.count != 1 || !displayBars.firstMatch.isHittable {
            evidence.report.appearanceNavigationViaDisplayPage = true
            settings.open(URL(string: "prefs:root=DISPLAY")!)
            let found = waitForAppearanceCondition(seconds: 5) {
                settings.state == .runningForeground && displayBars.count == 1 && displayBars.firstMatch.isHittable
            }
            recordAppearanceTarget(in: settings, phase: "observedDisplayTransitToSettingsRoot", evidence: evidence)
            guard found else { throw AppearanceReadError.exactTargetUnavailable }
        }
        let back = displayBars.firstMatch.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
            ["Settings", "设置"], ["Settings", "设置"]))
        guard settings.alerts.count == 0, XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0,
              back.count == 1, back.firstMatch.isEnabled, back.firstMatch.isHittable else {
            throw AppearanceReadError.exactTargetUnavailable
        }
        evidence.report.appearanceNavigationBackTaps += 1
        back.firstMatch.tap()
        guard waitForAppearanceCondition(seconds: 5, { settingsRootIdentified(in: settings) }) else {
            recordAppearanceTarget(in: settings, phase: "observedSettingsBackUnavailable", evidence: evidence)
            throw AppearanceReadError.exactTargetUnavailable
        }
    }

    @MainActor
    private func readAppearance(in settings: XCUIApplication, wait: Bool) throws -> AppearanceSelection {
        var selection: AppearanceSelection?
        let found = waitForAppearanceCondition(seconds: wait ? 5 : 0) {
            guard settings.state == .runningForeground, appearancePageIdentified(in: settings) else { return false }
            let light = knownAppearanceElements(in: settings, type: .button, titles: ["Light", "浅色"])
            let dark = knownAppearanceElements(in: settings, type: .button, titles: ["Dark", "深色"])
            guard light.count == 1, dark.count == 1, light.firstMatch.isHittable, dark.firstMatch.isHittable else { return false }
            @MainActor func selected(_ element: XCUIElement) -> Bool {
                element.isSelected || ["1", "Selected", "已选择", "已选中"].contains(element.value as? String ?? "")
            }
            let result = AppearanceSelection(lightSelected: selected(light.firstMatch), darkSelected: selected(dark.firstMatch))
            guard result.lightSelected != result.darkSelected else { return false }
            selection = result
            return true
        }
        guard found, let selection else { throw AppearanceReadError.exactTargetUnavailable }
        return selection
    }

    @MainActor
    private func recordAppearanceTarget(in settings: XCUIApplication, phase: String, evidence: AppearanceEvidence) {
        guard evidence.report.targetDiagnostics.count < 12 else { return }
        func count(_ type: XCUIElement.ElementType, _ titles: [String]) -> Int {
            min(20, knownAppearanceElements(in: settings, type: type, titles: titles).count)
        }
        func choice(_ titles: [String]) -> AppearanceChoiceDiagnostic {
            let buttons = knownAppearanceElements(in: settings, type: .button, titles: titles)
            let unique = buttons.count == 1
            let value = unique ? buttons.firstMatch.value as? String : nil
            let knownValue = value.map { ["0", "1", "Selected", "已选择", "已选中"].contains($0) } ?? false
            return .init(buttons: min(20, buttons.count), cells: count(.cell, titles), otherElements: count(.other, titles),
                         staticTexts: count(.staticText, titles), buttonHittable: unique ? buttons.firstMatch.isHittable : nil,
                         buttonSelected: unique ? buttons.firstMatch.isSelected : nil,
                         selectedValue: knownValue ? ["1", "Selected", "已选择", "已选中"].contains(value!) : nil)
        }
        evidence.report.targetDiagnostics.append(.init(phase: phase, settingsForeground: settings.state == .runningForeground,
            settingsNavigationBars: count(.navigationBar, ["Settings", "设置"]),
            expectedPage: appearancePageName,
            expectedNavigationBars: count(.navigationBar, appearancePageTitles),
            expectedTitleTexts: count(.staticText, appearancePageTitles),
            displayNavigationBars: count(.navigationBar, ["Display & Brightness", "显示与亮度"]),
            displayTitleTexts: count(.staticText, ["Display & Brightness", "显示与亮度"]),
            light: choice(["Light", "浅色"]), dark: choice(["Dark", "深色"])))
    }

    private struct AppearanceChoiceDiagnostic: Encodable {
        let buttons: Int
        let cells: Int
        let otherElements: Int
        let staticTexts: Int
        let buttonHittable: Bool?
        let buttonSelected: Bool?
        let selectedValue: Bool?
    }
    private struct AppearanceTargetDiagnostic: Encodable {
        let phase: String
        let settingsForeground: Bool
        let settingsNavigationBars: Int
        let expectedPage: String
        let expectedNavigationBars: Int
        let expectedTitleTexts: Int
        // Retained for reading the earlier Display-page failure evidence.
        let displayNavigationBars: Int
        let displayTitleTexts: Int
        let light: AppearanceChoiceDiagnostic
        let dark: AppearanceChoiceDiagnostic
    }
    private struct AppearanceElementFrame: Encodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
    private struct AppearanceElementDiagnostic: Encodable {
        let type: String
        let typeRawValue: Int
        let label: String?
        let identifier: String?
        let labelOmittedForLength: Bool
        let identifierOmittedForLength: Bool
        let selected: Bool
        let selectedValue: Bool?
        let hittable: Bool
        let frame: AppearanceElementFrame?
    }
    private struct AppearanceRootRowDiagnostic: Encodable {
        let scrollStep: Int
        let type: String
        let typeRawValue: Int
        let label: String
        let identifier: String?
        let identifierOmittedForLength: Bool
        let frame: AppearanceElementFrame
    }

    @MainActor
    private final class AppearanceEvidence {
        weak var testCase: RealModelCalculatorAcceptanceUITests?
        var report: AppearanceReport
        private var attached = false
        init(testCase: RealModelCalculatorAcceptanceUITests, helper: String) {
            self.testCase = testCase; report = AppearanceReport(helper: helper)
            report.expectedAppearancePage = testCase.appearancePageName
        }
        func finish() {
            guard !attached else { return }; attached = true
            report.finishedAt = Date().timeIntervalSince1970
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) else { return }
            let attachment = XCTAttachment(string: json)
            attachment.name = "Read-only appearance — target booleans and host metadata only"
            attachment.lifetime = .keepAlways; testCase?.add(attachment)
        }
    }

    private struct AppearanceReport: Encodable {
        let helper: String
        let manualAppearanceReportReviewRequired = true
        let manualOtherSettingsUnchangedReviewRequired = true
        var explicitScreenshotsCaptured = 0
        let messageBodiesExported = false
        let samplingDoesNotProveAbsenceOfTransientChanges = true
        let startedAt = Date().timeIntervalSince1970
        var before: AppearanceSelection?
        var after: AppearanceSelection?
        var targetDiagnostics: [AppearanceTargetDiagnostic] = []
        var appearanceElementInspectionPageVerified = false
        var appearanceElementMatchCount: Int?
        var appearanceElementListTruncated = false
        var appearanceElements: [AppearanceElementDiagnostic] = []
        var rootInspectionNavigation: String?
        var rootInspectionBackTaps = 0
        var rootInspectionURLRequests = 0
        var rootInspectionPageVerified = false
        var rootInspectionMatchCounts: [Int] = []
        var rootInspectionScrollDirections: [String] = []
        var rootAppearanceRows: [AppearanceRootRowDiagnostic] = []
        var expectedAppearancePage: String?
        var appearanceRootEntryIdentifier: String?
        var appearanceNavigationViaDisplayPage = false
        var appearanceNavigationBackTaps = 0
        var appearanceNavigationRootScrolls = 0
        var settingsRootBeforeSend = false
        var navigationCoverage = "preparedTargetOnlyNoHierarchyTraversalClaim"
        var settingsForegroundObserved = false
        var appearancePageObservedDuringRun = false
        // Legacy field applies only when iOS 26's Display page was observed.
        var displayBrightnessObservedDuringRun = false
        var autonomousReturnObserved = false
        var appearanceChecks = 0
        var appearanceChangedAtCheck = false
        var appearanceUnchangedAtChecks = false
        var reportedAppearanceMatchesObservation: Bool? = nil
        var successfulInputs = 0
        var observations = 0
        var sendAttempts = 0
        var waitLimitSeconds: Int?
        var acceptanceID: UUID?
        var conversationID: UUID?
        var runID: UUID?
        var requestID: UUID?
        var sentAt: TimeInterval?
        var finishedAt: TimeInterval?
        var hostFlowCompleted = false
        var result = "notCompleted"
        var lastSnapshot: Snapshot?
    }

    private struct Snapshot: Codable {
        let version: Int
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

    private struct Run: Codable {
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
    }

    private struct Activity: Codable {
        let id: String
        let name: String?
        let startedAt: TimeInterval
        let endedAt: TimeInterval?
        let isError: Bool
    }

    private struct Event: Codable {
        let kind: String
        let date: TimeInterval
        let tool: String?
    }

    @MainActor
    private final class RecoveryEvidence {
        weak var testCase: RealModelCalculatorAcceptanceUITests?
        var report = RecoveryReport()
        private var attached = false
        init(testCase: RealModelCalculatorAcceptanceUITests) { self.testCase = testCase }
        func finish() {
            guard !attached else { return }; attached = true
            report.finishedAt = Date().timeIntervalSince1970
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) else { return }
            let attachment = XCTAttachment(string: json)
            attachment.name = "Exact paused-run recovery — local disconnect evidence only"
            attachment.lifetime = .keepAlways; testCase?.add(attachment)
        }
    }

    private struct RecoveryReport: Encodable {
        let helper = "exactPausedRunRecovery"
        let modelRequestsStarted = 0
        let nativeReleaseConfirmation = "notExposedByThisHelper"
        let startedAt = Date().timeIntervalSince1970
        var expectedRunID: UUID?
        var endAttempts = 0
        var disconnectAttempts = 0
        var pausedRunEnded = false
        var locallyDisconnected = false
        var result = "notCompleted"
        var finishedAt: TimeInterval?
        var lastSnapshot: Snapshot?
    }

    @MainActor
    private final class Evidence {
        weak var testCase: RealModelCalculatorAcceptanceUITests?
        var report = Report()
        private var attached = false
        var frames: [(date: TimeInterval, screenshot: XCUIScreenshot)] = []
        var returnedAppScreenshot: XCUIScreenshot?

        init(testCase: RealModelCalculatorAcceptanceUITests) { self.testCase = testCase }

        func finish() {
            guard !attached else { return }; attached = true
            report.finishedAt = Date().timeIntervalSince1970
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) {
                let attachment = XCTAttachment(string: json)
                attachment.name = "Real-model host flow — Calculator screenshot review required"
                attachment.lifetime = .keepAlways; testCase?.add(attachment)
            }
            for (index, frame) in frames.enumerated() {
                let attachment = XCTAttachment(screenshot: frame.screenshot)
                attachment.name = "Real-model Calculator frame \(index + 1) — \(frame.date) — review result"
                attachment.lifetime = .keepAlways; testCase?.add(attachment)
            }
            if let returnedAppScreenshot {
                let attachment = XCTAttachment(screenshot: returnedAppScreenshot)
                attachment.name = "New real-model conversation — returned and settled"
                attachment.lifetime = .keepAlways; testCase?.add(attachment)
            }
        }
    }

    private struct Report: Encodable {
        let helper = "realModelCalculatorHostFlow"
        let manualCalculatorReviewRequired = true
        let expectedCalculatorResult = "391"
        let startedAt = Date().timeIntervalSince1970
        var acceptanceID: UUID?
        var sentAt: TimeInterval?
        var finishedAt: TimeInterval?
        var sendAttempts = 0
        var conversationID: UUID?
        var runID: UUID?
        var requestID: UUID?
        var calculatorForegroundObserved = false
        var leftEiscueForegroundObserved = false
        var returnedToEiscueObserved = false
        var hostFlowCompleted = false
        var result = "notCompleted"
        var lastSnapshot: Snapshot?
    }
}
