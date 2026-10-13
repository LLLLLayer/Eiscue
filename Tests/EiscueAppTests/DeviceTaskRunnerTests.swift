import EiscueDeviceKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class DeviceTaskRunnerTests: XCTestCase {
    func testTypedActionAutomaticallyVerifiesAndReturnsItsNewFrame() async throws {
        let controller = RunnerDeviceController()
        var phases: [DeviceTaskPhase] = []
        var presentation: [String] = []
        let runner = DeviceTaskRunner(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                                     log: { _, _ in }, onUnknown: {},
                                     onObservationWillCapture: { presentation.append("hold") },
                                     onActionFinished: { presentation.append("release") },
                                     onPhaseChanged: { phases.append($0) })
        let first = try observation(await runner.step(.observe))
        let result = try await runner.step(.action(.tap(.init(x: 10, y: 20)), frameID: first.screenshot.frameID))
        guard case .action(let verification) = result else { return XCTFail("Input must include its automatic verification.") }
        XCTAssertNotEqual(first.screenshot.frameID, verification.screenshot.frameID)
        XCTAssertTrue(verification.feedback.contains("1 identical submissions"))
        XCTAssertEqual(presentation, ["hold", "release", "hold"])
        XCTAssertEqual(phases, [.observing, .deciding, .executing, .verifying, .deciding])
        let counts = await controller.counts()
        XCTAssertEqual(counts.captures, 2)
        XCTAssertEqual(counts.actions, 1)
    }

    func testEveryActionRequiresCurrentObservationIncludingHomeAndLaunch() async throws {
        let controller = RunnerDeviceController()
        let runner = makeRunner(controller)
        for action in [DeviceAction.home, .launchApplication("com.apple.Preferences"), .pressKey(.search)] {
            await rejected(makeRunner(controller), .action(action, frameID: UUID()), as: .frame)
        }
        let first = try observation(await runner.step(.observe))
        _ = try await runner.step(.action(.home, frameID: first.screenshot.frameID))
        await rejected(runner, .action(.home, frameID: first.screenshot.frameID), as: .frame)
        let second = try observation(await runner.step(.observe))
        _ = try await runner.step(.action(.launchApplication("com.apple.Preferences"), frameID: second.screenshot.frameID))
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 2)
        XCTAssertEqual(counts.captures, 4)
    }

    func testTypedCallersCannotBypassScopeOrCapabilities() async throws {
        let controller = RunnerDeviceController()
        let chat = makeRunner(controller, scope: .chat)
        await rejected(chat, .observe, as: .scope)
        await rejected(chat, .listApplications, as: .scope)
        let observe = makeRunner(controller, scope: .observe)
        let frame = try observation(await observe.step(.observe))
        await rejected(observe, .action(.home, frameID: frame.screenshot.frameID), as: .scope)
        let restricted = makeRunner(controller, capabilities: [.screenshot])
        let restrictedFrame = try observation(await restricted.step(.observe))
        await rejected(restricted, .action(.tap(.init(x: 1, y: 1)), frameID: restrictedFrame.screenshot.frameID), as: .scope)
        await rejected(restricted, .listApplications, as: .scope)
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 0)
        XCTAssertEqual(counts.lists, 0)
    }

    func testTypedCoordinatesAndArgumentsAreValidatedBeforeSending() async throws {
        let controller = RunnerDeviceController()
        let runner = makeRunner(controller)
        let invalid: [DeviceAction] = [
            .tap(.init(x: .nan, y: 0)), .tap(.init(x: 390, y: 2)), .tap(.init(x: 0, y: -1)),
            .swipe(from: .init(x: 1, y: 1), to: .init(x: 2, y: 844), duration: 0.5),
            .swipe(from: .init(x: 1, y: 1), to: .init(x: 2, y: 2), duration: .infinity),
            .typeText(""), .typeText(String(repeating: "中", count: 3000)),
            .launchApplication("com.apple.Preferences;rm")
        ]
        for action in invalid {
            let frame = try observation(await runner.step(.observe)).screenshot.frameID
            await rejected(runner, .action(action, frameID: frame), as: .arguments)
        }
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 0)
        let frame = try observation(await runner.step(.observe)).screenshot.frameID
        _ = try await runner.step(.action(.tap(.init(x: 389, y: 843)), frameID: frame))
    }

    func testRejectedDecisionInvalidatesFrameWhenItReleasesPresentation() async throws {
        let controller = RunnerDeviceController()
        let runner = makeRunner(controller)
        let frame = try observation(await runner.step(.observe)).screenshot.frameID
        await rejected(runner, .action(.tap(.init(x: -1, y: 0)), frameID: frame), as: .arguments)
        await rejected(runner, .action(.tap(.init(x: 1, y: 1)), frameID: frame), as: .frame)
        let fresh = try observation(await runner.step(.observe)).screenshot.frameID
        _ = try await runner.step(.action(.tap(.init(x: 1, y: 1)), frameID: fresh))
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 1)
        XCTAssertEqual(counts.captures, 3)
    }

    func testMalformedAdapterDecisionsShareFramePauseAndReleaseBoundary() async throws {
        let controller = RunnerDeviceController()
        var held = false
        let runner = DeviceTaskRunner(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                                     log: { _, _ in }, onUnknown: {}, onObservationWillCapture: { held = true },
                                     onActionFinished: { held = false })
        for count in 1...3 {
            _ = try await runner.step(.observe)
            XCTAssertTrue(held)
            do { try await runner.rejectInvalidDecision(.frame) }
            catch {
                if count < 3 { guard case .frame = error as? DeviceTaskError else { return XCTFail("Expected malformed frame rejection.") } }
                else { guard case .paused = error as? DeviceTaskError else { return XCTFail("Expected repeated frame pause.") } }
            }
            XCTAssertFalse(held)
        }
        XCTAssertEqual(runner.pauseReason, .staleFrames)
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 0)
    }

    func testFinalVerificationIsReservedBeforeAnyInput() async throws {
        let blockedController = RunnerDeviceController()
        let blocked = makeRunner(blockedController, maxOperations: 2)
        let frame = try observation(await blocked.step(.observe)).screenshot.frameID
        await rejected(blocked, .action(.home, frameID: frame), as: .budget)
        XCTAssertEqual(blocked.phase, .paused)
        let blockedCounts = await blockedController.counts()
        XCTAssertEqual(blockedCounts.actions, 0)

        let controller = RunnerDeviceController()
        let runner = makeRunner(controller, maxOperations: 3)
        let first = try observation(await runner.step(.observe)).screenshot.frameID
        _ = try await runner.step(.action(.home, frameID: first))
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 1)
        XCTAssertEqual(counts.captures, 2)
        await rejected(runner, .observe, as: .budget)
    }

    func testFailedVerificationPausesKnownSubmittedActionWithoutRetrying() async throws {
        let controller = RunnerDeviceController(captureFailures: [2])
        let runner = makeRunner(controller)
        let first = try observation(await runner.step(.observe)).screenshot.frameID
        await rejected(runner, .action(.home, frameID: first), as: .paused(""))
        XCTAssertEqual(runner.phase, .paused)
        XCTAssertEqual(runner.pauseReason, .verificationUnavailable)
        XCTAssertFalse(runner.hasUnknownOutcome)
        await rejected(runner, .observe, as: .stopped)
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 1)
        XCTAssertEqual(counts.captures, 2)
    }

    func testFailedInitialObservationDoesNotImplySubmittedAction() async throws {
        let controller = RunnerDeviceController(captureFailures: [1])
        let runner = makeRunner(controller)
        do { _ = try await runner.step(.observe); XCTFail("Expected a failed capture.") }
        catch { XCTAssertEqual(error as? DeviceControlError, .notConnected) }
        XCTAssertNil(runner.pauseReason)
        XCTAssertFalse(runner.hasUnknownOutcome)
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 0)
    }

    func testCancellationDuringVerificationNeverReturnsSuccessOrNextFrame() async throws {
        let controller = RunnerDeviceController()
        var observations = 0
        let runner = DeviceTaskRunner(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                                     log: { _, _ in }, onUnknown: {}, onObservationWillCapture: {
            observations += 1
            if observations == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let first = try observation(await runner.step(.observe)).screenshot.frameID
        let operation = Task { try await runner.step(.action(.home, frameID: first)) }
        do { _ = try await operation.value; XCTFail("Cancelled verification must not report success.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(runner.phase, .stopped)
        await rejected(runner, .observe, as: .stopped)
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 1)
        XCTAssertEqual(counts.captures, 1)
    }

    func testUnknownDeliveryStopsWithoutAnAutomaticObservation() async throws {
        let controller = RunnerDeviceController(actionFailure: .deliveryUnknown("mock"))
        let notified = expectation(description: "Unknown delivery stops the host")
        let runner = DeviceTaskRunner(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                                     log: { _, _ in }, onUnknown: { notified.fulfill() })
        let first = try observation(await runner.step(.observe)).screenshot.frameID
        do { _ = try await runner.step(.action(.home, frameID: first)); XCTFail("Unknown input cannot be retried.") }
        catch { XCTAssertTrue((error as? DeviceControlError)?.isDeliveryUnknown == true) }
        await fulfillment(of: [notified], timeout: 1)
        XCTAssertTrue(runner.hasUnknownOutcome)
        await rejected(runner, .observe, as: .stopped)
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 1)
        XCTAssertEqual(counts.captures, 1)
    }

    func testStorageFailureAfterActionStopsEvenIfVerificationWouldWork() async throws {
        let controller = RunnerDeviceController()
        let notified = expectation(description: "Lost durable acknowledgment stops the host")
        let runner = DeviceTaskRunner(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                                     log: { kind, _ in if kind == "action.acknowledged" { throw RunnerTestError.storage } },
                                     onUnknown: { notified.fulfill() })
        let first = try observation(await runner.step(.observe)).screenshot.frameID
        do { _ = try await runner.step(.action(.home, frameID: first)); XCTFail("Expected storage failure.") }
        catch { XCTAssertEqual(error as? RunnerTestError, .storage) }
        await fulfillment(of: [notified], timeout: 1)
        XCTAssertTrue(runner.hasUnknownOutcome)
        await rejected(runner, .observe, as: .stopped)
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 1)
        XCTAssertEqual(counts.captures, 1)
    }

    func testStorageFailureBeforeDispatchAlsoClosesTheSession() async throws {
        let controller = RunnerDeviceController()
        let notified = expectation(description: "Lost preflight journal stops the host")
        let runner = DeviceTaskRunner(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                                     log: { kind, _ in if kind == "action.prepared" { throw RunnerTestError.storage } },
                                     onUnknown: { notified.fulfill() })
        let first = try observation(await runner.step(.observe)).screenshot.frameID
        do { _ = try await runner.step(.action(.home, frameID: first)); XCTFail("Expected storage failure.") }
        catch { XCTAssertEqual(error as? RunnerTestError, .storage) }
        await fulfillment(of: [notified], timeout: 1)
        await rejected(runner, .observe, as: .stopped)
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 0)
    }

    func testUnchangedActionsPauseBeforeThirdInputUsingAutomaticObservations() async throws {
        let controller = RunnerDeviceController()
        let runner = makeRunner(controller)
        var frame = try observation(await runner.step(.observe)).screenshot.frameID
        for count in 1...2 {
            let result = try observation(await runner.step(.action(.home, frameID: frame)))
            XCTAssertTrue(result.feedback.contains("\(count) identical submissions"))
            frame = result.screenshot.frameID
        }
        await rejected(runner, .action(.home, frameID: frame), as: .paused(""))
        XCTAssertEqual(runner.pauseReason, .noProgress)
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 2)
        XCTAssertEqual(counts.captures, 3)
    }

    func testRepeatedControllerFrameRejectionsPauseWithoutVerificationOrUnknownDelivery() async throws {
        let controller = RunnerDeviceController(actionFailure: .staleFrame)
        let runner = makeRunner(controller)
        for index in 1...3 {
            let frame = try observation(await runner.step(.observe)).screenshot.frameID
            do { _ = try await runner.step(.action(.home, frameID: frame)); XCTFail("Expected stale frame.") }
            catch {
                if index < 3 { XCTAssertEqual(error as? DeviceControlError, .staleFrame) }
                else { guard case .paused = error as? DeviceTaskError else { return XCTFail("Expected a pause.") } }
            }
        }
        XCTAssertEqual(runner.pauseReason, .staleFrames)
        XCTAssertFalse(runner.hasUnknownOutcome)
        let counts = await controller.counts()
        XCTAssertEqual(counts.captures, 3)
    }

    func testLiveControllerObservationMayHaveAnOlderImageTimestamp() async throws {
        let controller = RunnerDeviceController(imageAge: 120)
        let runner = makeRunner(controller)
        let first = try observation(await runner.step(.observe)).screenshot.frameID
        _ = try await runner.step(.action(.home, frameID: first))
        let counts = await controller.counts()
        XCTAssertEqual(counts.actions, 1, "Freshness belongs to the controller's live heartbeat contract.")
    }

    func testConcurrentDecisionsAreRejectedWhileADeviceOperationIsInFlight() async throws {
        let controller = RunnerDeviceController(suspendCapture: 1)
        let runner = makeRunner(controller)
        let capture = Task { try await runner.step(.observe) }
        while !(await controller.isWaiting()) { await Task.yield() }
        await rejected(runner, .observe, as: .busy)
        await controller.releaseCapture()
        _ = try await capture.value
        let counts = await controller.counts()
        XCTAssertEqual(counts.captures, 1)
    }

    private func makeRunner(_ controller: RunnerDeviceController, scope: TaskScope = .control,
                            capabilities: Set<DeviceCapability> = Set(DeviceCapability.allCases),
                            maxOperations: Int = 30) -> DeviceTaskRunner {
        DeviceTaskRunner(capabilities: capabilities, client: DeviceClient(controller: controller), scope: scope,
                         timeoutSeconds: 30, maxOperations: maxOperations, log: { _, _ in }, onUnknown: {})
    }

    private func observation(_ result: DeviceStepResult) throws -> DeviceObservation {
        switch result {
        case .observation(let value), .action(let value): value
        case .applications: throw RunnerTestError.unexpectedResult
        }
    }

    private func rejected(_ runner: DeviceTaskRunner, _ decision: DeviceDecision, as expected: DeviceTaskError,
                          file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await runner.step(decision); XCTFail("Expected rejection.", file: file, line: line) }
        catch {
            guard let actual = error as? DeviceTaskError else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
            switch (expected, actual) {
            case (.stopped, .stopped), (.expired, .expired), (.scope, .scope), (.frame, .frame),
                 (.arguments, .arguments), (.busy, .busy), (.budget, .budget), (.paused, .paused): break
            default: XCTFail("Unexpected device task error: \(actual)", file: file, line: line)
            }
        }
    }
}

