#if DEBUG
import EiscueAgentKit
import EiscueDeviceCore
import UIKit
import XCTest
@testable import Eiscue

@MainActor
final class DebugNetworkRunAcceptanceTests: XCTestCase {
    func testExistingNetworkDefaultsStillRequireAnExplicitBackend() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest"])
        XCTAssertEqual(plan.route, .localVPN)
        XCTAssertEqual(plan.backend, .xcTest)
        XCTAssertEqual(plan.kind, .background)
        XCTAssertTrue(plan.requiresLocalTunnel)
        XCTAssertFalse(plan.usesInputTarget)
        XCTAssertFalse(plan.usesAcceptanceTarget)
        let resume = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--resume-existing-local-tunnel"])
        XCTAssertTrue(resume.requiresLocalTunnel)
        XCTAssertTrue(resume.resumeTunnel)
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: []))
    }

    func testBluetoothForegroundSwipeHasNoNetworkBackendOrTunnel() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments())
        XCTAssertEqual(plan.route, .bluetoothBoard)
        XCTAssertNil(plan.backend)
        XCTAssertEqual(plan.kind, .foregroundSwipe)
        XCTAssertTrue(plan.usesInputTarget)
        XCTAssertTrue(plan.usesAcceptanceTarget)
        XCTAssertFalse(plan.resumeTunnel)
        XCTAssertFalse(plan.requiresLocalTunnel)
        XCTAssertFalse(plan.contactComparison)
        XCTAssertEqual(plan.maxToolCalls, 3)
    }

    func testBluetoothAllowsOwnedInputAndExplicitHIDBackgroundCases() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "inflightStop"))
        XCTAssertTrue(plan.usesInputTarget)
        for kind in ["background", "appReturn", "unknown"] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: kind)))
        }
    }

    func testHIDBackgroundUsesOnlyObservationAndWaitsForAnExternalTransition() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "hidBackground"))
        XCTAssertEqual(plan.route, .bluetoothBoard)
        XCTAssertNil(plan.backend)
        XCTAssertEqual(plan.inputRoute, .bluetooth)
        XCTAssertEqual(plan.requiredTools, [.screenshot])
        XCTAssertFalse(plan.usesInputTarget)
        XCTAssertTrue(plan.usesAcceptanceTarget, "HID background shows real setup then the owned page without requiring an input trace.")
        XCTAssertTrue(plan.samplesBackground)
        XCTAssertEqual(plan.backgroundWaitSeconds, 60)
        XCTAssertEqual(plan.seconds, 60)
        XCTAssertEqual(plan.interval, 15)
        XCTAssertEqual(plan.sampleGapLimit, 20)
        let session = DeviceToolSession(capabilities: [.screenshot],
            client: DeviceClient(actuator: RestrictedBLEAcceptanceActuator()), scope: .control,
            timeoutSeconds: 10, log: { _, _ in }, onUnknown: {})
        XCTAssertNil(plan.firstMissingTool(in: session.tools), "A HID background check must not need Home, launch or swipe.")
    }

    func testNCMOwnedInputCasesUseExplicitBackendAndNoTunnelOrHIDSetup() throws {
        for backend in ["coreDevice", "xcTest"] {
            for kind in ["foregroundSwipe", "inflightStop"] {
                let plan = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-route", "usbBoard",
                    "--network-run-backend", backend, "--network-run-case", kind])
                XCTAssertEqual(plan.route, .usbBoard)
                XCTAssertEqual(plan.backend?.rawValue, backend)
                XCTAssertNil(plan.inputRoute)
                XCTAssertFalse(plan.requiresLocalTunnel)
                XCTAssertFalse(plan.resumeTunnel)
                XCTAssertFalse(plan.contactComparison)
                XCTAssertTrue(plan.usesInputTarget)
                XCTAssertTrue(plan.usesAcceptanceTarget)
                XCTAssertEqual(plan.requiredTools, [.screenshot, .swipe])
                XCTAssertEqual(plan.maxToolCalls, kind == "foregroundSwipe" ? 3 : 70)
                XCTAssertNoThrow(try plan.validateBluetoothSetup(.ready(capabilities: [.screenshot, .swipe])))
                XCTAssertFalse(DeviceRunCleanup.acceptsRelease(confirmed: false, method: plan.route))
                XCTAssertTrue(DeviceRunCleanup.acceptsRelease(confirmed: true, method: plan.route))
            }
        }
    }

    func testNCMRejectsImplicitBackendTunnelResumeAndHIDArguments() {
        let base = ["--network-run-route", "usbBoard", "--network-run-case", "foregroundSwipe"]
        for backend in [[], ["--network-run-backend"], ["--network-run-backend", "automatic"], ["--network-run-backend", "unknown"]] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: base + backend))
        }
        let explicit = base + ["--network-run-backend", "xcTest"]
        for extra in [["--resume-existing-local-tunnel"], ["--network-run-input-route", "usb"],
                      ["--network-run-input-route", "bluetooth"], ["--network-run-contact-comparison"]] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: explicit + extra))
        }
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-route", "usbBoard",
            "--network-run-backend", "coreDevice", "--network-run-case", "hidBackground"]))
    }

    func testHIDInputRouteIsExplicitForAllHIDCasesAndRejectedForNetworkCases() throws {
        for kind in ["hidBackground", "foregroundSwipe", "inflightStop"] {
            for route in ["bluetooth", "usb"] {
                let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: kind) + ["--network-run-input-route", route])
                XCTAssertEqual(plan.inputRoute?.rawValue, route)
            }
        }
        for extra in [["--network-run-input-route"], ["--network-run-input-route", "unknown"],
                      ["--network-run-input-route", "usb", "--network-run-contact-comparison"],
                      ["--network-run-cancel-after-seconds", "1"]] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "hidBackground") + extra))
        }
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--network-run-case", "hidBackground"]))
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--network-run-input-route", "usb"]))
    }

    func testHIDBackgroundRequiresTapTextCalibrationButDoesNotRequireSwipe() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "hidBackground"))
        XCTAssertNoThrow(try plan.validateBluetoothSetup(.ready(capabilities: [.screenshot, .tap, .textInput])))
        for status in [DeviceStatus.unavailable(reason: "fixture"), .ready(capabilities: [.screenshot]), .ready(capabilities: [.screenshot, .tap])] {
            XCTAssertThrowsError(try plan.validateBluetoothSetup(status)) {
                XCTAssertEqual($0 as? DebugNetworkRunAcceptance.Failure, .bluetoothCalibrationRequired)
            }
        }
    }

    func testBackgroundWaitDoesNotAcceptInactiveAndReturnsOnlyAfterBackground() async throws {
        var state = UIApplication.State.active
        var observations: [UIApplication.State] = []
        let transition = Task { @MainActor in
            state = .inactive
            try await Task.sleep(for: .milliseconds(100))
            state = .background
        }
        defer { transition.cancel() }
        try await DebugNetworkRunAcceptance.waitForBackground(timeoutSeconds: 1, applicationState: {
            observations.append(state)
            return state
        })
        XCTAssertTrue(observations.contains(.inactive))
        XCTAssertEqual(observations.last, .background)
    }

    func testBackgroundWaitTimesOutAndHonorsCancellationWithoutFakingBackground() async throws {
        do {
            try await DebugNetworkRunAcceptance.waitForBackground(timeoutSeconds: 0.01, applicationState: { .active })
            XCTFail("A foreground process must not pass the background gate.")
        } catch { XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .didNotBackground) }
        let waiting = Task { @MainActor in
            try await DebugNetworkRunAcceptance.waitForBackground(timeoutSeconds: 1, applicationState: { .inactive })
        }
        waiting.cancel()
        do { try await waiting.value; XCTFail("Cancellation must settle the wait.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testBluetoothSwipePreflightRejectsTapAndTextOnlyBeforeSubmission() throws {
        for kind in ["foregroundSwipe", "inflightStop"] {
            let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: kind))
            XCTAssertThrowsError(try plan.validateBluetoothSetup(.ready(capabilities: [.screenshot, .tap, .textInput]))) {
                XCTAssertEqual($0 as? DebugNetworkRunAcceptance.Failure, .bluetoothSwipeCheckRequired)
            }
            XCTAssertNoThrow(try plan.validateBluetoothSetup(.ready(capabilities: [.screenshot, .tap, .textInput, .swipe])))
        }
        let network = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest"])
        XCTAssertNoThrow(try network.validateBluetoothSetup(.ready(capabilities: [.screenshot, .home])))
    }

    func testRestrictedBLEToolRegistrationSupportsOnlyTheOwnedSwipeCases() throws {
        let session = DeviceToolSession(capabilities: [.screenshot, .swipe],
            client: DeviceClient(actuator: RestrictedBLEAcceptanceActuator()), scope: .control,
            timeoutSeconds: 10, log: { _, _ in }, onUnknown: {})
        let tools = session.tools
        XCTAssertEqual(Set(tools.map(\.name)), Set([DeviceToolSpec.screenshot.rawValue, DeviceToolSpec.swipe.rawValue]))
        for kind in ["foregroundSwipe", "inflightStop"] {
            let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: kind))
            XCTAssertEqual(plan.requiredTools, [.screenshot, .swipe])
            XCTAssertNil(plan.firstMissingTool(in: tools))
        }
        let background = try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest"])
        XCTAssertEqual(background.firstMissingTool(in: tools), .home)
        let comparison = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments() + ["--network-run-contact-comparison"])
        XCTAssertNil(comparison.firstMissingTool(in: tools))
        XCTAssertEqual(comparison.requiredTools, [.screenshot, .swipe])
        XCTAssertEqual(comparison.maxToolCalls, DeviceToolSpec.screenshot.executionCost + 2 * DeviceToolSpec.swipe.executionCost)
    }

    func testContactComparisonRequiresExplicitBLEForegroundAndReservesBothActions() throws {
        let flag = "--network-run-contact-comparison"
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments() + [flag])
        XCTAssertTrue(plan.contactComparison)
        XCTAssertEqual(plan.maxToolCalls, 5)
        XCTAssertEqual(plan.expectedSwipeCount, 2)
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments(kind: "inflightStop") + [flag]))
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", flag]))
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--network-run-case", "foregroundSwipe", flag]))
        let initial = UUID(), stationaryFrame = UUID()
        let next = try DebugNetworkRunAcceptance.postActionFrameID(initialFrameID: initial, result: result(frameID: stationaryFrame, image: Data([1])))
        XCTAssertEqual(next, stationaryFrame, "The moving action must use the stationary action's returned grant.")
    }

    func testEmptyChatRegistrationIdentifiesScreenshotAsTheFirstMissingTool() throws {
        let plan = try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments())
        let chat = DeviceToolSession(capabilities: [.screenshot, .swipe],
            client: DeviceClient(actuator: RestrictedBLEAcceptanceActuator()), scope: .chat,
            timeoutSeconds: 10, log: { _, _ in }, onUnknown: {})
        XCTAssertTrue(chat.tools.isEmpty)
        XCTAssertEqual(plan.firstMissingTool(in: chat.tools), .screenshot)
        let observe = DeviceToolSession(capabilities: [.screenshot, .swipe],
            client: DeviceClient(actuator: RestrictedBLEAcceptanceActuator()), scope: .observe,
            timeoutSeconds: 10, log: { _, _ in }, onUnknown: {})
        XCTAssertEqual(plan.firstMissingTool(in: observe.tools), .swipe)
    }

    func testBluetoothRejectsAmbiguousNetworkAndConflictingDiagnosticArguments() {
        for extra in [["--network-run-backend", "coreDevice"], ["--resume-existing-local-tunnel"],
                      ["--network-run-cancel-after-seconds", "1"], ["--ui-testing"], ["--owned-device-check"], ["--ble-device-check"]] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: bluetoothArguments() + extra), "\(extra)")
        }
        for route in ["unknown"] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-route", route, "--network-run-backend", "xcTest"]))
        }
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.Plan(arguments: ["--network-run-backend", "xcTest", "--network-run-route"]))
    }

    func testSwipeRequiresTheActionsNewNonemptyImageAndVisibleMovement() throws {
        let initial = UUID(), next = UUID()
        let evidence = try DebugNetworkRunAcceptance.swipeEvidence(initialFrameID: initial,
            result: result(frameID: next, image: Data([1, 2, 3])), startRowY: 200, endRowY: 150)
        XCTAssertEqual(evidence.initialFrameID, initial)
        XCTAssertEqual(evidence.postActionFrameID, next)
        XCTAssertEqual(evidence.postActionImageBytes, 3)
        XCTAssertEqual(evidence.rowDeltaPoints, 50)
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        try metadata.verifyMovingSwipe(initialFrameID: initial, result: result(frameID: next, image: Data([1, 2, 3])), startRowY: 200, endRowY: 150)
        XCTAssertEqual(metadata.motionVerified, true)
        XCTAssertNil(metadata.motionFailure)
    }

    func testSwipeRejectsOldFramesEmptyImagesAndFailedResults() {
        let initial = UUID()
        for returned in [result(frameID: initial, image: Data([1])), result(frameID: UUID(), image: Data()),
                         result(frameID: UUID(), image: nil), result(frameID: UUID(), image: Data([1]), outcome: .failed)] {
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.swipeEvidence(initialFrameID: initial,
                result: returned, startRowY: 200, endRowY: 150)) { error in
                XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .postActionObservationMissing)
            }
        }
        XCTAssertThrowsError(try DebugNetworkRunAcceptance.swipeEvidence(initialFrameID: initial,
            result: .image(Data([1]), mimeType: "image/jpeg"), startRowY: 200, endRowY: 150)) { error in
            XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .invalidFrame)
        }
    }

    func testSwipeRejectsSmallOrNonfiniteUIKitMovement() {
        for end in [200.0, 170, 230, .nan, .infinity] {
            let initial = UUID(), next = UUID()
            let observed = result(frameID: next, image: Data([1, 2, 3]))
            var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
            metadata.recordSwipeReturn(initialFrameID: initial, result: observed, startRowY: 200, endRowY: end)
            XCTAssertEqual(metadata.initialFrameID, initial)
            XCTAssertEqual(metadata.postActionFrameID, next)
            XCTAssertEqual(metadata.postActionImageBytes, 3, "Failed motion must retain the action's actual returned image evidence.")
            XCTAssertEqual(metadata.swipeEndRowYPoints, end.isFinite ? end : nil)
            XCTAssertEqual(metadata.swipeRowDeltaPoints, end.isFinite ? abs(end - 200) : nil)
            XCTAssertNoThrow(try metadata.verifyMovingSwipe(initialFrameID: initial, result: observed, startRowY: 200, endRowY: end),
                "Visual failure must allow normal host completion/retention measurement.")
            XCTAssertEqual(metadata.motionVerified, false)
            XCTAssertEqual(metadata.motionFailure, DebugNetworkRunAcceptance.Failure.swipeDidNotMove.rawValue)
            XCTAssertThrowsError(try DebugNetworkRunAcceptance.swipeEvidence(initialFrameID: initial,
                result: observed, startRowY: 200, endRowY: end)) { error in
                XCTAssertEqual(error as? DebugNetworkRunAcceptance.Failure, .swipeDidNotMove)
            }
        }
    }

    func testMetadataPreservesRawHIDReleaseSeparatelyFromLocalPolicyAndRetention() throws {
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        metadata.route = DeviceConnectionMethod.bluetoothBoard.rawValue
        metadata.cleanupConfirmed = false
        metadata.cleanupLocallyAccepted = DeviceRunCleanup.acceptsRelease(confirmed: false, method: .bluetoothBoard)
        metadata.retentionCheckedBeforeTeardown = true
        metadata.hostEngineClosedBeforeTeardown = true
        metadata.hostOwnerReleased = true
        metadata.retainedBluetoothConnected = true
        metadata.retainedScreenSharing = true
        metadata.retainedCalibration = true
        metadata.retainedReady = true
        metadata.scopeBeforeSubmission = TaskScope.control.rawValue
        metadata.runScope = TaskScope.chat.rawValue
        metadata.registeredToolNames = []
        metadata.missingToolName = DeviceToolSpec.screenshot.rawValue
        metadata.touchReceipts = [.init(gesture: .stationary, contactID: 1, type: 0, typeName: DebugNetworkRunAcceptance.touchTypeName(.direct),
                                       phase: "began", uptime: 1, receivedUptime: 1, x: 10, y: 20)]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        XCTAssertEqual(json["cleanupConfirmed"] as? Bool, false)
        XCTAssertEqual(json["cleanupLocallyAccepted"] as? Bool, true)
        XCTAssertEqual(json["retentionCheckedBeforeTeardown"] as? Bool, true)
        XCTAssertEqual(json["retainedCalibration"] as? Bool, true)
        XCTAssertEqual(json["scopeBeforeSubmission"] as? String, TaskScope.control.rawValue)
        XCTAssertEqual(json["runScope"] as? String, TaskScope.chat.rawValue)
        XCTAssertEqual(json["registeredToolNames"] as? [String], [])
        XCTAssertEqual(json["missingToolName"] as? String, DeviceToolSpec.screenshot.rawValue)
        XCTAssertEqual(json["modelRequests"] as? Int, 0)
        XCTAssertEqual(json["realAI"] as? Bool, false)
        XCTAssertEqual(json["realPiRuntime"] as? Bool, false)
        let touches = try XCTUnwrap(json["touchReceipts"] as? [[String: Any]])
        XCTAssertEqual(touches.first?["gesture"] as? String, "stationary")
        XCTAssertEqual(touches.first?["contactID"] as? Int, 1)
        XCTAssertEqual(touches.first?["typeName"] as? String, "direct")
        XCTAssertNil(json["content"])
        XCTAssertNil(json["image"])
        XCTAssertNil(json["credentials"])
    }

    func testReadinessTraceKeepsSetupAndRecentChangesWithoutRepeatingStablePolls() {
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        var state = DebugNetworkRunAcceptance.ReadinessState()
        state.status = "ready"; state.pointerVerified = true
        metadata.recordReadiness(phase: "setup_ready", state: state, uptime: 1)
        metadata.recordReadiness(phase: "stable_poll", state: state, uptime: 2)
        XCTAssertEqual(metadata.readiness.count, 1)
        for index in 0..<40 {
            state.pointerVerified = index.isMultiple(of: 2)
            metadata.recordReadiness(phase: "probe_\(index)", state: state, force: true, uptime: Double(index + 3))
        }
        XCTAssertEqual(metadata.readiness.count, 32)
        XCTAssertEqual(metadata.readiness.first?.phase, "setup_ready")
        XCTAssertEqual(metadata.readiness.last?.phase, "probe_39")
        XCTAssertEqual(metadata.readiness.last?.state.pointerVerified, false)
    }

    func testReadinessReasonsAndPayloadExposeOnlyControlledMetadata() throws {
        XCTAssertEqual(DebugNetworkRunAcceptance.readinessReasonCode(DeviceControlError.staleFrame.localizedDescription), "staleFrame")
        XCTAssertEqual(DebugNetworkRunAcceptance.readinessReasonCode("untrusted private text"), "unclassified")
        var metadata = DebugNetworkRunAcceptance.Metadata(sessionID: UUID())
        var state = DebugNetworkRunAcceptance.ReadinessState()
        state.statusReasonCode = DebugNetworkRunAcceptance.readinessReasonCode("untrusted private text")
        state.screenSessionChangedFromSetup = true; state.screenGeometryChangedFromSetup = false
        state.operationChangedFromSetup = true; state.owner = "none"
        metadata.recordReadiness(phase: "before_teardown", state: state)
        let encoded = try JSONEncoder().encode(metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let samples = try XCTUnwrap(json["readiness"] as? [[String: Any]])
        let saved = try XCTUnwrap(samples.first?["state"] as? [String: Any])
        XCTAssertEqual(saved["statusReasonCode"] as? String, "unclassified")
        XCTAssertEqual(saved["screenSessionChangedFromSetup"] as? Bool, true)
        XCTAssertNil(saved["screenSessionID"])
        XCTAssertNil(saved["operationID"])
        XCTAssertNil(saved["unavailableReason"])
        XCTAssertNil(saved["image"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("untrusted private text"))
    }

    func testSetupCannotBecomeStableWhileCalibrationModalOrLeaseStillExists() {
        var gate = DebugNetworkRunAcceptance.StabilityGate<Int>()
        // Ready calibration with a presented/dismissing modal remains ineligible.
        XCTAssertFalse(gate.update(eligible: false, value: 1, uptime: 0))
        XCTAssertFalse(gate.update(eligible: false, value: 1, uptime: 10))
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 11))
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 11.9))
        // A recreated setup owner resets the full stability interval.
        XCTAssertFalse(gate.update(eligible: false, value: 1, uptime: 12))
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 12.1))
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 13))
        XCTAssertTrue(gate.update(eligible: true, value: 1, uptime: 13.1))
    }

    func testSetupStabilityResetsOnSessionIdentityChangeAndLostReadiness() {
        var gate = DebugNetworkRunAcceptance.StabilityGate<Int>()
        XCTAssertFalse(gate.update(eligible: true, value: 1, uptime: 0))
        XCTAssertFalse(gate.update(eligible: true, value: 2, uptime: 1))
        XCTAssertFalse(gate.update(eligible: true, value: 2, uptime: 1.9))
        XCTAssertTrue(gate.update(eligible: true, value: 2, uptime: 2))
        XCTAssertFalse(gate.update(eligible: false, value: 2, uptime: 3))
        XCTAssertFalse(gate.update(eligible: true, value: 2, uptime: 4))
        XCTAssertTrue(gate.update(eligible: true, value: 2, uptime: 5))
    }

    private func bluetoothArguments(kind: String = "foregroundSwipe") -> [String] {
        ["--network-run-acceptance", "--network-run-route", "bluetoothBoard", "--network-run-case", kind]
    }
    private func result(frameID: UUID, image: Data?, outcome: AgentToolOutcome = .succeeded) -> AgentToolResult {
        var content: [AgentToolContent] = [.text("frameId=\(frameID.uuidString); width=100; height=200;")]
        if let image { content.append(.image(data: image, mimeType: "image/jpeg")) }
        return AgentToolResult(content: content, outcome: outcome)
    }
}

private actor RestrictedBLEAcceptanceActuator: DeviceFixtureActuator {
    var fixtureObservedFrameID: UUID?
    var fixtureGeometry: DeviceFrameGeometry?
    func status() async -> DeviceStatus { .ready(capabilities: [.screenshot, .swipe]) }
}
#endif
