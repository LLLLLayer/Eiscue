import XCTest

/// This opt-in helper sends one ordinary request to the saved model. A passing
/// host-flow check still requires review of the actual Calculator screenshots.
final class RealModelCalculatorAcceptanceUITests: XCTestCase {
    @MainActor private var failureEvidence: (@MainActor () -> Void)?

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Real-model Calculator acceptance requires an explicitly prepared physical iPhone.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_REAL_MODEL_TEST"] == "1" || environment["EISCUE_REAL_MODEL_RECOVERY"] == "1" else {
            throw XCTSkip("Opt in explicitly to the real-model test or exact-run recovery helper.")
        }
        #endif
    }

    @MainActor
    func testCurrentSavedModelCalculatorFlow() async throws {
        guard ProcessInfo.processInfo.environment["EISCUE_REAL_MODEL_TEST"] == "1",
              ProcessInfo.processInfo.environment["EISCUE_REAL_MODEL_RECOVERY"] != "1" else {
            throw XCTSkip("Recovery opt-in never starts a model request.")
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
        guard environment["EISCUE_REAL_MODEL_RECOVERY"] == "1", environment["EISCUE_REAL_MODEL_TEST"] != "1" else {
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
    private func readMetadata(in app: XCUIApplication, evidence: Evidence? = nil, recovery: RecoveryEvidence? = nil) throws -> Snapshot {
        let element = app.descendants(matching: .any).matching(identifier: "debugRealModelRunMetadata").firstMatch
        try require(element.waitForExistence(timeout: 5),
                    "The explicit read-only real-model diagnostics projection is unavailable.")
        let value = try XCTUnwrap(element.value as? String, "Run metadata has no accessibility value.")
        let data = try XCTUnwrap(value.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        evidence?.report.lastSnapshot = snapshot
        recovery?.report.lastSnapshot = snapshot
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
