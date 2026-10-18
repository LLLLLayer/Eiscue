import EiscueAgentKit
import EiscueDeviceKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class DeviceRunCleanupTests: XCTestCase {
    func testAcceptedModelFailureBeforeToolsReleasesInputWithoutDisconnecting() async throws {
        let controller = CleanupDeviceController()
        let session = makeSession(controller)

        try await finish(makeRun(), session: session, controller: controller)

        XCTAssertFalse(session.hasStartedExecution)
        let events = await controller.events
        XCTAssertEqual(events, ["release"])
    }

    func testScreenshotExecutionDisconnectsEvenWhenItsPreparedLogCannotBeSaved() async throws {
        for failLog in [false, true] {
            let controller = CleanupDeviceController()
            let session = DeviceToolSession(client: DeviceClient(actuator: controller), scope: .control,
                                            timeoutSeconds: 30, log: { kind, _ in
                if failLog && kind == "observation.prepared" { throw CleanupFixtureError.persistence }
            }, onUnknown: {})
            let screenshot = try XCTUnwrap(session.tools.first { $0.name == "device_screenshot" })
            do {
                _ = try await screenshot.execute([:])
                XCTAssertFalse(failLog, "The prepared-log failure must reach the caller.")
            } catch {
                XCTAssertTrue(failLog)
                XCTAssertEqual(error as? AgentToolError, .outcomeUnknown)
            }

            // Deliberately omit activity events: execution may precede event delivery.
            XCTAssertTrue(session.hasStartedExecution)
            try await finish(makeRun(), session: session, controller: controller)
            let events = await controller.events
            XCTAssertEqual(events, failLog ? ["disconnect"] : ["screenshot", "disconnect"])
        }
    }

    func testUnsafeOrUnconfirmedFailuresAlwaysDisconnect() async throws {
        enum Reason: CaseIterable {
            case userStop, pendingSubmission
            case runtimeOrStorageFailure, toolStarted, missingSession
        }
        for reason in Reason.allCases {
            let controller = CleanupDeviceController()
            var session: DeviceToolSession? = makeSession(controller)
            var run = makeRun()
            var modelRequestFailed = true
            var stopRequested = false
            switch reason {
            case .userStop: stopRequested = true
            case .pendingSubmission: run.submission = .pending
            case .runtimeOrStorageFailure: modelRequestFailed = false
            case .toolStarted:
                run.activities = [ToolActivity(id: "call-1", name: "device_screenshot")]
            case .missingSession: session = nil
            }

            try await finish(run, modelRequestFailed: modelRequestFailed,
                             session: session, stopRequested: stopRequested, controller: controller)

            let events = await controller.events
            XCTAssertEqual(events, ["disconnect"], "Unexpected retention for \(reason)")
        }
    }

    func testNormalCompletionKeepsConnectionUnlessAutomaticDisconnectIsSelected() async throws {
        for disconnectAfterTask in [false, true] {
            let controller = CleanupDeviceController()
            var run = makeRun()
            run.state = .completed
            try await finish(run, disconnectAfterTask: disconnectAfterTask, modelRequestFailed: false,
                             session: makeSession(controller), controller: controller)
            let events = await controller.events
            XCTAssertEqual(events, disconnectAfterTask ? ["disconnect"] : ["release"])
        }
    }

    func testFailedInputReleaseDisconnectsAndPropagatesTheFailure() async throws {
        let controller = CleanupDeviceController(failRelease: true)
        do {
            try await finish(makeRun(), session: makeSession(controller), controller: controller)
            XCTFail("An unconfirmed input release cannot retain the connection.")
        } catch {
            XCTAssertEqual(error as? DeviceControlError, .deliveryUnknown("Fixture release failed"))
        }

        let events = await controller.events
        XCTAssertEqual(events, ["release", "disconnect"])
    }

    func testAcceptedPauseReleasesInputBeforeRetainingConnection() async throws {
        for reason in [RunPauseReason.toolLimit, .noProgress, .verification] {
            let controller = CleanupDeviceController()
            var run = makeRun()
            run.state = .paused; run.pauseReason = reason
            try await finish(run, modelRequestFailed: false, session: makeSession(controller), controller: controller)
            let events = await controller.events
            XCTAssertEqual(events, ["release"])
        }
    }

    func testConnectionLossPauseDisconnectsInsteadOfRetainingFailedTransport() async throws {
        let controller = CleanupDeviceController()
        var run = makeRun()
        run.state = .paused; run.pauseReason = .connection
        try await finish(run, modelRequestFailed: false, session: makeSession(controller), controller: controller)
        let events = await controller.events
        XCTAssertEqual(events, ["disconnect"])
    }

    func testPauseCannotRetainAnUnconfirmedReleaseOrUserStop() async throws {
        let failingController = CleanupDeviceController(failRelease: true)
        var run = makeRun()
        run.state = .paused; run.pauseReason = .toolLimit
        do {
            try await finish(run, modelRequestFailed: false, session: makeSession(failingController), controller: failingController)
            XCTFail("Paused tasks still require a confirmed input release.")
        } catch {
            XCTAssertEqual(error as? DeviceControlError, .deliveryUnknown("Fixture release failed"))
        }
        let failureEvents = await failingController.events
        XCTAssertEqual(failureEvents, ["release", "disconnect"])

        let stoppedController = CleanupDeviceController()
        try await finish(run, modelRequestFailed: false, session: makeSession(stoppedController),
                         stopRequested: true, controller: stoppedController)
        let stopEvents = await stoppedController.events
        XCTAssertEqual(stopEvents, ["disconnect"])
    }

    func testIncompletePauseRecordDoesNotRetainConnection() async throws {
        for missingReason in [true, false] {
            let controller = CleanupDeviceController()
            var run = makeRun()
            run.state = .paused
            run.pauseReason = missingReason ? nil : .toolLimit
            run.submission = missingReason ? .accepted : .pending
            try await finish(run, modelRequestFailed: false, session: makeSession(controller), controller: controller)
            let events = await controller.events
            XCTAssertEqual(events, ["disconnect"])
        }
    }

    func testChatCleanupNeverTouchesDeviceConnection() async throws {
        for state in [RunState.failed, .completed, .paused, .interrupted] {
            let controller = CleanupDeviceController()
            var run = makeRun(scope: .chat)
            run.state = state
            try await finish(run, session: makeSession(controller, scope: .chat),
                             stopRequested: true, controller: controller)
            let events = await controller.events
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testUnconfirmedDisconnectFailsCleanup() async throws {
        for method in [DeviceConnectionMethod.localVPN, .usbBoard] {
            let controller = CleanupDeviceController(confirmDisconnect: false)
            var run = makeRun()
            run.state = .outcomeUnknown
            run.stopCause = .outcomeUnknown(toolName: "device_swipe")
            do {
                try await finish(run, method: method, modelRequestFailed: false, session: makeSession(controller),
                                 stopRequested: true, controller: controller)
                XCTFail("A local close must not count as confirmed network cleanup.")
            } catch {
                XCTAssertTrue(error is DeviceSession.Failure)
            }
            let events = await controller.events
            XCTAssertEqual(events, ["disconnect"])
        }
    }

    func testHIDUnconfirmedDisconnectIsAcceptedForCompletionAndStop() async throws {
        for stopped in [false, true] {
            let controller = CleanupDeviceController(confirmDisconnect: false)
            var run = makeRun()
            run.state = stopped ? .interrupted : .completed
            try await finish(run, method: .bluetoothBoard, disconnectAfterTask: !stopped, modelRequestFailed: false,
                             session: makeSession(controller), stopRequested: stopped, controller: controller)
            let events = await controller.events
            XCTAssertEqual(events, ["disconnect"])
        }
    }

    func testFailedInputReleaseAndUnconfirmedDisconnectPreserveBothCauses() async throws {
        let controller = CleanupDeviceController(failRelease: true, confirmDisconnect: false)
        do {
            try await finish(makeRun(), session: makeSession(controller), controller: controller)
            XCTFail("Both cleanup failures must reach the caller.")
        } catch let failure as DeviceRunCleanup.Failures {
            XCTAssertEqual(failure.inputRelease as? DeviceControlError, .deliveryUnknown("Fixture release failed"))
            XCTAssertEqual(failure.disconnect.localizedDescription, DeviceSession.Failure.releaseUnconfirmed.localizedDescription)
            XCTAssertEqual(failure.localizedDescription, failure.inputRelease.localizedDescription + "\n" + failure.disconnect.localizedDescription)
        }
        let events = await controller.events
        XCTAssertEqual(events, ["release", "disconnect"])
    }

    func testHIDUnconfirmedDisconnectStillPropagatesInputReleaseFailure() async throws {
        let controller = CleanupDeviceController(failRelease: true, confirmDisconnect: false)
        do {
            try await finish(makeRun(), method: .bluetoothBoard, session: makeSession(controller), controller: controller)
            XCTFail("HID cleanup must retain the input release failure.")
        } catch {
            XCTAssertEqual(error as? DeviceControlError, .deliveryUnknown("Fixture release failed"))
        }
        let events = await controller.events
        XCTAssertEqual(events, ["release", "disconnect"])
    }

    private func makeRun(scope: TaskScope = .control) -> RunRecord {
        var run = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(),
                            scope: scope, model: "fixture", skill: nil, state: .failed, detail: "", events: [])
        run.submission = .accepted
        return run
    }

    private func makeSession(_ controller: CleanupDeviceController, scope: TaskScope = .control) -> DeviceToolSession {
        DeviceToolSession(client: DeviceClient(actuator: controller), scope: scope,
                          timeoutSeconds: 30, log: { _, _ in }, onUnknown: {})
    }

    private func finish(_ run: RunRecord, method: DeviceConnectionMethod = .localVPN, disconnectAfterTask: Bool = false,
                        modelRequestFailed: Bool = true, session: DeviceToolSession?, stopRequested: Bool = false,
                        controller: CleanupDeviceController) async throws {
        let client = DeviceClient(actuator: controller)
        try await DeviceRunCleanup.finish(run: run, method: method, disconnectAfterTask: disconnectAfterTask, modelRequestFailed: modelRequestFailed,
                                          deviceTools: session, stopRequested: stopRequested,
                                          finishConnection: { try await client.finishTask() },
                                          disconnect: { await client.disconnectAndConfirmRelease() })
    }
}

private enum CleanupFixtureError: Error, Equatable { case persistence }

private actor CleanupDeviceController: DeviceFixtureActuator {
    var fixtureObservedFrameID: UUID?
    var fixtureGeometry: DeviceFrameGeometry?
    private(set) var events: [String] = []
    private let failRelease: Bool
    private let confirmDisconnect: Bool

    init(failRelease: Bool = false, confirmDisconnect: Bool = true) {
        self.failRelease = failRelease; self.confirmDisconnect = confirmDisconnect
    }

    func status() async -> DeviceStatus { .ready(capabilities: [.screenshot]) }
    func captureScreenshot() async throws -> DeviceScreenshot {
        events.append("screenshot")
        return DeviceScreenshot(width: 390, height: 844, mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
    }
    func fixtureReleaseInput() async throws {
        events.append("release")
        if failRelease { throw DeviceControlError.deliveryUnknown("Fixture release failed") }
    }
    func fixtureDisconnect() async { events.append("disconnect") }
    func fixtureDisconnectAndConfirmRelease() async -> Bool {
        await fixtureDisconnect(); return confirmDisconnect
    }
}