private enum RunnerTestError: Error, Equatable { case storage, unexpectedResult }

private actor RunnerDeviceController: DeviceController {
    let captureFailures: Set<Int>
    let actionFailure: DeviceControlError?
    let imageAge: TimeInterval
    let suspendCapture: Int?
    private var captures = 0
    private var actions = 0
    private var lists = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(captureFailures: Set<Int> = [], actionFailure: DeviceControlError? = nil,
         imageAge: TimeInterval = 0, suspendCapture: Int? = nil) {
        self.captureFailures = captureFailures; self.actionFailure = actionFailure
        self.imageAge = imageAge; self.suspendCapture = suspendCapture
    }

    func status() async -> DeviceStatus { .ready(capabilities: Set(DeviceCapability.allCases)) }
    func captureScreenshot() async throws -> DeviceScreenshot {
        captures += 1
        if captures == suspendCapture { await withCheckedContinuation { continuation = $0 } }
        if captureFailures.contains(captures) { throw DeviceControlError.notConnected }
        return DeviceScreenshot(capturedAt: Date().addingTimeInterval(-imageAge), width: 390, height: 844,
                                mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
    }
    func tap(at point: DevicePoint, frameID: UUID) async throws { try performAction() }
    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws { try performAction() }
    func typeText(_ text: String, frameID: UUID) async throws { try performAction() }
    func pressKey(_ key: DeviceKeyboardAction, frameID: UUID) async throws { try performAction() }
    func home() async throws { try performAction() }
    func launchApplication(bundleID: String) async throws { try performAction() }
    func listApplications() async throws -> [DeviceApplication] { lists += 1; return [] }
    private func performAction() throws { actions += 1; if let actionFailure { throw actionFailure } }
    func counts() -> (captures: Int, actions: Int, lists: Int) { (captures, actions, lists) }
    func isWaiting() -> Bool { continuation != nil }
    func releaseCapture() { continuation?.resume(); continuation = nil }
}
