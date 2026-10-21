import ObjectiveC
import XCTest

/// Operates the already connected normal App. These checks require the real
/// connect-returned-before-publish DEBUG boundary, never a synthetic transport.
/// Root must correlate the attachment with both App JSON reports. Nonzero PCM
/// establishes capture only; it does not establish spoken-word transcription.
final class VoiceRecoveryAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Voice recovery acceptance requires the prepared physical iPhone.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["EISCUE_REAL_NETWORK_TEST"] == "1",
              environment["EISCUE_REAL_SPEECH_TEST"] == "1",
              environment["EISCUE_VOICE_BOUNDED_INTERACTION"] == "1",
              environment["EISCUE_NETWORK_BACKEND"] == "coreDevice" else {
            throw XCTSkip("Opt in with TEST_RUNNER_EISCUE_REAL_NETWORK_TEST=1, REAL_SPEECH_TEST=1, VOICE_BOUNDED_INTERACTION=1 and NETWORK_BACKEND=coreDevice.")
        }
        #endif
    }

    @MainActor
    func testBackgroundAfterRealConnectBeforeReadyPublication() throws {
        try runRecoveryCase(.background)
    }

    /// A busy backend picker must refuse selection. After explicit cancellation
    /// and cleanup, change to the explicitly requested backend and leave it there
    /// for root to inspect. Never invoke a model or connect the new backend.
    @MainActor
    func testBusyBackendSelectionThenCancelAndExplicitlySelectXCTest() throws {
        guard ProcessInfo.processInfo.environment["EISCUE_VOICE_TARGET_BACKEND"] == "xcTest" else {
            throw XCTSkip("Also set TEST_RUNNER_EISCUE_VOICE_TARGET_BACKEND=xcTest for this explicit preference change.")
        }
        try runRecoveryCase(.backendSelection)
    }

    private enum RecoveryCase: String { case background, backendSelection }
    private enum CheckFailure: Error { case unmet(StaticString) }

    @MainActor
    private func runRecoveryCase(_ recoveryCase: RecoveryCase) throws {
        let app = XCUIApplication(bundleIdentifier: "org.eiscue.app")
        let evidence = Evidence(testCase: self, recoveryCase: recoveryCase, metadata: [
            "helper": "voiceRecoveryBoundary", "case": recoveryCase.rawValue,
            "startedAt": Date().timeIntervalSince1970,
            "caseValidation": "pendingAppDiagnosticCorrelation", "realSpeechRequired": false,
            "audioOrDraftExported": false, "appLaunchAttempted": false,
            "connectionAttemptedByHelper": false, "permissionChangedByHelper": false
        ])
        addTeardownBlock { await evidence.attach() }
        var scope: InteractionScope?
        var ownsRequest = false
        var captureUIEnded = false
        var restorationCancelRequested = false
        var completed = false
        defer {
            // A failed timing check must not leave this helper's microphone or
            // restoration running. Cleanup is a separate event, never a pass.
            if !completed, ownsRequest {
                evidence.metadata["failureCleanupStartedAt"] = Date().timeIntervalSince1970
                evidence.metadata["failureCleanupWaitLimitSeconds"] = 45
                evidence.metadata["failureCleanupRemoteReleaseVerified"] = false
                evidence.metadata["failureCleanupUIConfirmed"] = false
                evidence.metadata["failureCleanupUIUnconfirmed"] = true
                let deadline = ContinuousClock.now.advanced(by: .seconds(45))
                let cancel = app.buttons["cancelDictationButton"]
                let restoration = app.buttons["cancelSpeechDeviceRestorationButton"]
                let status = app.staticTexts["speechDeviceRestorationStatus"]
                let voiceMode = app.buttons["speechInputButton"]
                var captureCancelRequested = false
                var quietSince: ContinuousClock.Instant?
                var uiConfirmed = false
                repeat {
                    // Never activate/terminate the App or cancel a run/new
                    // recording. Loss of this known UI scope stays unconfirmed.
                    guard app.state == .runningForeground, app.alerts.count == 0,
                          !app.buttons["stopRunButton"].exists,
                          app.buttons["deviceNavigationLink"].exists else { break }
                    let capturePresent = cancel.exists
                    if captureUIEnded && capturePresent { break }
                    if capturePresent {
                        quietSince = nil
                        if !captureCancelRequested, cancel.isEnabled, cancel.isHittable {
                            captureCancelRequested = true
                            evidence.metadata["failureCaptureCancelRequestedAt"] = Date().timeIntervalSince1970
                            cancel.tap()
                        }
                    } else {
                        captureUIEnded = true
                        // SwiftUI may expose restoration only after capture's
                        // cancel control disappears. Observe that handoff and
                        // await the cancellation's UI gate; one tap is not done.
                        if restoration.exists || status.exists {
                            quietSince = nil
                            if !restorationCancelRequested, restoration.exists,
                               restoration.isEnabled, restoration.isHittable {
                                restorationCancelRequested = true
                                evidence.metadata["failureRestorationCancelRequestedAt"] = Date().timeIntervalSince1970
                                restoration.tap()
                            }
                        } else if voiceMode.exists && voiceMode.isEnabled && voiceMode.activityIndicators.count == 0 {
                            if quietSince == nil { quietSince = ContinuousClock.now }
                            if let quietSince, ContinuousClock.now >= quietSince.advanced(by: .seconds(3)) {
                                uiConfirmed = true
                                break
                            }
                        } else { quietSince = nil }
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                } while ContinuousClock.now < deadline
                evidence.metadata["failureCleanupUIConfirmed"] = uiConfirmed
                evidence.metadata["failureCleanupUIUnconfirmed"] = !uiConfirmed
                evidence.metadata["failureCleanupFinishedAt"] = Date().timeIntervalSince1970
                ownsRequest = false
            }
            evidence.metadata["interactionOptionsRestored"] = scope?.restore() ?? true
            evidence.attach()
        }
        func require(_ condition: Bool, _ message: StaticString) throws {
            guard condition else { throw CheckFailure.unmet(message) }
        }
        func wait(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            repeat {
                if condition() { return true }
                Thread.sleep(forTimeInterval: 0.05)
            } while ContinuousClock.now < deadline
            return false
        }
        func act(_ name: String, _ action: () -> Void) {
            evidence.metadata[name + "RequestedAt"] = Date().timeIntervalSince1970
            action()
            evidence.metadata[name + "ReturnedAt"] = Date().timeIntervalSince1970
        }
        let ready = ["Ready to control", "设备操作已就绪"]
        let readyBadge = ["Ready", "已就绪"]
        let boundary = "phase=connect-returned-before-publish-wait-entered waiting=true"
        do {
            try require(app.state == .runningForeground,
                        "Return to the normal connected App first; this helper never launches it.")
            try require(app.alerts.count == 0 && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0,
                        "Resolve authorization dialogs separately.")
            try require(!app.buttons["stopRunButton"].exists && !app.buttons["cancelDictationButton"].exists
                        && !app.staticTexts["speechDeviceRestorationStatus"].exists,
                        "Finish the current run, recording and recovery first.")
            openDevice(in: app)
            try require(["In app", "App 内连接"].contains(app.buttons["deviceConnectionMethodPicker"].value as? String ?? "")
                        && app.buttons["deviceControlBackendPicker"].value as? String == "DisplayService"
                        && ready.contains(app.staticTexts["devicePairingComplete"].label)
                        && app.buttons["disconnectDeviceButton"].isEnabled,
                        "The real local-VPN CoreDevice connection must already be ready.")
            returnToAssistant(in: app)
            let editor = app.descendants(matching: .any).matching(identifier: "messageInput").firstMatch
            try require(editor.waitForExistence(timeout: 5), "Start with the normal keyboard composer.")
            let originalDraft = try XCTUnwrap(editor.value as? String)
            let originalPrefix = originalDraft == editor.placeholderValue ? "" : originalDraft
            let installedScope = try InteractionScope(app: app)
            scope = installedScope
            addTeardownBlock { await installedScope.restore() }
            act("selectVoiceMode") { app.buttons["speechInputButton"].tap() }
            let record = app.buttons["holdToTalkButton"]
            try require(record.waitForExistence(timeout: 5) && record.isEnabled && record.isHittable
                        && (record.value as? String ?? "").hasPrefix("state=idle "),
                        "The normal idle --speech-diagnostics recording control is required.")
            ownsRequest = true
            act("requestCapture") { record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            try require(wait(seconds: 15) { Self.hasNonzeroCapture(record) },
                        "Actual nonzero PCM capture was not observed; no recovery case action was sent.")
            evidence.metadata["nonzeroPCMObservedAt"] = Date().timeIntervalSince1970
            Thread.sleep(forTimeInterval: 2)
            try require(Self.hasNonzeroCapture(record), "Recording ended before the normal stop action.")
            act("stopCapture") { record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            let status = app.staticTexts["speechDeviceRestorationStatus"]
            try require(wait(seconds: 30) {
                status.exists && status.value as? String == boundary
                    && !app.buttons["cancelDictationButton"].exists
            }, "The actual connect-returned-before-publish boundary was not observed; no late case action was sent.")
            captureUIEnded = true
            evidence.metadata["actualConnectReturnedBoundaryObservedAt"] = Date().timeIntervalSince1970
            try require(editor.exists, "The completed utterance has not returned to the keyboard composer.")
            let completedDraft = try XCTUnwrap(editor.value as? String)
            try require(originalPrefix.isEmpty || completedDraft.hasPrefix(originalPrefix),
                        "Capture changed the original typed draft prefix.")

            if recoveryCase == .backendSelection {
                act("openDeviceDuringRecovery") { openDevice(in: app) }
                let picker = app.buttons["deviceControlBackendPicker"]
                try require(picker.exists && !picker.isEnabled && picker.value as? String == "DisplayService",
                            "The real recovery must disable backend selection without changing its preference.")
                evidence.metadata["busyBackendSelectionDisabled"] = true
                returnToAssistant(in: app)
                let cancel = app.buttons["cancelSpeechDeviceRestorationButton"]
                try require(status.exists && status.value as? String == boundary
                            && cancel.exists && cancel.isEnabled && cancel.isHittable,
                            "The boundary elapsed before explicit cancellation; no late action was sent.")
                restorationCancelRequested = true
                act("cancelAtReturnedConnectionBoundary") { cancel.tap() }
            } else {
                try require(status.value as? String == boundary, "The boundary elapsed before backgrounding.")
                act("backgroundAtReturnedConnectionBoundary") { XCUIDevice.shared.press(.home) }
                try require(wait(seconds: 5) {
                    app.state == .runningBackground || app.state == .runningBackgroundSuspended
                }, "The existing App did not enter background.")
                evidence.metadata["backgroundObservedAt"] = Date().timeIntervalSince1970
                Thread.sleep(forTimeInterval: 3)
                try require(app.state != .notRunning, "The existing App exited; this helper never relaunches it.")
                act("returnToForeground") { app.activate() }
            }
            try require(wait(seconds: 45) {
                !status.exists && !app.buttons["cancelSpeechDeviceRestorationButton"].exists
                    && !app.buttons["cancelDictationButton"].exists && app.buttons["speechInputButton"].isEnabled
            }, "The captured recovery has not finished its cleanup.")
            // The owned lifecycle is over. Later draft/selection assertions
            // must never grant cleanup authority over a newer task or capture.
            ownsRequest = false
            // Only the real recovery boundary needs unquiesced interactions.
            // Restore normal synchronization before later navigation/sheets.
            let interactionsRestored = scope?.restore() ?? true
            evidence.metadata["interactionOptionsRestoredAfterCleanup"] = interactionsRestored
            try require(interactionsRestored, "The original XCTest interaction options were not restored after cleanup.")
            evidence.metadata["interactionOptionsRestoredAfterCleanupAt"] = Date().timeIntervalSince1970
            try require(editor.exists && editor.value as? String == completedDraft,
                        "The completed draft changed during recovery cancellation.")
            evidence.metadata["cleanupUIFinishedAt"] = Date().timeIntervalSince1970
            evidence.metadata["completedDraftPreserved"] = true
            let lateDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            repeat {
                try require(!readyBadge.contains(app.buttons["deviceNavigationLink"].value as? String ?? "")
                            && !status.exists && !app.buttons["cancelDictationButton"].exists,
                            "Old recovery published late Ready, restarted recovery or started capture.")
                Thread.sleep(forTimeInterval: 0.1)
            } while ContinuousClock.now < lateDeadline
            evidence.metadata["lateReadyObservationSeconds"] = 3
            openDevice(in: app)
            let picker = app.buttons["deviceControlBackendPicker"]
            try require(picker.isEnabled && app.switches["deviceControlToggle"].isEnabled
                        && !ready.contains(app.staticTexts["devicePairingComplete"].label),
                        "Recovery cleanup retained ownership or published Ready.")
            if recoveryCase == .backendSelection {
                try require(wait(seconds: 5) { picker.exists && picker.isEnabled && picker.isHittable },
                            "The backend picker was not ready after cleanup.")
                act("openBackendPickerAfterCleanup") { picker.tap() }
                let choice = app.buttons["deviceControlBackendChoice_xcTest"]
                try require(wait(seconds: 5) { choice.exists && choice.isEnabled && choice.isHittable },
                            "The explicit XCTest choice was not ready in the backend sheet.")
                evidence.metadata["backendChoiceReadyObservedAt"] = Date().timeIntervalSince1970
                act("selectBackendAfterCleanup") { choice.tap() }
                try require(wait(seconds: 5) { !choice.exists },
                            "The backend sheet did not dismiss after the explicit XCTest choice.")
                evidence.metadata["backendChoiceDismissedObservedAt"] = Date().timeIntervalSince1970
                try require(wait(seconds: 15) { picker.exists && picker.isEnabled && picker.value as? String == "XCTest" },
                            "The explicit backend preference did not settle after cleanup.")
                evidence.metadata["explicitXCTestSelectionSettled"] = true
                evidence.metadata["leavesSelectedBackendXCTest"] = true
                let noConnectDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                repeat {
                    try require(!ready.contains(app.staticTexts["devicePairingComplete"].label)
                                && app.buttons["connectDeviceButton"].isEnabled,
                                "Explicit preference selection connected automatically or retained busy state.")
                    Thread.sleep(forTimeInterval: 0.1)
                } while ContinuousClock.now < noConnectDeadline
            }
            evidence.metadata["uiChecksPassed"] = true
            completed = true
        } catch CheckFailure.unmet(let message) {
            evidence.recordFailure(message)
            evidence.attach(phase: .failureBeforeCleanup)
            throw CheckFailure.unmet(message)
        } catch {
            let reason: StaticString = "A required bounded UI observation was unavailable; inspect fixed metadata only."
            evidence.recordFailure(reason)
            evidence.attach(phase: .failureBeforeCleanup)
            throw CheckFailure.unmet(reason)
        }
    }

    @MainActor private final class Evidence {
        enum Phase: String, Hashable { case failureBeforeCleanup, finished }
        weak var testCase: XCTestCase?
        let recoveryCase: RecoveryCase
        var metadata: [String: Any]
        private var attached: Set<Phase> = []
        init(testCase: XCTestCase, recoveryCase: RecoveryCase, metadata: [String: Any]) {
            self.testCase = testCase; self.recoveryCase = recoveryCase; self.metadata = metadata
        }
        func recordFailure(_ reason: StaticString) {
            metadata["checkFailed"] = true
            metadata["checkFailureReason"] = reason.description
            metadata["checkFailureObservedAt"] = Date().timeIntervalSince1970
        }
        func attach(phase: Phase = .finished) {
            guard !attached.contains(phase) else { return }
            // No AX reads here: a failed cleanup lookup must not prevent the
            // original fixed failure or the latest cleanup metadata exporting.
            var snapshot = metadata
            snapshot["evidencePhase"] = phase.rawValue
            snapshot[phase == .finished ? "finishedAt" : "evidenceObservedAt"] = Date().timeIntervalSince1970
            guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return }
            attached.insert(phase)
            let attachment = XCTAttachment(string: text)
            attachment.name = "Voice recovery boundary — \(recoveryCase.rawValue) — \(phase.rawValue) — metadata only"
            attachment.lifetime = .keepAlways
            testCase?.add(attachment)
        }
    }

    @MainActor
    private static func hasNonzeroCapture(_ record: XCUIElement) -> Bool {
        guard record.exists, let value = record.value as? String else { return false }
        let pairs = value.split(separator: " ").map { $0.split(separator: "=", maxSplits: 1) }
        let fields = Dictionary(pairs.filter { $0.count == 2 }.map { (String($0[0]), String($0[1])) }, uniquingKeysWith: { first, _ in first })
        return fields["state"] == "recording" && fields["signal"] == "true"
            && (Int(fields["buffers"] ?? "") ?? 0) > 0 && (Int(fields["frames"] ?? "") ?? 0) > 0
    }

    /// Same bounded runner ABI as NetworkAcceptanceUITests. Preserve all other
    /// driver options and restore them even after a failed case.
    @MainActor
    private final class InteractionScope {
        private let app: XCUIApplication
        private let original: NSNumber
        private var restored = false
        init(app: XCUIApplication) throws {
            guard let appClass = object_getClass(app) else { throw CheckFailure.unmet("The XCTest application class is unavailable.") }
            for (name, encoding) in [("currentInteractionOptions", "I16@0:8"), ("setCurrentInteractionOptions:", "v20@0:8I16")] {
                let selector = NSSelectorFromString(name)
                guard app.responds(to: selector), let method = class_getInstanceMethod(appClass, selector),
                      let actual = method_getTypeEncoding(method), String(cString: actual) == encoding else {
                    throw CheckFailure.unmet("The validated bounded XCTest interaction ABI is unavailable.")
                }
            }
            guard let original = app.value(forKey: "currentInteractionOptions") as? NSNumber else {
                throw CheckFailure.unmet("The original XCTest interaction options are unavailable.")
            }
            self.app = app; self.original = original
            let scoped = original.uint32Value | 0b11
            app.setValue(NSNumber(value: scoped), forKey: "currentInteractionOptions")
            guard (app.value(forKey: "currentInteractionOptions") as? NSNumber)?.uint32Value == scoped else {
                app.setValue(original, forKey: "currentInteractionOptions")
                throw CheckFailure.unmet("XCTest did not apply bounded interaction options.")
            }
        }
        @discardableResult func restore() -> Bool {
            if restored { return true }
            app.setValue(original, forKey: "currentInteractionOptions")
            restored = (app.value(forKey: "currentInteractionOptions") as? NSNumber)?.uint32Value == original.uint32Value
            return restored
        }
    }
}
