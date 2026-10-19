import XCTest

/// Uses the installed App without relaunching or resetting its real state.
/// Local disconnection is not proof of remote media release; device screenshot
/// and input acceptance run separately in the standalone Owned check.
final class NetworkAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Network acceptance preparation requires a physical iPhone.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_REAL_NETWORK_TEST"] == "1" else {
            throw XCTSkip("Run explicitly with TEST_RUNNER_EISCUE_REAL_NETWORK_TEST=1.")
        }
        guard ["coreDevice", "xcTest"].contains(environment["EISCUE_NETWORK_BACKEND"] ?? "") else {
            throw XCTSkip("Set TEST_RUNNER_EISCUE_NETWORK_BACKEND to coreDevice or xcTest.")
        }
        #endif
    }

    /// One native XCUI gesture on the same visible Owned scroll target used by
    /// the App diagnostic. A failed gesture is never repeated by this helper.
    @MainActor
    func testSwipeKnownOwnedTarget() throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        var inputAttempts = 0
        var metadata = "helper=swipeKnownOwnedTarget\ncoordinateUnits=points\nstartedAt=\(Date().timeIntervalSince1970)"
        func attachMetadata(_ phase: String) {
            let attachment = XCTAttachment(string: metadata + "\ninputAttempts=\(inputAttempts)")
            attachment.name = "Owned native swipe metadata — \(phase)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { attachMetadata("blocked or failed") }
            try require(condition, message)
        }
        let holdArgument = ProcessInfo.processInfo.environment["EISCUE_SWIPE_HOLD_SECONDS"]
        let parsedHold = holdArgument.flatMap(Double.init)
        try check(holdArgument == nil || parsedHold != nil, "EISCUE_SWIPE_HOLD_SECONDS must be a number from 0 to 0.5.")
        let holdSeconds = parsedHold ?? 0
        try check(holdSeconds.isFinite && (0...0.5).contains(holdSeconds),
                  "EISCUE_SWIPE_HOLD_SECONDS must be finite and from 0 to 0.5.")
        metadata += "\ninitialHoldSeconds=\(holdSeconds)"
        try check(app.state == .runningForeground && app.staticTexts["Input check"].exists
                    && app.buttons["Tap to count"].exists,
                    "Open the foreground Eiscue Owned target first; this helper never launches or navigates.")
        try check(app.alerts.count == 0 && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0,
                    "Resolve existing dialogs separately; this helper handles no authorization.")
        try check(app.scrollViews.count == 1, "The Owned target must have exactly one native ScrollView.")
        let scroll = app.scrollViews.firstMatch
        let row = scroll.staticTexts["Verification row 1"]
        try check(row.exists, "The known first verification row is unavailable; no reset is performed.")
        let scrollBefore = scroll.frame, rowBefore = row.frame, appFrame = app.frame
        let startPoint = CGPoint(x: scrollBefore.midX, y: scrollBefore.maxY - 30)
        let endPoint = CGPoint(x: scrollBefore.midX, y: scrollBefore.minY + 30)
        let distance = startPoint.y - endPoint.y
        try check(scrollBefore.width > 0 && distance > 0 && rowBefore.height > 0
                    && [startPoint.x, startPoint.y, endPoint.x, endPoint.y, rowBefore.minY].allSatisfy(\.isFinite)
                    && appFrame.contains(startPoint) && appFrame.contains(endPoint),
                    "The observed Owned swipe geometry is invalid.")
        metadata += "\nscrollFrameBefore=\(scrollBefore)\nrow1FrameBefore=\(rowBefore)\nstart=\(startPoint)\nend=\(endPoint)\ndistancePoints=\(distance)\nplannedSeconds=0.5\nvelocityPointsPerSecond=\(distance / 0.5)"
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Owned native swipe — before"
        before.lifetime = .keepAlways
        add(before)
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = origin.withOffset(CGVector(dx: startPoint.x - appFrame.minX, dy: startPoint.y - appFrame.minY))
        let end = origin.withOffset(CGVector(dx: endPoint.x - appFrame.minX, dy: endPoint.y - appFrame.minY))
        try check(app.state == .runningForeground && app.staticTexts["Input check"].exists
                    && app.buttons["Tap to count"].exists && app.alerts.count == 0,
                    "The known foreground target changed before the single swipe.")
        inputAttempts = 1
        metadata += "\ngestureRequestedAt=\(Date().timeIntervalSince1970)"
        attachMetadata("before single gesture")
        start.press(forDuration: holdSeconds, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: distance / 0.5), thenHoldForDuration: 0.02)
        metadata += "\ngestureReturnedAt=\(Date().timeIntervalSince1970)"
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row.exists && row.frame.minY < rowBefore.minY - 30
        }, object: nil)
        let result = XCTWaiter.wait(for: [moved], timeout: 2)
        metadata += "\nrow1FrameAfter=\(row.frame)\nscrollFrameAfter=\(scroll.frame)\nrow1MovedUpOver30Points=\(result == .completed)\nfinishedAt=\(Date().timeIntervalSince1970)"
        try check(app.state == .runningForeground && app.staticTexts["Input check"].exists
                    && app.buttons["Tap to count"].exists,
                    "The Owned target is unavailable for its after screenshot.")
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Owned native swipe — after"
        after.lifetime = .keepAlways
        add(after)
        attachMetadata("after single gesture")
        try check(result == .completed, "The first row did not move up by more than 30 points within 2 seconds; no retry was sent.")
    }

    /// Authorizes only the observed dtpasteboard/dtpasteboardd system paste
    /// sources on the App's Owned target. Owned JSON verifies the actual text.
    @MainActor
    func testAllowKnownOwnedCheckPaste() throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        var metadata = "helper=allowKnownOwnedCheckPaste\ntextValidation=notPerformed\ntextValidationAuthority=OwnedDeviceCheckJSON\nstartedAt=\(Date().timeIntervalSince1970)"
        var attached = false
        func attachMetadata() {
            guard !attached else { return }
            attached = true
            let attachment = XCTAttachment(string: metadata)
            attachment.name = "Owned paste authorization metadata — text not verified"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        defer { attachMetadata() }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { attachMetadata() }
            try require(condition, message)
        }
        try check(app.state == .runningForeground,
                    "The installed Eiscue App must already be foreground; this helper never launches or activates it.")
        try check(app.staticTexts["Input check"].exists && app.buttons["Tap to count"].exists,
                    "Only the foreground Eiscue Owned input target may receive this paste authorization.")
        metadata += "\nappForegroundVerified=true\nownedTargetVerified=true"

        func normalize(_ title: String) -> String {
            let formatting = ["“", "”", "\"", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200E}", "\u{200F}"]
            return formatting.reduce(title) { $0.replacingOccurrences(of: $1, with: "") }
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").lowercased()
        }
        let knownSources = ["dtpasteboard", "dtpasteboardd"]
        func knownPasteAlert(in application: XCUIApplication) -> (element: XCUIElement, source: String)? {
            let alerts = application.alerts
            guard alerts.count == 1 else { return nil }
            let alert = alerts.firstMatch
            let labels = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label)).map(normalize)
            let source = knownSources.first { source in
                let title = "eiscue would like to paste from " + source
                let acceptedTitles: Set<String> = [title, title + ".", title + " do you want to allow this?",
                                                   title + ". do you want to allow this?"]
                return labels.contains(where: acceptedTitles.contains)
            }
            guard let source else { return nil }
            let allow = alert.buttons["Allow Paste"]
            guard allow.exists && allow.label == "Allow Paste" else { return nil }
            return (alert, source)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        metadata += "\nknownPasteWaitStartedAt=\(Date().timeIntervalSince1970)\nknownPasteWaitLimitSeconds=30"
        var pending = knownPasteAlert(in: app) ?? knownPasteAlert(in: springboard)
        while pending == nil, ContinuousClock.now < deadline {
            try check(app.state == .runningForeground,
                        "Eiscue must remain foreground while waiting for its known paste permission.")
            Thread.sleep(forTimeInterval: 0.25)
            pending = knownPasteAlert(in: app) ?? knownPasteAlert(in: springboard)
        }
        if pending == nil { attachMetadata() }
        let match = try XCTUnwrap(pending,
                                 "Only Eiscue's system paste request from dtpasteboard or dtpasteboardd is authorized.")
        metadata += "\nknownPasteSource=\(match.source)"
        let alert = match.element
        let allow = alert.buttons["Allow Paste"]
        try check(app.state == .runningForeground && app.staticTexts["Input check"].exists
                    && app.buttons["Tap to count"].exists && allow.isEnabled && allow.isHittable,
                    "The known Owned target and its exact paste permission must still be available.")
        metadata += "\nknownPasteSourceVerified=true\nallowPasteTappedAt=\(Date().timeIntervalSince1970)"
        allow.tap()
        metadata += "\nallowPasteTapped=true"
        try check(alert.waitForNonExistence(timeout: 5), "The known paste authorization dialog did not close.")
        metadata += "\ndialogDismissed=true\nfinishedAt=\(Date().timeIntervalSince1970)"
    }

    @MainActor
    func testRequestSelectedLocalVPNConnection() throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        try require(app.state != .notRunning, "Open Eiscue first; this test never launches it.")
        app.activate()
        openDevice(in: app)
        try requireIdleControls(in: app)
        let backend = try XCTUnwrap(ProcessInfo.processInfo.environment["EISCUE_NETWORK_BACKEND"])
        try require(["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? ""),
                    "Prepare the local-VPN route first.")
        try require(app.buttons["deviceControlBackendPicker"].value as? String == (backend == "coreDevice" ? "DisplayService" : "XCTest"),
                    "Prepare the explicit backend first.")
        let connect = app.buttons["connectDeviceButton"]
        try require(connect.isHittable && connect.isEnabled, "The connection cannot be started normally.")
        connect.tap()
        // This proves only that the normal connection request was initiated.
        // Permissions remain for the user; independent diagnostics verify readiness.
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Connection requested — authorization and readiness not verified"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testPreviewSelectedLocalVPNConnection() throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let backend = ProcessInfo.processInfo.environment["EISCUE_NETWORK_BACKEND"] ?? ""
        let backendTitle = backend == "coreDevice" ? "DisplayService" : "XCTest"
        var metadata = "startedAt=\(Date().timeIntervalSince1970)\npreviewRequested=false\nimageAttached=false\nconnectionChangeRequested=false"
        func attach(_ phase: String) {
            let attachment = XCTAttachment(string: metadata)
            attachment.name = "Selected network preview UI — \(phase)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        defer { attach("finished") }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { metadata += "\ncheckFailed=true"; attach("blocked or failed") }
            try require(condition, message)
        }
        try check(app.state == .runningForeground && app.alerts.count == 0
                  && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0,
                  "Open the normal App in the foreground first; this helper never launches or handles authorization.")
        try check(!app.buttons["stopRunButton"].exists && !app.buttons["cancelDictationButton"].exists
                  && !app.staticTexts["speechDeviceRestorationStatus"].exists,
                  "Finish the current task, recording and restoration before previewing.")
        openDevice(in: app)
        try requireIdleControls(in: app)
        let method = app.buttons["deviceConnectionMethodPicker"]
        let backendPicker = app.buttons["deviceControlBackendPicker"]
        let status = app.staticTexts["devicePairingComplete"]
        let ready = NSPredicate(format: "exists == true AND label IN %@", ["Ready to control", "设备操作已就绪"])
        try check(["In app", "App 内连接"].contains(method.value as? String ?? "")
                  && backendPicker.value as? String == backendTitle && backendPicker.isEnabled,
                  "The already selected local-VPN route must use the requested backend.")
        try check(ready.evaluate(with: status) && app.buttons["disconnectDeviceButton"].exists
                  && app.buttons["disconnectDeviceButton"].isEnabled,
                  "The existing control connection must already be ready; this helper never connects it.")
        metadata += "\nlocalVPNVerified=true\nbackendMatched=true\ninitiallyReady=true"
        let preview = app.buttons["deviceScreenPreviewButton"]
        for _ in 0..<5 {
            if preview.exists && preview.isHittable { break }
            app.swipeUp()
        }
        if !preview.exists {
            // Read the normal preference only to distinguish an intentionally
            // hidden Debug entry. Never enable it on behalf of this helper.
            openSettings(in: app)
            let debugTools = app.switches["debugToolsToggle"]
            for _ in 0..<5 {
                if debugTools.exists && debugTools.isHittable { break }
                app.swipeUp()
            }
            if debugTools.exists && debugTools.value as? String == "0" {
                metadata += "\ndebugToolsDisabled=true\nskipped=true"
                throw XCTSkip("The App's Debug tools are disabled; enable them separately before requesting a screen preview.")
            }
            try check(false, "The Debug preview entry is unavailable; no preference was changed.")
        }
        try check(app.state == .runningForeground && ready.evaluate(with: status)
                  && preview.exists && preview.isEnabled && preview.isHittable && app.alerts.count == 0,
                  "The ready connection and its normal preview control must still be available.")
        metadata += "\npreviewRequested=true\npreviewRequestedAt=\(Date().timeIntervalSince1970)"
        attach("before single preview request")
        preview.tap()
        let image = app.descendants(matching: .any).matching(identifier: "deviceScreenPreviewImage").firstMatch
        let close = app.buttons["closeDeviceScreenPreviewButton"]
        let imageAppeared = image.waitForExistence(timeout: 15)
        let canClose = close.waitForExistence(timeout: 5) && close.isEnabled && close.isHittable
        metadata += "\nimageAppeared=\(imageAppeared)\ncloseAvailable=\(canClose)\npreviewObservedAt=\(Date().timeIntervalSince1970)"
        if canClose {
            close.tap()
            let dismissed = close.waitForNonExistence(timeout: 5)
            metadata += "\npreviewDismissed=\(dismissed)\npreviewClosedAt=\(Date().timeIntervalSince1970)"
            try check(dismissed, "The normal preview dismissal did not finish.")
        }
        try check(imageAppeared && canClose, "A decoded preview image and normal close action did not both appear.")
        try waitFor(ready, on: status, message: "The existing control connection did not remain ready after closing its preview.")
        try requireIdleControls(in: app)
        try check(method.value as? String == "In app" || method.value as? String == "App 内连接",
                  "The selected route changed during the preview.")
        try check(backendPicker.value as? String == backendTitle && backendPicker.isEnabled,
                  "The selected backend changed or remained busy after preview dismissal.")
        metadata += "\nreadyRetained=true\nrouteAndBackendUnchanged=true\nuiChecksPassed=true\nfinishedAt=\(Date().timeIntervalSince1970)"
    }

    @MainActor
    func testPrepareLocalVPNBackend() throws {
        let backend = try XCTUnwrap(ProcessInfo.processInfo.environment["EISCUE_NETWORK_BACKEND"])
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        try require(app.state != .notRunning, "Open the installed Eiscue App first; this test never launches it.")
        app.activate()
        try require(app.state == .runningForeground, "Eiscue must already be available in the foreground.")
        try require(!app.buttons["stopRunButton"].exists && !app.buttons["cancelDictationButton"].exists
                    && !app.staticTexts["speechDeviceRestorationStatus"].exists,
                    "Finish the current task or dictation before preparing acceptance.")
        try require(app.alerts.count == 0, "Leave existing dialogs and system permissions to the user.")

        openDevice(in: app)
        try requireIdleControls(in: app)
        let networkDisconnect = app.buttons["disconnectDeviceButton"]
        let bluetoothDisconnect = app.buttons["bluetoothDisconnectButton"]
        if networkDisconnect.exists || bluetoothDisconnect.exists {
            let disconnect = networkDisconnect.exists ? networkDisconnect : bluetoothDisconnect
            try require(disconnect.isHittable && disconnect.isEnabled, "The existing connection cannot be disconnected normally.")
            disconnect.tap()
            try require(disconnect.waitForNonExistence(timeout: 15), "Local disconnection did not finish; do not force termination.")
            try requireIdleControls(in: app)
        }

        let methodPicker = app.buttons["deviceConnectionMethodPicker"]
        methodPicker.tap()
        let localVPN = app.buttons["deviceConnectionChoice_localVPN"]
        try require(localVPN.waitForExistence(timeout: 5) && localVPN.isEnabled && localVPN.isHittable,
                    "The local-VPN route is unavailable; leave the current session untouched.")
        localVPN.tap()
        try require(localVPN.waitForNonExistence(timeout: 5), "The route selection did not close.")
        try waitFor(NSPredicate(format: "value IN %@", ["In app", "App 内连接"]), on: methodPicker,
                    message: "The local-VPN preference was not selected.")

        let backendPicker = app.buttons["deviceControlBackendPicker"]
        try waitFor(NSPredicate(format: "exists == true AND enabled == true"), on: backendPicker,
                    message: "A task, recovery or connection transition prevents backend selection.")
        backendPicker.tap()
        let choice = app.buttons["deviceControlBackendChoice_\(backend)"]
        try require(choice.waitForExistence(timeout: 5) && choice.isEnabled && choice.isHittable,
                    "The requested backend is unavailable on this device.")
        // Choose even the effective default so a legacy automatic preference
        // becomes an explicit backend without starting a connection.
        choice.tap()
        try require(choice.waitForNonExistence(timeout: 5), "The backend selection did not close.")
        try waitFor(NSPredicate(format: "value == %@", backend == "coreDevice" ? "DisplayService" : "XCTest"),
                    on: backendPicker, message: "The requested backend preference was not selected.")
        try requireIdleControls(in: app)

        let status = app.staticTexts["devicePairingComplete"]
        try waitFor(NSPredicate(format: "exists == true AND label IN %@", ["Not connected", "未连接"]),
                    on: status, message: "An existing identity and locally disconnected state are required; no pairing is performed.")
        try require(!networkDisconnect.exists && !bluetoothDisconnect.exists,
                    "A connection is still active; do not launch the independent Owned check.")
        let connect = app.buttons["connectDeviceButton"]
        try require(connect.exists && connect.isEnabled, "The App is not ready for a later explicit connection.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Network preparation — localVPN — \(backend) — local disconnect only"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Exercises the real DictationSession, not the isolated speech fixture.
    /// The external XCTest runner may itself affect microphone availability;
    /// this does not establish microphone coexistence without that runner.
    /// UI quiescence can wait until recording ends, so use one bounded gesture.
    /// Verify nonzero audio separately against this run's App diagnostic times.
    @MainActor
    func testVoiceCaptureRestoresSelectedNetworkRoute() throws {
        guard ProcessInfo.processInfo.environment["EISCUE_REAL_SPEECH_TEST"] == "1" else {
            throw XCTSkip("Also opt in with TEST_RUNNER_EISCUE_REAL_SPEECH_TEST=1 for real microphone capture.")
        }
        let requestedCase = ProcessInfo.processInfo.environment["EISCUE_VOICE_CASE"] ?? "holdCancel"
        if requestedCase != "holdCancel" {
            let voiceCase = try XCTUnwrap(VoiceAcceptanceCase(rawValue: requestedCase), "Unknown real voice acceptance case.")
            try runVoiceAcceptanceCase(voiceCase)
            return
        }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let backend = ProcessInfo.processInfo.environment["EISCUE_NETWORK_BACKEND"] ?? ""
        let backendTitle = backend == "coreDevice" ? "DisplayService" : "XCTest"
        let ready = NSPredicate(format: "exists == true AND label IN %@", ["Ready to control", "设备操作已就绪"])
        let cleanup = VoiceCleanup(testCase: self, app: app, backendTitle: backendTitle,
                                   metadata: "backend=\(backend)\naudioSignal=notVerifiedByUITest\nappDiagnostic=SpeechCaptureDiagnostic.json")
        // XCTest also runs teardown after driver/assertion failures that bypass
        // Swift catch/defer. Only the idle connection accepted below is ours.
        addTeardownBlock { await cleanup.finish() }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw VoiceCheckFailure.unmet(message) }
        }
        func wait(_ predicate: NSPredicate, _ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
        }
        do {
            try check(app.state != .notRunning, "Open the connected App first; this test never launches it.")
            app.activate()
            try check(app.state == .runningForeground && app.alerts.count == 0,
                      "The foreground App must have no pending authorization dialog.")
            try check(!app.buttons["stopRunButton"].exists && !app.buttons["cancelDictationButton"].exists
                      && !app.staticTexts["speechDeviceRestorationStatus"].exists, "Finish the current task or dictation first.")
            openDevice(in: app)
            try check(app.switches["deviceControlToggle"].isEnabled, "A task or recovery still owns the device.")
            try check(["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                      && app.buttons["deviceControlBackendPicker"].value as? String == backendTitle,
                      "Connect the prepared local-VPN route and explicit backend first.")
            try check(ready.evaluate(with: app.staticTexts["devicePairingComplete"])
                      && app.buttons["disconnectDeviceButton"].isEnabled, "The selected network connection must already be ready.")
            cleanup.ownsCleanup = true
            returnToAssistant(in: app)
            let editor = app.descendants(matching: .any).matching(identifier: "messageInput").firstMatch
            try check(editor.waitForExistence(timeout: 5), "Start from the normal keyboard composer.")
            let originalDraft = editor.value as? String
            try check(originalDraft != nil, "The original draft cannot be inspected without changing it.")
            let deviceLink = app.buttons["deviceNavigationLink"]
            let connectedBadge = deviceLink.value as? String
            try check(connectedBadge != nil, "The current connection badge is unavailable.")
            app.buttons["speechInputButton"].tap()
            let record = app.buttons["holdToTalkButton"]
            try check(record.waitForExistence(timeout: 5) && record.isEnabled && record.isHittable,
                      "The normal recording control is unavailable.")
            try check(deviceLink.value as? String == connectedBadge, "Selecting voice mode changed the connection before recording.")
            try check((record.value as? String ?? "").hasPrefix("state="),
                      "The running DEBUG App needs --speech-diagnostics for later audio verification; no relaunch is performed.")
            let recordFrame = record.frame
            let cancelDistance = max(CGFloat(96), recordFrame.height * 2)
            try check(recordFrame.width > 0 && recordFrame.height > 0
                      && recordFrame.midY - cancelDistance > app.frame.minY,
                      "The observed recording control has no safe upward cancellation path.")
            let start = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: 0, dy: -cancelDistance))
            cleanup.metadata += "\nholdSeconds=5\ncancelDragPoints=\(cancelDistance)\ngestureBeganAt=\(Date().timeIntervalSince1970)"
            cleanup.mayOwnRecording = true
            // Do not inspect UI during capture: a query may wait for the full
            // 55-second recording limit. The upward drag requests cancellation.
            start.press(forDuration: 5, thenDragTo: end)
            cleanup.metadata += "\ngestureFinishedAt=\(Date().timeIntervalSince1970)\ncancelGestureCompleted=true"
            let cancel = app.buttons["cancelDictationButton"]
            try check(cancel.waitForNonExistence(timeout: 15), "Recording did not finish cancelling.")
            cleanup.metadata += "\ncancelControlAbsent=true"
            try check(wait(NSPredicate(format: "exists == true AND enabled == true"), app.buttons["speechInputButton"], timeout: 30)
                      && !app.staticTexts["speechDeviceRestorationStatus"].exists, "Connection restoration did not finish.")
            if record.exists {
                app.buttons["speechInputButton"].tap()
                try check(record.waitForNonExistence(timeout: 5), "Could not return to the keyboard after cancellation.")
            }
            try check(editor.waitForExistence(timeout: 5) && editor.value as? String == originalDraft,
                      "Cancellation changed the original draft.")
            openDevice(in: app)
            try check(wait(ready, app.staticTexts["devicePairingComplete"])
                      && ["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                      && app.buttons["deviceControlBackendPicker"].value as? String == backendTitle,
                      "The original network route and backend did not return to ready.")
            cleanup.metadata += "\nrestoredReady=true\ndraftUnchanged=true"
            let disconnect = app.buttons["disconnectDeviceButton"]
            try check(disconnect.isHittable && disconnect.isEnabled, "The restored connection cannot be disconnected normally.")
            disconnect.tap()
            try check(disconnect.waitForNonExistence(timeout: 15)
                      && wait(NSPredicate(format: "exists == true AND label IN %@", ["Not connected", "未连接"]), app.staticTexts["devicePairingComplete"]),
                      "Local disconnection did not finish.")
            cleanup.ownsCleanup = false
            cleanup.metadata += "\nlocallyDisconnected=true\ncleanupOutcome=locallyDisconnected\ncleanupIncomplete=false"
        } catch {
            cleanup.metadata += "\ncheckFailed=true"
            XCTFail("Real voice handoff check failed: \(error)")
        }
    }

    /// An external operator observes this capture's App metadata and backgrounds
    /// Eiscue independently of XCTest's possibly blocking tap. This helper never
    /// launches, activates, backgrounds, cancels or disconnects the App itself.
    @MainActor
    func testRequestVoiceCaptureForExternalBackground() throws {
        guard ProcessInfo.processInfo.environment["EISCUE_REAL_SPEECH_TEST"] == "1" else {
            throw XCTSkip("Also opt in with TEST_RUNNER_EISCUE_REAL_SPEECH_TEST=1 for real microphone capture.")
        }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let backend = ProcessInfo.processInfo.environment["EISCUE_NETWORK_BACKEND"] ?? ""
        let backendTitle = backend == "coreDevice" ? "DisplayService" : "XCTest"
        var metadata = "helper=requestVoiceCaptureForExternalBackground\nbackend=\(backend)\nvoiceCase=externalBackground\nstartedAt=\(Date().timeIntervalSince1970)\naudioSignal=notVerifiedByUITest\ncaseValidation=pendingAppDiagnostic\nappDiagnostic=SpeechCaptureDiagnostic.json\nbackgroundActionAuthority=externalOperator\ncleanupAttempted=false\ndraftTextLogged=false"
        func attach(_ phase: String) {
            let attachment = XCTAttachment(string: metadata)
            attachment.name = "External-background voice request — \(phase) — \(backendTitle)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        defer { attach("finished") }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { metadata += "\ncheckFailed=true"; attach("blocked or failed") }
            try require(condition, message)
        }
        try check(app.state == .runningForeground,
                  "Open the connected App in the foreground first; this helper never launches or activates it.")
        try check(app.alerts.count == 0
                  && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0,
                  "Resolve existing dialogs separately; this helper handles no authorization.")
        try check(!app.buttons["stopRunButton"].exists && !app.buttons["cancelDictationButton"].exists
                  && !app.staticTexts["speechDeviceRestorationStatus"].exists,
                  "Finish the current task, recording and restoration first.")
        openDevice(in: app)
        try requireIdleControls(in: app)
        try check(["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                  && app.buttons["deviceControlBackendPicker"].value as? String == backendTitle,
                  "Prepare the local-VPN route and explicit backend first.")
        let ready = NSPredicate(format: "exists == true AND label IN %@", ["Ready to control", "设备操作已就绪"])
        try check(ready.evaluate(with: app.staticTexts["devicePairingComplete"])
                  && app.buttons["disconnectDeviceButton"].isEnabled,
                  "The selected network connection must already be ready.")
        metadata += "\noriginalRoute=localVPN\noriginalConnectionReady=true"
        returnToAssistant(in: app)
        let editor = app.descendants(matching: .any).matching(identifier: "messageInput").firstMatch
        try check(editor.waitForExistence(timeout: 5), "Start from the normal keyboard composer.")
        let badge = app.buttons["deviceNavigationLink"].value as? String
        try check(badge != nil, "The current connection badge is unavailable.")
        app.buttons["speechInputButton"].tap()
        let record = app.buttons["holdToTalkButton"]
        try check(record.waitForExistence(timeout: 5) && record.isEnabled && record.isHittable
                  && (record.value as? String ?? "").hasPrefix("state=idle "),
                  "An idle DEBUG App with --speech-diagnostics is required; no relaunch is performed.")
        try check(app.buttons["deviceNavigationLink"].value as? String == badge,
                  "Selecting voice mode changed the original connection before recording.")
        let recordFrame = record.frame
        try check(recordFrame.width > 0 && recordFrame.height > 0
                  && [recordFrame.midX, recordFrame.midY].allSatisfy(\.isFinite)
                  && app.frame.contains(recordFrame), "The recording control's observed geometry is invalid.")
        let recordPoint = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        try check(app.state == .runningForeground, "The App left the foreground before the recording request.")
        let requestedAt = Date().timeIntervalSince1970
        metadata += "\nstartToggleCaptureRequestedAt=\(requestedAt)\nrecordingRequests=1\nexpectedNonzeroPCM=true\nterminalActionAttemptedByHelper=false"
        attach("before single recording request")
        print("VOICE_EXTERNAL_BACKGROUND_REQUEST backend=\(backend) requestedAt=\(requestedAt)")
        recordPoint.tap()
        let returnedAt = Date().timeIntervalSince1970
        metadata += "\nstartToggleCaptureReturnedAt=\(returnedAt)\nstartToggleCaptureCallSeconds=\(returnedAt - requestedAt)"
        // Do not query accessibility while capture may still be active. App
        // process state is all this half observes after its single request.
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        let result = XCTWaiter.wait(for: [backgrounded], timeout: 20)
        metadata += "\nbackgroundStateObserved=\(result == .completed)\nbackgroundStateObservedAt=\(Date().timeIntervalSince1970)\nappStateAfterRequest=\(app.state.rawValue)"
        try check(result == .completed,
                  "External background entry was not observed; no terminal action or cleanup was attempted by this helper.")
        metadata += "\nrequestUICompleted=true\nactiveCaptureBackgroundHit=requiresAppDiagnosticCorrelation"
    }

    /// Run only after the external operator has foregrounded the same App.
    /// This inspects UI cleanup without reconnecting or claiming remote release.
    @MainActor
    func testVerifyVoiceExternalBackgroundCleanup() throws {
        guard ProcessInfo.processInfo.environment["EISCUE_REAL_SPEECH_TEST"] == "1" else {
            throw XCTSkip("Also opt in with TEST_RUNNER_EISCUE_REAL_SPEECH_TEST=1.")
        }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let backend = ProcessInfo.processInfo.environment["EISCUE_NETWORK_BACKEND"] ?? ""
        let backendTitle = backend == "coreDevice" ? "DisplayService" : "XCTest"
        var metadata = "helper=verifyVoiceExternalBackgroundCleanup\nbackend=\(backend)\nstartedAt=\(Date().timeIntervalSince1970)\ncaseValidation=pendingAppDiagnostic\nremoteMediaRelease=notVerifiedByUITest\ncleanupAttempted=false\ndraftTextLogged=false\npreCaptureDraftComparison=notAvailableAcrossIndependentHelpers"
        defer {
            let attachment = XCTAttachment(string: metadata)
            attachment.name = "External-background voice cleanup UI — \(backendTitle)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try require(app.state == .runningForeground,
                    "Foreground Eiscue separately first; this helper never launches or activates it.")
        try require(app.alerts.count == 0 && !app.buttons["stopRunButton"].exists,
                    "Resolve existing dialogs or task ownership separately.")
        returnToAssistant(in: app)
        try require(app.buttons["cancelDictationButton"].waitForNonExistence(timeout: 15)
                    && app.staticTexts["speechDeviceRestorationStatus"].waitForNonExistence(timeout: 30)
                    && !app.buttons["cancelSpeechDeviceRestorationButton"].exists,
                    "Recording or device restoration is still pending after the external return.")
        try waitFor(NSPredicate(format: "exists == true AND enabled == true"), on: app.buttons["speechInputButton"],
                    message: "The speech composer remains owned by recording or restoration.")
        metadata += "\nrecordingControlAbsent=true\nrestorationControlsAbsent=true\nspeechModeControlEnabled=true"
        openDevice(in: app)
        try requireIdleControls(in: app)
        try require(["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                    && app.buttons["deviceControlBackendPicker"].value as? String == backendTitle,
                    "The original local-VPN route or selected backend changed.")
        let status = app.staticTexts["devicePairingComplete"]
        let disconnected = NSPredicate(format: "exists == true AND label IN %@", ["Not connected", "未连接"])
        if backend == "coreDevice" {
            try waitFor(disconnected, on: status,
                        message: "CoreDevice unexpectedly reconnected after backgrounding the real recording.")
            // The retained local VPN also exposes a Disconnect button while
            // device control is disconnected. Its presence is not media-session
            // evidence; leave it untouched and check the control state/gate.
            try require(app.buttons["connectDeviceButton"].exists
                        && app.buttons["connectDeviceButton"].isEnabled && app.buttons["connectDeviceButton"].isHittable
                        && app.buttons["deviceConnectionMethodPicker"].isEnabled
                        && app.buttons["deviceControlBackendPicker"].isEnabled
                        && app.switches["deviceControlToggle"].isEnabled,
                        "The released CoreDevice route is not ready for a later explicit connection.")
            metadata += "\nlocallyDisconnected=true\nexplicitConnectAvailable=true\nconnectionSelectorsAndToggleEnabled=true\ndisconnectButtonMayRepresentRetainedVPN=true\ndisconnectButtonIsMediaConnectionEvidence=false\nvpnDisconnectRequested=false"
        } else {
            // XCTest has no dictation release/restore handoff. Backgrounding may
            // independently lose its transport; do not impose CoreDevice policy.
            let ready = NSPredicate(format: "exists == true AND label IN %@", ["Ready to control", "设备操作已就绪"])
            let isReady = ready.evaluate(with: status)
            let isDisconnected = disconnected.evaluate(with: status)
            try require(isReady || isDisconnected, "The XCTest route has not reached an idle connection state.")
            metadata += "\nrouteReady=\(isReady)\nlocallyDisconnected=\(isDisconnected)"
        }
        metadata += "\nrouteAndBackendUnchanged=true\nuiChecksPassed=true\nuiChecksFinishedAt=\(Date().timeIntervalSince1970)"
    }

    /// Runs the ordinary Settings repair once, without resetting pairing or
    /// reconnecting. Result rows report App UI only; repair has no diagnostic
    /// export, and this helper cannot independently verify PCM or remote release.
    @MainActor
    func testRepairSelectedLocalVPNConnection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_REAL_CONNECTION_REPAIR_TEST"] == "1",
              environment["EISCUE_REAL_SPEECH_TEST"] == "1" else {
            throw XCTSkip("Also opt in with TEST_RUNNER_EISCUE_REAL_CONNECTION_REPAIR_TEST=1 and TEST_RUNNER_EISCUE_REAL_SPEECH_TEST=1.")
        }
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let backend = environment["EISCUE_NETWORK_BACKEND"] ?? ""
        let backendTitle = backend == "coreDevice" ? "DisplayService" : "XCTest"
        var metadata = "helper=repairSelectedLocalVPNConnection\nbackend=\(backend)\noriginalRoute=localVPN\nstartedAt=\(Date().timeIntervalSince1970)\nvalidation=UIOnly\naudioSignal=notIndependentlyVerified\nremoteMediaRelease=notIndependentlyVerified\nrepairDiagnosticExportAvailable=false\nresultTextLogged=false\nrepairRequests=0"
        func attach(_ phase: String) {
            let attachment = XCTAttachment(string: metadata)
            attachment.name = "Connection repair UI metadata — \(phase) — \(backendTitle)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        defer { attach("finished") }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { metadata += "\ncheckFailed=true"; attach("blocked or failed") }
            try require(condition, message)
        }
        try check(app.state == .runningForeground && app.alerts.count == 0
                  && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0,
                  "Open the normal App in the foreground with permissions settled; this helper never launches or authorizes it.")
        try check(!app.buttons["stopRunButton"].exists && !app.buttons["cancelDictationButton"].exists
                  && !app.staticTexts["speechDeviceRestorationStatus"].exists,
                  "Finish the current task, recording and restoration before repair.")
        openDevice(in: app)
        try requireIdleControls(in: app)
        try check(["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                  && app.buttons["deviceControlBackendPicker"].value as? String == backendTitle,
                  "Only the already selected local-VPN route and requested backend may be repaired.")
        let status = app.staticTexts["devicePairingComplete"]
        let ready = NSPredicate(format: "exists == true AND label IN %@", ["Ready to control", "设备操作已就绪"])
        let disconnected = NSPredicate(format: "exists == true AND label IN %@", ["Not connected", "未连接"])
        let initiallyReady = ready.evaluate(with: status)
        let initiallyDisconnected = disconnected.evaluate(with: status)
        try check(initiallyReady || initiallyDisconnected, "The existing route must be ready or locally disconnected and idle.")
        let initialAction = app.buttons[initiallyReady ? "disconnectDeviceButton" : "connectDeviceButton"]
        try check(initialAction.exists && initialAction.isEnabled
                  && app.buttons["deviceControlBackendPicker"].isEnabled,
                  "A connection transition or another owner still blocks the normal connection controls.")
        metadata += "\ninitiallyReady=\(initiallyReady)\ninitiallyLocallyDisconnected=\(initiallyDisconnected)"

        openSettings(in: app)
        let repairLink = app.buttons["connectionRepairNavigationLink"]
        for _ in 0..<5 {
            if repairLink.exists && repairLink.isHittable { break }
            app.swipeUp()
        }
        try check(repairLink.exists && repairLink.isEnabled && repairLink.isHittable,
                  "The normal Settings connection-repair entry is unavailable.")
        repairLink.tap()
        let start = app.buttons["connectionRepairButton"]
        let progress = app.descendants(matching: .any).matching(identifier: "connectionRepairProgress").firstMatch
        let connectionResult = app.descendants(matching: .any).matching(identifier: "connectionRepairConnectionResult").firstMatch
        let microphoneResult = app.descendants(matching: .any).matching(identifier: "connectionRepairMicrophoneResult").firstMatch
        try check(start.waitForExistence(timeout: 5) && start.isEnabled && start.isHittable
                  && !progress.exists && !connectionResult.exists && !microphoneResult.exists,
                  "Repair must start from an idle page without previous results.")
        let requestedAt = Date().timeIntervalSince1970
        metadata += "\nrepairRequestedAt=\(requestedAt)\nrepairRequests=1\nresultWaitLimitSeconds=30"
        attach("before single repair request")
        start.tap()
        metadata += "\nrepairTapReturnedAt=\(Date().timeIntervalSince1970)"
        // Permission sheets are deliberately not answered. The normal capture
        // lasts five seconds after authorization; an unsettled sheet, cleanup
        // or capture cannot turn a timed-out UI check into a reported pass.
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningForeground && connectionResult.exists && microphoneResult.exists
                && !progress.exists && start.exists && start.isEnabled
        }, object: nil)
        let completion = XCTWaiter.wait(for: [finished], timeout: 30)
        metadata += "\nresultsSettled=\(completion == .completed)\nresultsObservedAt=\(Date().timeIntervalSince1970)"
        try check(completion == .completed, "Repair did not show both results and release its UI gate within the bounded wait.")
        try check(app.alerts.count == 0
                  && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0
                  && connectionResult.isHittable && microphoneResult.isHittable,
                  "The two repair results must be visible without an unresolved authorization dialog.")
        // Read only the two known result rows. Never attach their labels or a
        // page dump; these booleans classify the App's report, not raw evidence.
        let connectionLabel = connectionResult.label
        let microphoneLabel = microphoneResult.label
        let classifications: [(String, Bool)] = [
            ("uiReportsConnectionReleased", ["Control connection disconnected.", "设备控制已断开。"].contains { connectionLabel.contains($0) }),
            ("uiReportsConnectionNotConnected", ["No current control connection. This cannot confirm whether a previous screen session remains.", "当前未连接设备。无法据此判断之前的屏幕会话是否已关闭。"].contains { connectionLabel.contains($0) }),
            ("uiReportsConnectionUnconfirmed", ["Couldn’t confirm that the previous screen-control session closed. Pairing, VPN and conversations are preserved.", "无法确认之前的屏幕控制会话已关闭。配对、VPN 和对话已保留。"].contains { connectionLabel.contains($0) }),
            ("uiReportsMicrophoneSignal", ["Microphone input was detected during this check.", "本次检查检测到了麦克风输入。"].contains { microphoneLabel.contains($0) }),
            ("uiReportsMicrophoneNoSignal", ["No microphone input was detected during this check. You can try again and make a sound near the microphone.", "本次检查未检测到麦克风输入。可以再次检查，并在麦克风附近发出声音。"].contains { microphoneLabel.contains($0) }),
            ("uiReportsMicrophonePermissionDenied", app.buttons["connectionRepairOpenSettingsButton"].exists),
            ("uiReportsMicrophoneUnavailable", ["The microphone check could not be completed. Its result is unconfirmed.", "麦克风检查未能完成，结果尚未确认。"].contains { microphoneLabel.contains($0) }),
            ("uiReportsMicrophoneCancelled", ["Microphone check cancelled.", "麦克风检查已取消。"].contains { microphoneLabel.contains($0) })
        ]
        for (key, value) in classifications { metadata += "\n\(key)=\(value)" }
        metadata += "\nconnectionUIClassificationKnown=\(classifications.prefix(3).contains { $0.1 })\nmicrophoneUIClassificationKnown=\(classifications.dropFirst(3).contains { $0.1 })\nbothResultRowsVisible=true\nrepairButtonReenabled=true"
        openDevice(in: app)
        try requireIdleControls(in: app)
        try check(["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                  && app.buttons["deviceControlBackendPicker"].value as? String == backendTitle
                  && app.buttons["deviceControlBackendPicker"].isEnabled,
                  "Repair changed the original route/backend or retained the connection UI gate.")
        metadata += "\nrouteAndBackendUnchanged=true\nconnectionUIGateReleased=true\npostRepairLocallyDisconnected=\(disconnected.evaluate(with: status))\npostRepairReady=\(ready.evaluate(with: status))\nuiChecksPassed=true\nfinishedAt=\(Date().timeIntervalSince1970)"
    }

    private enum VoiceAcceptanceCase: String {
        case modeSwitch, holdFinish, keyboardFinish, navigateDevice, background
    }

    /// UI checks and action timestamps are only one half of acceptance. Root
    /// must match these times to nonzero PCM and lifecycle stages in the App's
    /// metadata; a late XCTest action must not count as hitting active capture.
    @MainActor
    private func runVoiceAcceptanceCase(_ voiceCase: VoiceAcceptanceCase) throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let backend = ProcessInfo.processInfo.environment["EISCUE_NETWORK_BACKEND"] ?? ""
        let backendTitle = backend == "coreDevice" ? "DisplayService" : "XCTest"
        let ready = NSPredicate(format: "exists == true AND label IN %@", ["Ready to control", "设备操作已就绪"])
        let disconnected = NSPredicate(format: "exists == true AND label IN %@", ["Not connected", "未连接"])
        let cleanup = VoiceCleanup(testCase: self, app: app, backendTitle: backendTitle,
            metadata: "backend=\(backend)\nvoiceCase=\(voiceCase.rawValue)\ntranscriptionRequired=false\naudioSignal=notVerifiedByUITest\nappDiagnostic=SpeechCaptureDiagnostic.json\ncaseValidation=pendingAppDiagnostic")
        cleanup.attachmentName = "Real voice case metadata — \(voiceCase.rawValue) — \(backendTitle)"
        addTeardownBlock { await cleanup.finish() }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw VoiceCheckFailure.unmet(message) }
        }
        func wait(_ predicate: NSPredicate, _ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
        }
        @discardableResult
        func action(_ name: String, _ operation: () -> Void) -> TimeInterval {
            let began = Date().timeIntervalSince1970
            cleanup.metadata += "\n\(name)RequestedAt=\(began)"
            operation()
            let ended = Date().timeIntervalSince1970
            cleanup.metadata += "\n\(name)ReturnedAt=\(ended)\n\(name)CallSeconds=\(ended - began)"
            return ended - began
        }
        do {
            let holdArgument = ProcessInfo.processInfo.environment["EISCUE_VOICE_HOLD_SECONDS"]
            let parsedHold = holdArgument.flatMap(Double.init)
            let holdSeconds = parsedHold ?? 5
            if voiceCase == .holdFinish {
                try check((holdArgument == nil || parsedHold != nil) && holdSeconds.isFinite
                          && (5...10).contains(holdSeconds),
                          "EISCUE_VOICE_HOLD_SECONDS must be a finite number from 5 to 10.")
            }
            try check(app.state != .notRunning, "Open the connected App first; this test never launches it.")
            app.activate()
            try check(app.state == .runningForeground && app.alerts.count == 0,
                      "The foreground App must have no pending authorization dialog.")
            try check(!app.buttons["stopRunButton"].exists && !app.buttons["cancelDictationButton"].exists
                      && !app.staticTexts["speechDeviceRestorationStatus"].exists, "Finish the current task or dictation first.")
            openDevice(in: app)
            try check(app.switches["deviceControlToggle"].isEnabled,
                      "A task or recovery still owns the device.")
            try check(["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                      && app.buttons["deviceControlBackendPicker"].value as? String == backendTitle,
                      "Connect the prepared local-VPN route and explicit backend first.")
            try check(ready.evaluate(with: app.staticTexts["devicePairingComplete"])
                      && app.buttons["disconnectDeviceButton"].isEnabled,
                      "The selected network connection must already be ready.")
            cleanup.ownsCleanup = true
            returnToAssistant(in: app)
            let editor = app.descendants(matching: .any).matching(identifier: "messageInput").firstMatch
            try check(editor.waitForExistence(timeout: 5), "Start from the normal keyboard composer.")
            let originalDraft = try XCTUnwrap(editor.value as? String, "The draft cannot be compared safely.")
            // XCTest may expose the placeholder as the value of an empty field.
            // Keep actual draft text only in memory, never in the attachment.
            let placeholderIsValue = originalDraft == editor.placeholderValue
            let originalPrefix = placeholderIsValue ? "" : originalDraft
            let deviceLink = app.buttons["deviceNavigationLink"]
            let connectedBadge = try XCTUnwrap(deviceLink.value as? String, "The connection badge is unavailable.")
            if voiceCase == .holdFinish {
                cleanup.metadata += "\nD1preludeStartedAt=\(Date().timeIntervalSince1970)\nD1expectedCapture=false\nD1expectedDevicePreparation=false\nD1expectedRestoration=false"
            }
            action("selectVoiceMode") { app.buttons["speechInputButton"].tap() }
            let record = app.buttons["holdToTalkButton"]
            try check(record.waitForExistence(timeout: 5) && record.isEnabled && record.isHittable,
                      "The normal recording control is unavailable.")
            try check(deviceLink.value as? String == connectedBadge,
                      "Selecting voice mode changed the connection before recording.")
            let idleDiagnostic = record.value as? String ?? ""
            try check(idleDiagnostic.hasPrefix("state=idle "),
                      "An idle DEBUG App with --speech-diagnostics is required; no relaunch is performed.")
            cleanup.metadata += "\nvoiceModeSelectedAt=\(Date().timeIntervalSince1970)\ndraftPlaceholderNormalized=\(placeholderIsValue)"
            if voiceCase == .holdFinish {
                action("D1selectKeyboardMode") { app.buttons["speechInputButton"].tap() }
                try check(record.waitForNonExistence(timeout: 5) && editor.waitForExistence(timeout: 5)
                          && editor.value as? String == originalDraft && deviceLink.value as? String == connectedBadge
                          && !app.buttons["cancelDictationButton"].exists
                          && !app.staticTexts["speechDeviceRestorationStatus"].exists,
                          "The D1 mode-only prelude changed the draft or connection, or started dictation work.")
                cleanup.metadata += "\nD1uiChecksPassed=true\nD1recordingRequested=false\nD1draftUnchanged=true\nD1connectionBadgeUnchanged=true\nD1preludeFinishedAt=\(Date().timeIntervalSince1970)"
                action("D2selectVoiceMode") { app.buttons["speechInputButton"].tap() }
                try check(record.waitForExistence(timeout: 5) && record.isEnabled && record.isHittable
                          && (record.value as? String ?? "").hasPrefix("state=idle ")
                          && deviceLink.value as? String == connectedBadge,
                          "The D2 hold-finish case could not start from idle voice mode on the original connection.")
            }
            if voiceCase == .modeSwitch {
                cleanup.metadata += "\nexpectedCapture=false\nexpectedDevicePreparation=false\nexpectedRestoration=false"
                action("selectKeyboardMode") { app.buttons["speechInputButton"].tap() }
                try check(record.waitForNonExistence(timeout: 5)
                          && deviceLink.value as? String == connectedBadge,
                          "Switching input modes changed the ready connection or failed to return to the keyboard.")
            } else {
                cleanup.metadata += "\nexpectedCapture=true\nexpectedNonzeroPCM=true"
                // Resolve coordinates before recording. Do not poll or inspect
                // accessibility during capture: XCTest may await the 55 s end.
                let recordPoint = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let keyboardPoint = app.buttons["speechInputButton"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let devicePoint = deviceLink.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                try check(app.buttons["speechInputButton"].isHittable && deviceLink.isHittable,
                          "The observed controls are unavailable before recording.")
                cleanup.mayOwnRecording = true
                if voiceCase == .holdFinish {
                    let recordFrame = record.frame
                    let endPoint = CGPoint(x: recordFrame.midX + 1, y: recordFrame.midY)
                    try check(recordFrame.width > 2 && recordFrame.height > 0
                              && [endPoint.x, endPoint.y].allSatisfy(\.isFinite) && recordFrame.contains(endPoint),
                              "The recording control has no safe in-control release path.")
                    let end = recordPoint.withOffset(CGVector(dx: 1, dy: 0))
                    cleanup.metadata += "\ngestureSeconds=\(holdSeconds)\ngestureDurationIsAudioDuration=false\nreleaseDragPoints=1\nexpectedGateMode=hold\nexpectedTerminalStage=hold-released_then_stop\nexpectedForegroundRestore=true\nD2captureRequestedAt=\(Date().timeIntervalSince1970)\nD2caseValidation=pendingAppDiagnostic"
                    // The drag form synthesizes one continuous touch. A bare
                    // stationary press may reach the accessibility activation
                    // path instead of exercising the held recognizer.
                    action("holdAndRelease") { recordPoint.press(forDuration: holdSeconds, thenDragTo: end) }
                } else {
                    let startSeconds = action("startToggleCapture") { recordPoint.tap() }
                    // This is a stale-action guard, not a changed driver or App
                    // timeout. Do not navigate or toggle a different state if
                    // XCTest returned only after the requested recording ended.
                    guard startSeconds < 15 else {
                        cleanup.metadata += "\ncaseHit=false\ncaseBlocked=startCommandReturnDelayed\nterminalActionAttempted=false"
                        throw VoiceCheckFailure.unmet("The capture start command returned too late for the bounded interactive case; inspect App metadata.")
                    }
                    cleanup.metadata += "\ninteractiveWaitSeconds=5\nwaitDurationIsAudioDuration=false"
                    Thread.sleep(forTimeInterval: 5)
                    cleanup.metadata += "\nterminalActionAttempted=true\ncaseHit=requiresAppDiagnostic"
                    switch voiceCase {
                    case .keyboardFinish:
                        cleanup.metadata += "\nexpectedTerminalStage=stop\nexpectedForegroundRestore=true"
                        action("selectKeyboardDuringCapture") { keyboardPoint.tap() }
                    case .navigateDevice:
                        cleanup.metadata += "\nexpectedTerminalStage=cancel\nexpectedForegroundRestore=true"
                        action("navigateDeviceDuringCapture") { devicePoint.tap() }
                        try check(app.buttons["deviceConnectionMethodPicker"].waitForExistence(timeout: 5),
                                  "The intended device-page navigation did not occur.")
                        try check(wait(NSPredicate(format: "exists == true AND enabled == true"), app.switches["deviceControlToggle"], timeout: 30),
                                  "The device page still has an owned dictation transition.")
                        returnToAssistant(in: app)
                    case .background:
                        cleanup.metadata += "\nexpectedTerminalStage=cancel_or_interrupted\nbackgroundRestorationPolicy=\(backend == "coreDevice" ? "remainDisconnected" : "observeActualTransport")"
                        action("homeDuringCapture") { XCUIDevice.shared.press(.home) }
                        Thread.sleep(forTimeInterval: 5)
                        let backgroundState = app.state
                        cleanup.metadata += "\nobservedBackgroundAt=\(Date().timeIntervalSince1970)\nbackgroundAppState=\(backgroundState.rawValue)"
                        try check([XCUIApplication.State.runningBackground, .runningBackgroundSuspended].contains(backgroundState),
                                  "The App did not remain running in the background; this helper will not relaunch it.")
                        action("returnToForeground") { app.activate() }
                    case .modeSwitch, .holdFinish:
                        throw VoiceCheckFailure.unmet("Unexpected interactive voice case.")
                    }
                }
                try check(app.buttons["cancelDictationButton"].waitForNonExistence(timeout: 15),
                          "Recording did not finish; no speech text is required for this check.")
                try check(wait(NSPredicate(format: "exists == true AND enabled == true"), app.buttons["speechInputButton"], timeout: 30)
                          && !app.staticTexts["speechDeviceRestorationStatus"].exists,
                          "Dictation cleanup or restoration did not finish.")
                if record.exists {
                    action("returnToKeyboardAfterCapture") { app.buttons["speechInputButton"].tap() }
                    try check(record.waitForNonExistence(timeout: 5), "Could not return to the keyboard after capture.")
                }
            }
            try check(editor.waitForExistence(timeout: 5), "The keyboard composer is unavailable after the case.")
            let finalDraft = try XCTUnwrap(editor.value as? String, "The draft cannot be compared after the case.")
            try check(finalDraft.hasPrefix(originalPrefix), "Dictation lost the original draft prefix.")
            if voiceCase == .modeSwitch {
                try check(finalDraft == originalDraft, "Switching input modes changed the draft.")
            }
            cleanup.metadata += "\ndraftPrefixPreserved=true\ndraftUnchanged=\(finalDraft == originalDraft)"
            openDevice(in: app)
            try check(["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                      && app.buttons["deviceControlBackendPicker"].value as? String == backendTitle
                      && app.buttons["deviceConnectionMethodPicker"].isEnabled && app.switches["deviceControlToggle"].isEnabled,
                      "The original route/backend changed or dictation still owns the device.")
            if voiceCase == .background {
                if backend == "coreDevice" {
                    try check(wait(disconnected, app.staticTexts["devicePairingComplete"])
                              && !app.buttons["disconnectDeviceButton"].exists,
                              "Background dictation unexpectedly restored CoreDevice control.")
                }
                cleanup.metadata += "\nreturnedReady=\(ready.evaluate(with: app.staticTexts["devicePairingComplete"]))\nreturnedLocallyDisconnected=\(disconnected.evaluate(with: app.staticTexts["devicePairingComplete"]))"
            } else {
                try check(wait(ready, app.staticTexts["devicePairingComplete"]), "The original network route did not return to ready.")
                cleanup.metadata += "\nrestoredReady=true"
            }
            if voiceCase == .holdFinish {
                cleanup.metadata += "\nD2uiChecksPassed=true\nD2uiChecksFinishedAt=\(Date().timeIntervalSince1970)"
            }
            cleanup.metadata += "\nuiChecksPassed=true\nuiChecksFinishedAt=\(Date().timeIntervalSince1970)"
            // VoiceCleanup performs the same scoped local disconnection as the
            // original helper, including after a driver/assertion failure.
        } catch {
            cleanup.metadata += "\ncheckFailed=true"
            XCTFail("Real voice \(voiceCase.rawValue) check failed: \(error)")
        }
    }

    @MainActor
    private static func cancelVoiceAndDisconnectIfPossible(
        in app: XCUIApplication, backendTitle: String, mayOwnRecording: Bool
    ) -> String {
        guard app.state == .runningForeground else { return "blockedAppNotForeground" }
        guard app.alerts.count == 0 else { return "blockedByExistingDialog" }
        guard !app.buttons["stopRunButton"].exists else { return "blockedByExistingTask" }
        let cancel = app.buttons["cancelDictationButton"]
        if cancel.exists {
            guard mayOwnRecording else { return "blockedByUnownedRecording" }
            guard cancel.isHittable && cancel.isEnabled else { return "cancelUnavailable" }
            cancel.tap()
            guard cancel.waitForNonExistence(timeout: 15) else { return "cancelUnconfirmed" }
        }
        guard app.staticTexts["speechDeviceRestorationStatus"].waitForNonExistence(timeout: 30) else {
            return "restorationStillPending"
        }
        guard app.state == .runningForeground, app.alerts.count == 0,
              !app.buttons["stopRunButton"].exists else { return "blockedBeforeDisconnect" }
        let method = app.buttons["deviceConnectionMethodPicker"]
        if !method.exists {
            let link = app.buttons["deviceNavigationLink"]
            guard link.isHittable && link.isEnabled else { return "devicePageUnavailable" }
            link.tap()
            guard method.waitForExistence(timeout: 5) else { return "devicePageUnavailable" }
        }
        guard ["In app", "App 内连接"].contains(method.value as? String ?? ""),
              app.buttons["deviceControlBackendPicker"].value as? String == backendTitle else {
            return "blockedByChangedRoute"
        }
        guard method.isEnabled, app.switches["deviceControlToggle"].isEnabled else {
            return "blockedByOwnedOperation"
        }
        let disconnect = app.buttons["disconnectDeviceButton"]
        if disconnect.exists {
            guard disconnect.isHittable && disconnect.isEnabled else { return "disconnectUnavailable" }
            disconnect.tap()
            guard disconnect.waitForNonExistence(timeout: 15) else { return "disconnectUnconfirmed" }
        }
        let disconnected = NSPredicate(format: "exists == true AND label IN %@", ["Not connected", "未连接"])
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: disconnected,
                                      object: app.staticTexts["devicePairingComplete"])], timeout: 15)
        return result == .completed ? "locallyDisconnected" : "disconnectUnconfirmed"
    }

    @MainActor
    private final class VoiceCleanup {
        weak var testCase: NetworkAcceptanceUITests?
        let app: XCUIApplication
        let backendTitle: String
        var metadata: String
        var attachmentName: String?
        var ownsCleanup = false
        var mayOwnRecording = false

        init(testCase: NetworkAcceptanceUITests, app: XCUIApplication, backendTitle: String, metadata: String) {
            self.testCase = testCase
            self.app = app
            self.backendTitle = backendTitle
            self.metadata = metadata
        }

        func finish() {
            if ownsCleanup {
                // Preserve an incomplete marker if the cleanup driver itself aborts.
                metadata += "\ncleanupAttempted=true"
                attach(name: "Voice cleanup started — result pending",
                       details: "\ncleanupOutcome=inProgress\ncleanupIncomplete=true")
                let outcome = NetworkAcceptanceUITests.cancelVoiceAndDisconnectIfPossible(
                    in: app, backendTitle: backendTitle, mayOwnRecording: mayOwnRecording)
                ownsCleanup = outcome != "locallyDisconnected"
                metadata += "\ncleanupOutcome=\(outcome)\ncleanupIncomplete=\(ownsCleanup)"
            } else {
                metadata += "\ncleanupAttempted=false"
            }
            attach(name: attachmentName ?? "Real voice hold-cancel gesture metadata — \(backendTitle)")
            if ownsCleanup { XCTFail("Voice cleanup remains incomplete; see cleanupOutcome in the attachment.") }
        }

        private func attach(name: String, details: String = "") {
            let attachment = XCTAttachment(string: metadata + details)
            attachment.name = name
            attachment.lifetime = .keepAlways
            testCase?.add(attachment)
        }
    }

    @MainActor
    private func requireIdleControls(in app: XCUIApplication) throws {
        let permission = app.switches["deviceControlToggle"]
        let method = app.buttons["deviceConnectionMethodPicker"]
        try waitFor(NSPredicate(format: "exists == true AND enabled == true"), on: permission,
                    message: "Finish tasks, recovery, recording and connection work before changing preferences.")
        try require(method.isEnabled, "The route is still owned by another operation.")
        try require(app.alerts.count == 0, "This preparation does not handle authorization dialogs.")
    }

    @MainActor
    private func waitFor(_ predicate: NSPredicate, on element: XCUIElement, message: String) throws {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 15)
        try require(result == .completed, message)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { XCTFail(message); throw PreparationFailure.blocked }
    }

    private enum PreparationFailure: Error { case blocked }
    private enum VoiceCheckFailure: Error { case unmet(String) }
}
