import EiscueAgentKit
import EiscueDeviceCore
import Foundation
import XCTest
@testable import Eiscue

@MainActor final class CoordinatorControlRegressionTests: XCTestCase {
    func testCompletedControlReleasesInputAndRetainsSelectedConnection() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.model.draft = "Do the task"
        await fixture.model.sendMessage()
        let events = await fixture.actuator.events
        XCTAssertEqual(events, ["release"])
        XCTAssertEqual(fixture.model.runs.first?.scope, .control)
        XCTAssertEqual(fixture.model.runs.first?.state, .completed)
        XCTAssertNil(fixture.model.runs.first?.cleanupFailure)
        XCTAssertTrue(fixture.model.isDeviceReady)
        XCTAssertEqual(fixture.model.activeDeviceConnectionMethod, .localVPN)
        XCTAssertNil(fixture.model.deviceSession.owner)
        XCTAssertFalse(fixture.model.isRunning)
        XCTAssertEqual(fixture.background.begins, 1)
        XCTAssertEqual(fixture.background.successes, [true])
    }

    func testCompletedHIDControlAcceptsUnconfirmedAutomaticDisconnect() async throws {
        for disconnectAfterTask in [false, true] {
            let fixture = try ControlCoordinatorFixture(releaseConfirmed: false, method: .bluetoothBoard)
            defer { fixture.remove() }
            fixture.model.disconnectAfterTask = disconnectAfterTask
            fixture.factory.running.onStart = { _ in fixture.model.sceneChanged(.background) }
            fixture.model.draft = "Complete HID task"

            await fixture.model.sendMessage()

            let completed = try XCTUnwrap(fixture.model.runs.first)
            let persisted = try await fixture.model.journal.load().records.first
            XCTAssertEqual(completed.state, .completed)
            XCTAssertNil(completed.cleanupFailure)
            XCTAssertEqual(persisted?.state, .completed)
            XCTAssertNil(persisted?.cleanupFailure)
            XCTAssertEqual(fixture.background.successes, [true])
            XCTAssertEqual(fixture.notifications.states, [.completed])
            XCTAssertFalse(fixture.model.deviceSession.hasUnconfirmedRelease)
            XCTAssertEqual(fixture.model.isDeviceReady, !disconnectAfterTask)
            XCTAssertEqual(fixture.model.activeDeviceConnectionMethod, disconnectAfterTask ? nil : .bluetoothBoard)
            XCTAssertNil(fixture.model.deviceSession.owner)
            XCTAssertNil(fixture.model.activeRun)
            let events = await fixture.actuator.events
            XCTAssertEqual(events, disconnectAfterTask ? ["disconnect"] : ["release"])
        }
    }

    func testUserStopAcceptsCapturedHIDUnconfirmedReleaseAfterClientReplacement() async throws {
        for replaceClient in [false, true] {
            let fixture = try ControlCoordinatorFixture(releaseConfirmed: false, method: .bluetoothBoard)
            defer { fixture.remove() }
            let replacement = CoordinatorActuator()
            fixture.factory.running.holdStream = true
            fixture.factory.running.onStart = { _ in
                fixture.model.sceneChanged(.background)
                if replaceClient {
                    fixture.model.deviceClient = DeviceClient(actuator: replacement)
                    fixture.model.activeDeviceConnectionMethod = .usbBoard
                    fixture.model.activeDeviceControlBackend = .xcTest
                }
            }
            fixture.model.draft = "Stop HID task"
            let work = Task { await fixture.model.sendMessage() }
            try await coordinatorEventually { fixture.factory.running.requests.count == 1 }
            let runID = try XCTUnwrap(fixture.model.activeRun?.id)

            let result = await fixture.model.runCoordinator.stopAndWait(runID: runID)
            let completed = try XCTUnwrap(result)
            await work.value

            let persisted = try await fixture.model.journal.load().records.first
            XCTAssertEqual(completed.state, .interrupted)
            XCTAssertEqual(completed.stopCause, .userRequested)
            XCTAssertNil(completed.cleanupFailure)
            XCTAssertEqual(persisted?.state, .interrupted)
            XCTAssertNil(persisted?.cleanupFailure)
            XCTAssertEqual(fixture.notifications.states, [.interrupted])
            XCTAssertFalse(fixture.model.deviceSession.hasUnconfirmedRelease)
            XCTAssertEqual(fixture.model.activeDeviceConnectionMethod, replaceClient ? .usbBoard : nil)
            XCTAssertNil(fixture.model.deviceSession.owner)
            XCTAssertNil(fixture.model.activeRun)
            let events = await fixture.actuator.events
            let replacementEvents = await replacement.events
            XCTAssertEqual(events, ["disconnect", "disconnect"])
            XCTAssertTrue(replacementEvents.isEmpty)
        }
    }

    func testAutomaticDisconnectUsesCapturedRouteAfterClientReplacement() async throws {
        for method in [DeviceConnectionMethod.bluetoothBoard, .localVPN] {
            let fixture = try ControlCoordinatorFixture(releaseConfirmed: false, method: method)
            defer { fixture.remove() }
            let replacement = CoordinatorActuator()
            let replacementMethod: DeviceConnectionMethod = method == .bluetoothBoard ? .usbBoard : .bluetoothBoard
            fixture.model.disconnectAfterTask = true
            fixture.factory.running.onStart = { _ in
                fixture.model.deviceClient = DeviceClient(actuator: replacement)
                fixture.model.activeDeviceConnectionMethod = replacementMethod
            }
            fixture.model.draft = "Complete captured route task"

            await fixture.model.sendMessage()

            let completed = try XCTUnwrap(fixture.model.runs.first)
            XCTAssertEqual(completed.state, .completed)
            XCTAssertEqual(completed.cleanupFailure, method == .bluetoothBoard ? nil : fixture.model.safeError(DeviceSession.Failure.releaseUnconfirmed))
            XCTAssertEqual(fixture.background.successes, [method == .bluetoothBoard])
            XCTAssertEqual(fixture.model.activeDeviceConnectionMethod, replacementMethod)
            let events = await fixture.actuator.events
            let replacementEvents = await replacement.events
            XCTAssertEqual(events, ["disconnect"])
            XCTAssertTrue(replacementEvents.isEmpty)
        }
    }

    func testInputReleaseAndDisconnectFailuresAreBothRedactedAndPersisted() async throws {
        let releaseFailureMessage = "Fixture input release failed: isolated-coordinator-fixture " + String(repeating: "detail ", count: 180)
        let fixture = try ControlCoordinatorFixture(failRelease: true, releaseConfirmed: false,
                                                   releaseFailureMessage: releaseFailureMessage)
        defer { fixture.remove() }
        fixture.factory.running.onStart = { _ in fixture.model.sceneChanged(.background) }
        fixture.model.draft = "Complete with cleanup failures"

        await fixture.model.sendMessage()

        let completed = try XCTUnwrap(fixture.model.runs.first)
        let persisted = try await fixture.model.journal.load().records.first
        let inputFailure = fixture.model.safeError(DeviceControlError.deliveryUnknown(releaseFailureMessage))
        let expected = inputFailure + "\n" + fixture.model.safeError(DeviceSession.Failure.releaseUnconfirmed)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.cleanupFailure, expected)
        XCTAssertEqual(persisted?.state, .completed)
        XCTAssertEqual(persisted?.cleanupFailure, expected)
        XCTAssertFalse(completed.cleanupFailure?.contains("isolated-coordinator-fixture") ?? true)
        XCTAssertEqual(fixture.background.successes, [false])
        XCTAssertEqual(fixture.notifications.states, [.failed])
        let events = await fixture.actuator.events
        XCTAssertEqual(events, ["release", "disconnect"])
    }

    func testCleanupUsesCapturedClientWhenSelectedClientHasBeenReplaced() async throws {
        for fails in [false, true] {
            let fixture = try ControlCoordinatorFixture(failRelease: fails); defer { fixture.remove() }
            let replacement = CoordinatorActuator()
            fixture.factory.running.onStart = { _ in
                fixture.model.deviceClient = DeviceClient(actuator: replacement)
                fixture.model.activeDeviceConnectionMethod = .usbBoard
                fixture.model.activeDeviceControlBackend = .xcTest
            }
            fixture.model.draft = "Do the task"
            await fixture.model.sendMessage()
            let originalEvents = await fixture.actuator.events
            let replacementEvents = await replacement.events
            XCTAssertEqual(originalEvents, fails ? ["release", "disconnect"] : ["release"])
            XCTAssertEqual(replacementEvents, [], "Final cleanup may affect only the run's captured device.")
            XCTAssertEqual(fixture.model.activeDeviceConnectionMethod, .usbBoard)
            XCTAssertEqual(fixture.model.activeDeviceControlBackend, .xcTest)
            XCTAssertEqual(fixture.model.runs.first?.state, .completed)
            XCTAssertEqual(fixture.model.runs.first?.cleanupFailure != nil, fails)
        }
    }

    func testDeviceCleanupFailureRemainsSeparateFromSuccessfulWork() async throws {
        let fixture = try ControlCoordinatorFixture(failRelease: true); defer { fixture.remove() }
        fixture.model.draft = "Do the task"
        await fixture.model.sendMessage()
        let run = try XCTUnwrap(fixture.model.runs.first)
        XCTAssertEqual(run.state, .completed)
        XCTAssertNotNil(run.cleanupFailure)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
        let events = await fixture.actuator.events
        XCTAssertEqual(events, ["release", "disconnect"])
        let stored = try await fixture.model.journal.load().records.first
        XCTAssertEqual(stored?.state, .completed)
        XCTAssertEqual(stored?.cleanupFailure, run.cleanupFailure)
        XCTAssertEqual(fixture.background.successes, [false], "Failed cleanup must not publish completed progress.")
    }

    func testCompletedControlPersistsUnconfirmedAutomaticDisconnectBeforeEndingActivity() async throws {
        let fixture = try ControlCoordinatorFixture(releaseConfirmed: false); defer { fixture.remove() }
        fixture.model.disconnectAfterTask = true
        fixture.factory.running.onStart = { _ in fixture.model.sceneChanged(.background) }
        let expectedFailure = fixture.model.safeError(DeviceSession.Failure.releaseUnconfirmed)
        var summaryAtActivityEnd: RunRecord?
        fixture.background.onEnd = { runID in
            XCTAssertEqual(fixture.model.deviceSession.owner, .run(runID))
            let summary = fixture.directory.appendingPathComponent("Runs/\(runID.uuidString).json")
            summaryAtActivityEnd = (try? Data(contentsOf: summary)).flatMap { try? JSONDecoder().decode(RunRecord.self, from: $0) }
        }
        fixture.model.draft = "Complete and disconnect"

        await fixture.model.sendMessage()

        let completed = try XCTUnwrap(fixture.model.runs.first)
        let stored = try await fixture.model.journal.load()
        let persisted = try XCTUnwrap(stored.records.first)
        XCTAssertEqual(completed.scope, .control)
        XCTAssertEqual(completed.state, .completed, "Cleanup failure must not rewrite successful work.")
        XCTAssertEqual(completed.cleanupFailure, expectedFailure)
        XCTAssertEqual(persisted.id, completed.id)
        XCTAssertEqual(persisted.state, .completed)
        XCTAssertEqual(persisted.cleanupFailure, expectedFailure)
        XCTAssertNotNil(persisted.endedAt)
        XCTAssertEqual(summaryAtActivityEnd?.cleanupFailure, expectedFailure,
                       "The final failure must be durable before the system activity ends.")
        XCTAssertEqual(fixture.background.successes, [false])
        XCTAssertEqual(fixture.notifications.states, [.failed], "Cleanup failure cannot announce successful work as completed.")
        XCTAssertFalse(fixture.background.isExecuting)
        XCTAssertTrue(fixture.model.deviceSession.hasUnconfirmedRelease)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
        XCTAssertNil(fixture.model.deviceSession.owner)
        XCTAssertNil(fixture.model.activeRun)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertThrowsError(try fixture.model.deviceSession.acquire(.run(UUID())))
        let events = await fixture.actuator.events
        XCTAssertEqual(events, ["disconnect"])
    }

    func testUnknownStopPersistsFailedReleaseEvenWhenFinalDisconnectIsConfirmed() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        // Isolate stop's receipt propagation: the final cleanup later succeeds,
        // so it cannot supply the failure that the stop operation must record.
        await fixture.actuator.setReleaseConfirmations([false, true])
        fixture.factory.running.holdStream = true
        fixture.factory.running.onStart = { _ in fixture.model.sceneChanged(.background) }
        let cause = StopCause.outcomeUnknown(toolName: DeviceToolSpec.swipe.rawValue)
        fixture.factory.running.cancellationOutcome = .stopped(cause)
        let expectedFailure = fixture.model.safeError(DeviceSession.Failure.releaseUnconfirmed)
        var summaryAtActivityEnd: RunRecord?
        fixture.background.onEnd = { runID in
            XCTAssertEqual(fixture.model.deviceSession.owner, .run(runID))
            let summary = fixture.directory.appendingPathComponent("Runs/\(runID.uuidString).json")
            summaryAtActivityEnd = (try? Data(contentsOf: summary)).flatMap { try? JSONDecoder().decode(RunRecord.self, from: $0) }
        }
        fixture.model.draft = "Stop an uncertain swipe"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { fixture.factory.running.requests.count == 1 }
        let runID = try XCTUnwrap(fixture.model.activeRun?.id)

        let result = await fixture.model.runCoordinator.stopAndWait(runID: runID)
        let completed = try XCTUnwrap(result)
        await work.value

        let stored = try await fixture.model.journal.load()
        let persisted = try XCTUnwrap(stored.records.first)
        XCTAssertEqual(completed.state, .outcomeUnknown)
        XCTAssertEqual(completed.stopCause, cause)
        XCTAssertEqual(completed.cleanupFailure, expectedFailure)
        XCTAssertEqual(persisted.id, runID)
        XCTAssertEqual(persisted.state, .outcomeUnknown)
        XCTAssertEqual(persisted.stopCause, cause)
        XCTAssertEqual(persisted.cleanupFailure, expectedFailure)
        XCTAssertEqual(summaryAtActivityEnd?.state, .outcomeUnknown)
        XCTAssertEqual(summaryAtActivityEnd?.cleanupFailure, expectedFailure)
        XCTAssertEqual(fixture.background.successes, [false])
        XCTAssertEqual(fixture.notifications.states, [.outcomeUnknown], "Cleanup failure must retain uncertainty in the terminal notification state.")
        XCTAssertFalse(fixture.background.isExecuting)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
        XCTAssertNil(fixture.model.deviceSession.owner)
        XCTAssertNil(fixture.model.activeRun)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertTrue(fixture.model.interruptedConversationIDs.contains(completed.conversationID))
        let events = await fixture.actuator.events
        XCTAssertEqual(events, ["disconnect", "disconnect"])
    }

    func testUnknownStopAccumulatesAndRedactsReleaseAndEngineCloseFailuresInEitherOrder() async throws {
        for releaseFirst in [true, false] {
            let cancellation = CoordinatorGate(), disconnect = CoordinatorGate()
            let fixture = try ControlCoordinatorFixture(disconnectGate: disconnect); defer { fixture.remove() }
            await fixture.actuator.setReleaseConfirmations([false, true])
            fixture.factory.running.holdStream = true
            fixture.factory.running.cancellationGate = cancellation
            let closeFailure = AgentError.cleanupFailed("Runtime close failed: isolated-coordinator-fixture")
            fixture.factory.running.cancellationFailure = closeFailure
            fixture.factory.running.onStart = { _ in fixture.model.sceneChanged(.background) }
            let cause = StopCause.outcomeUnknown(toolName: DeviceToolSpec.swipe.rawValue)
            fixture.factory.running.cancellationOutcome = .stopped(cause)
            let releaseFailure = fixture.model.safeError(DeviceSession.Failure.releaseUnconfirmed)
            let engineFailure = fixture.model.safeError(closeFailure)
            var summaryAtActivityEnd: RunRecord?
            fixture.background.onEnd = { runID in
                XCTAssertEqual(fixture.model.deviceSession.owner, .run(runID))
                let summary = fixture.directory.appendingPathComponent("Runs/\(runID.uuidString).json")
                summaryAtActivityEnd = (try? Data(contentsOf: summary)).flatMap { try? JSONDecoder().decode(RunRecord.self, from: $0) }
            }
            fixture.model.draft = "Stop with two cleanup failures"
            let work = Task { await fixture.model.sendMessage() }
            try await coordinatorEventually {
                fixture.factory.running.requests.count == 1 && fixture.model.activeRun?.submission == .accepted
            }
            let runID = try XCTUnwrap(fixture.model.activeRun?.id)
            let stopping = Task { await fixture.model.runCoordinator.stopAndWait(runID: runID) }
            addTeardownBlock {
                await cancellation.open(); await disconnect.open()
                _ = await stopping.value; await work.value
            }
            try await coordinatorEventually {
                let disconnectStarted = await fixture.actuator.firstDisconnectStarted
                return fixture.factory.running.cancellations == 1 && disconnectStarted
            }
            if releaseFirst {
                await disconnect.open()
                try await coordinatorEventually { fixture.model.activeRun?.cleanupFailure == releaseFailure }
                await cancellation.open()
            } else {
                await cancellation.open()
                try await coordinatorEventually { fixture.model.activeRun?.cleanupFailure == engineFailure }
                await disconnect.open()
            }
            let result = await stopping.value
            let completed = try XCTUnwrap(result)
            await work.value
            let stored = try await fixture.model.journal.load()
            let persisted = try XCTUnwrap(stored.records.first)
            let expected = (releaseFirst ? [releaseFailure, engineFailure] : [engineFailure, releaseFailure]).joined(separator: "\n")
            XCTAssertEqual(completed.state, .outcomeUnknown)
            XCTAssertEqual(completed.stopCause, cause)
            XCTAssertEqual(completed.cleanupFailure, expected,
                           "The stream and cancel error report the same engine failure; each distinct failure must appear once.")
            XCTAssertFalse(completed.cleanupFailure?.contains("isolated-coordinator-fixture") ?? true)
            XCTAssertEqual(persisted.id, runID)
            XCTAssertEqual(persisted.state, .outcomeUnknown)
            XCTAssertEqual(persisted.stopCause, cause)
            XCTAssertEqual(persisted.cleanupFailure, expected)
            XCTAssertEqual(summaryAtActivityEnd?.cleanupFailure, expected)
            XCTAssertEqual(fixture.background.successes, [false])
            XCTAssertEqual(fixture.notifications.states, [.outcomeUnknown])
            XCTAssertNil(fixture.model.deviceSession.owner)
            XCTAssertNil(fixture.model.activeRun)
            XCTAssertFalse(fixture.model.isBusy)
            let events = await fixture.actuator.events
            XCTAssertEqual(events, ["disconnect", "disconnect"])
        }
    }

    func testRuntimeCleanupFailureDisconnectsWithoutChangingCompletedOutcome() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.factory.running.trailingEvents = [.cleanupFailed("Runtime close could not be confirmed"), .finished(.completed)]
        fixture.model.draft = "Do the task"
        await fixture.model.sendMessage()
        XCTAssertEqual(fixture.model.runs.first?.state, .completed)
        XCTAssertEqual(fixture.model.runs.first?.cleanupFailure, "Runtime close could not be confirmed")
        XCTAssertEqual(fixture.background.successes, [false])
        let events = await fixture.actuator.events
        XCTAssertEqual(events, ["disconnect"])
    }

    func testBusyAndOwnershipRemainHeldUntilDeviceCleanupAndFinalJournalAreComplete() async throws {
        let release = CoordinatorGate()
        let fixture = try ControlCoordinatorFixture(releaseGate: release); defer { fixture.remove() }
        var sawFinalSummaryWhileBusy = false
        fixture.background.onEnd = { taskID in
            XCTAssertTrue(fixture.model.isRunning)
            XCTAssertFalse(fixture.model.canChangeDeviceRoute)
            XCTAssertEqual(fixture.model.deviceSession.owner, .run(taskID))
            let summaryURL = fixture.directory.appendingPathComponent("Runs/\(taskID.uuidString).json")
            if let data = try? Data(contentsOf: summaryURL), let summary = try? JSONDecoder().decode(RunRecord.self, from: data) {
                sawFinalSummaryWhileBusy = summary.endedAt != nil && summary.state == .completed
            }
        }
        fixture.model.draft = "Do the task"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { await fixture.actuator.releaseStarted }
        XCTAssertTrue(fixture.model.isRunning)
        XCTAssertTrue(fixture.model.isBusy)
        XCTAssertFalse(fixture.model.canChangeDeviceRoute)
        XCTAssertFalse(fixture.model.canRepairDeviceConnection)
        XCTAssertNotNil(fixture.model.deviceSession.owner)
        XCTAssertNil(fixture.model.activeRun?.endedAt)
        await release.open()
        await work.value
        XCTAssertTrue(sawFinalSummaryWhileBusy)
        XCTAssertFalse(fixture.model.isRunning)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertNil(fixture.model.deviceSession.owner)
        XCTAssertTrue(fixture.model.canChangeDeviceRoute)
    }

    func testFactoryCreatesRunEngineWithoutReplacingConfiguredRecoveryEngine() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.model.draft = "Do the task"
        await fixture.model.sendMessage()
        XCTAssertEqual(fixture.factory.running.requests.count, 1)
        XCTAssertEqual(fixture.factory.configured.requests.count, 0)
        XCTAssertTrue(fixture.factory.toolNames.contains(DeviceToolSpec.tap.rawValue))
        await fixture.model.recoverSelectedConversation()
        XCTAssertEqual(fixture.factory.configured.recoveries, 1)
        XCTAssertEqual(fixture.factory.running.recoveries, 0)
    }

    func testUserStopPreservesItsCauseAndDisconnectsTheOwnedClient() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.factory.running.holdStream = true
        fixture.model.draft = "Do the task"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { fixture.factory.running.requests.count == 1 }
        let runID = try XCTUnwrap(fixture.model.activeRun?.id)
        let record = await fixture.model.runCoordinator.stopAndWait(runID: runID)
        await work.value
        XCTAssertEqual(record?.state, .interrupted)
        XCTAssertEqual(record?.stopCause, .userRequested)
        XCTAssertGreaterThan(fixture.factory.running.cancellations, 0)
        XCTAssertEqual(fixture.factory.configured.cancellations, 0)
        XCTAssertFalse(fixture.model.isRunning)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertFalse(fixture.model.deviceSession.hasUnconfirmedRelease)
    }

    func testStopRetainsAnUnconfirmedReleaseReceiptInTheOwningDeviceSession() async throws {
        let fixture = try ControlCoordinatorFixture(releaseConfirmed: false); defer { fixture.remove() }
        fixture.factory.running.holdStream = true
        fixture.model.draft = "Stop with unconfirmed release"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { fixture.factory.running.requests.count == 1 }
        let runID = try XCTUnwrap(fixture.model.activeRun?.id)
        _ = await fixture.model.runCoordinator.stopAndWait(runID: runID)
        await work.value
        XCTAssertTrue(fixture.model.deviceSession.hasUnconfirmedRelease)
        XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertThrowsError(try fixture.model.deviceSession.acquire(.run(UUID())))
    }

    func testStopKeepsRunOwnershipUntilItsCapturedDisconnectCompletes() async throws {
        let disconnect = CoordinatorGate()
        let fixture = try ControlCoordinatorFixture(disconnectGate: disconnect); defer { fixture.remove() }
        fixture.factory.running.holdStream = true
        var disconnectReleased = false
        fixture.background.onEnd = { _ in
            XCTAssertTrue(disconnectReleased, "Run completion must wait for stop-owned transport teardown.")
        }
        fixture.model.draft = "Stop while disconnect is pending"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { fixture.factory.running.requests.count == 1 }
        let runID = try XCTUnwrap(fixture.model.activeRun?.id)
        let stopping = Task { await fixture.model.runCoordinator.stopAndWait(runID: runID) }
        try await coordinatorEventually { await fixture.actuator.firstDisconnectStarted }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.model.isRunning)
        XCTAssertTrue(fixture.model.isStopping)
        XCTAssertEqual(fixture.model.deviceSession.owner, .run(runID))
        XCTAssertFalse(fixture.model.canChangeDeviceRoute)
        XCTAssertFalse(fixture.model.isDeviceReady)
        if case .releasing = fixture.model.deviceSession.state {} else { XCTFail("Stop must release through the owning session.") }
        disconnectReleased = true
        await disconnect.open()
        let completed = await stopping.value
        await work.value
        let persisted = try await fixture.model.journal.load().records.first
        XCTAssertEqual(completed?.id, runID)
        XCTAssertEqual(persisted?.id, runID)
        XCTAssertNotNil(persisted?.endedAt)
        XCTAssertFalse(fixture.model.isRunning)
        XCTAssertFalse(fixture.model.isStopping)
        XCTAssertNil(fixture.model.deviceSession.owner)
    }

    func testUserStopCannotHideLaterUnknownToolOutcome() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.factory.running.holdStream = true
        let cause = StopCause.outcomeUnknown(toolName: DeviceToolSpec.tap.rawValue)
        fixture.factory.running.cancellationOutcome = .stopped(cause)
        fixture.model.draft = "Stop after dispatch"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { fixture.factory.running.requests.count == 1 }
        let runID = try XCTUnwrap(fixture.model.activeRun?.id)
        let completed = await fixture.model.runCoordinator.stopAndWait(runID: runID)
        await work.value
        XCTAssertEqual(completed?.state, .outcomeUnknown)
        XCTAssertEqual(completed?.stopCause, cause)
        XCTAssertTrue(fixture.model.interruptedConversationIDs.contains(try XCTUnwrap(completed?.conversationID)))
    }

    func testStopDuringBackgroundPreparationCancelsWaitingWithoutStartingTheEngine() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.background.blocksBegin = true
        fixture.model.draft = "Do the task"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { fixture.background.begins == 1 }
        let runID = try XCTUnwrap(fixture.model.activeRun?.id)
        let record = await fixture.model.runCoordinator.stopAndWait(runID: runID)
        await work.value
        XCTAssertEqual(record?.state, .interrupted)
        XCTAssertTrue(fixture.factory.running.requests.isEmpty)
        XCTAssertEqual(fixture.factory.configured.cancellations, 0)
        XCTAssertFalse(fixture.model.isRunning)
        XCTAssertNil(fixture.model.deviceSession.owner)
    }

    func testStopDuringInitialStatusDoesNotStartBackgroundPreparationLater() async throws {
        let status = CoordinatorGate()
        let fixture = try ControlCoordinatorFixture(statusGate: status); defer { fixture.remove() }
        fixture.background.blocksBegin = true
        fixture.model.draft = "Stop before activity preparation"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { await fixture.actuator.statusStarted }
        let runID = try XCTUnwrap(fixture.model.activeRun?.id)
        let stopping = Task { await fixture.model.runCoordinator.stopAndWait(runID: runID) }
        try await coordinatorEventually { await fixture.actuator.firstDisconnectStarted }
        await status.open()
        let completed = await stopping.value
        await work.value
        XCTAssertEqual(completed?.state, .interrupted)
        XCTAssertEqual(completed?.stopCause, .userRequested)
        XCTAssertEqual(fixture.background.begins, 0)
        XCTAssertTrue(fixture.factory.running.requests.isEmpty)
        XCTAssertFalse(fixture.model.isRunning)
    }

    func testExternalLossDuringInitialStatusCannotPublishStaleReadinessOrStartWork() async throws {
        let status = CoordinatorGate()
        let fixture = try ControlCoordinatorFixture(statusGate: status); defer { fixture.remove() }
        // Delay the host stop callback so the coordinator must independently
        // reject the status result captured under the previous device identity.
        fixture.model.deviceSession.onExternalStop = nil
        fixture.model.draft = "Disconnected during preparation"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { await fixture.actuator.statusStarted }
        fixture.model.deviceSession.handle(.transportLost)
        XCTAssertFalse(fixture.model.isDeviceReady)
        await status.open()
        await work.value
        XCTAssertEqual(fixture.background.begins, 0)
        XCTAssertTrue(fixture.factory.running.requests.isEmpty)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertFalse(fixture.model.isRunning)
    }

    func testChatRunLeavesTheDeviceRouteUnownedAndSelectable() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.model.scope = .chat
        fixture.factory.running.holdStream = true
        fixture.model.draft = "Just chat"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { fixture.factory.running.requests.count == 1 }
        XCTAssertTrue(fixture.model.isRunning)
        XCTAssertFalse(fixture.model.isDeviceRunActive)
        XCTAssertNil(fixture.model.deviceSession.owner)
        XCTAssertTrue(fixture.model.canChangeDeviceRoute)
        XCTAssertTrue(fixture.model.canRepairDeviceConnection)
        let runID = try XCTUnwrap(fixture.model.activeRun?.id)
        _ = await fixture.model.runCoordinator.stopAndWait(runID: runID)
        await work.value
        let events = await fixture.actuator.events
        XCTAssertEqual(events, [])
    }

    func testUnknownOutcomeHasIndependentStateAndForcesConnectionRelease() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        let call = AgentToolCall(id: "unknown", name: DeviceToolSpec.tap.rawValue, arguments: [:])
        fixture.background.onEnd = { _ in
            XCTAssertEqual(fixture.model.runCoordinator.current?.stopCause, .outcomeUnknown(toolName: call.name))
        }
        fixture.factory.running.trailingEvents = [.toolStarted(call),
            .toolFinished(.init(call: call, result: .init(content: [.text("Unconfirmed")], outcome: .unknown))),
            .finished(.stopped(.outcomeUnknown(toolName: call.name)))]
        fixture.model.draft = "Do the task"
        await fixture.model.sendMessage()
        let record = try XCTUnwrap(fixture.model.runs.first)
        XCTAssertEqual(record.state, .outcomeUnknown)
        XCTAssertEqual(record.stopCause, .outcomeUnknown(toolName: call.name))
        XCTAssertTrue(fixture.model.interruptedConversationIDs.contains(record.conversationID))
        XCTAssertFalse(record.unknownActionTitle.isEmpty)
        let events = await fixture.actuator.events
        XCTAssertEqual(events, ["disconnect"])
    }

    func testFinalJournalSummaryFailurePreservesUnknownOutcomeAndReportsStorageErrorSeparately() async throws {
        let disconnect = CoordinatorGate()
        let fixture = try ControlCoordinatorFixture(disconnectGate: disconnect); defer { fixture.remove() }
        let cause = StopCause.outcomeUnknown(toolName: DeviceToolSpec.tap.rawValue)
        fixture.factory.running.trailingEvents = [.finished(.stopped(cause))]
        fixture.model.draft = "Unknown before final journal failure"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { await fixture.actuator.firstDisconnectStarted }
        let runID = try XCTUnwrap(fixture.model.activeRun?.id)
        let summary = fixture.directory.appendingPathComponent("Runs/\(runID.uuidString).json")
        // Numbered events can commit, while the derived summary destination
        // deliberately rejects its final atomic file replacement.
        try FileManager.default.createDirectory(at: summary, withIntermediateDirectories: true)
        fixture.model.currentScenePhase = .background
        await disconnect.open()
        await work.value
        let record = try XCTUnwrap(fixture.model.runs.first)
        XCTAssertEqual(record.state, .outcomeUnknown)
        XCTAssertEqual(record.stopCause, cause)
        XCTAssertNotNil(record.cleanupFailure)
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.background.successes, [false])
        XCTAssertEqual(fixture.notifications.states, [.outcomeUnknown])
        XCTAssertTrue(fixture.model.interruptedConversationIDs.contains(record.conversationID))
        try FileManager.default.removeItem(at: summary)
        let recovered = try await fixture.model.journal.load()
        XCTAssertTrue(recovered.failures.isEmpty)
        XCTAssertEqual(recovered.records.first?.state, .outcomeUnknown)
        XCTAssertEqual(recovered.records.first?.stopCause, cause)
    }

    func testUnknownToolResultSurvivesItsEventSaveFailureWithoutATerminalEvent() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.factory.running.holdStream = true
        fixture.model.draft = "Unknown result before event-save failure"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { fixture.model.activeRun?.submission == .accepted }
        let call = AgentToolCall(id: "unknown-save", name: DeviceToolSpec.tap.rawValue, arguments: [:])
        fixture.factory.running.yield(.toolStarted(call))
        try await coordinatorEventually { fixture.model.activeRun?.events.last?.kind == "tool.started" }
        try await blockNextJournalEntry(fixture)
        fixture.factory.running.yield(.toolFinished(.init(call: call, result: .init(content: [], outcome: .unknown))))
        // No finished(unknown) event and no runner callback are available to
        // rescue classification after the result's journal save fails.
        await work.value
        try await assertUnknownAndStorageFailure(fixture, tool: .tap)
    }

    func testEarlierEventSaveFailurePreservesAlreadyKnownRunnerUnknownWithoutItsCallback() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.factory.running.holdStream = true
        fixture.model.draft = "Runner knows before consumer catches up"
        let work = Task { await fixture.model.sendMessage() }
        try await coordinatorEventually { fixture.model.activeRun?.submission == .accepted }
        let tools = DeviceToolSession(client: fixture.model.deviceClient, scope: .control, timeoutSeconds: 30,
            log: { _, _ in throw CocoaError(.fileWriteUnknown) }, onUnknown: {})
        let screenshot = try XCTUnwrap(tools.tools.first { $0.name == DeviceToolSpec.screenshot.rawValue })
        do { _ = try await screenshot.execute([:]); XCTFail("The injected log failure must terminate the tool.") }
        catch { XCTAssertEqual(error as? AgentToolError, .outcomeUnknown) }
        XCTAssertTrue(tools.hasUnknownOutcome)
        fixture.model.runCoordinator.current?.tools = tools
        try await blockNextJournalEntry(fixture)
        fixture.factory.running.yield(.toolStarted(.init(id: "earlier-save", name: DeviceToolSpec.screenshot.rawValue, arguments: [:])))
        await work.value
        try await assertUnknownAndStorageFailure(fixture, tool: .screenshot)
    }

    private func blockNextJournalEntry(_ fixture: ControlCoordinatorFixture) async throws {
        let record = try XCTUnwrap(fixture.model.activeRun)
        // This actor call is also a barrier for the preceding accepted/tool
        // event, so the collision targets exactly the next consumer save.
        try await fixture.model.journal.save(record)
        let folder = fixture.directory.appendingPathComponent("Runs/\(record.id.uuidString).events")
        let sequence = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .compactMap { Int($0.deletingPathExtension().lastPathComponent) }.max() ?? 0
        let collision = folder.appendingPathComponent(String(format: "%020d.json", sequence + 1))
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        fixture.factory.running.onCancel = { try? FileManager.default.removeItem(at: collision) }
    }

    private func assertUnknownAndStorageFailure(_ fixture: ControlCoordinatorFixture, tool: DeviceToolSpec) async throws {
        let record = try XCTUnwrap(fixture.model.runs.first)
        XCTAssertEqual(record.state, .outcomeUnknown)
        XCTAssertEqual(record.stopCause, .outcomeUnknown(toolName: tool.rawValue))
        XCTAssertEqual(record.detail, String(localized: "run.unknown_delivery", table: "Runtime"))
        XCTAssertNotNil(record.cleanupFailure)
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertTrue(fixture.model.interruptedConversationIDs.contains(record.conversationID))
        XCTAssertEqual(fixture.background.successes, [false])
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertGreaterThan(fixture.factory.running.cancellations, 0)
        let recovered = try await fixture.model.journal.load()
        XCTAssertTrue(recovered.failures.isEmpty)
        XCTAssertEqual(recovered.records.first?.state, .outcomeUnknown)
        XCTAssertEqual(recovered.records.first?.cleanupFailure, record.cleanupFailure)
    }
}

@MainActor final class CoordinatorContinuationRegressionTests: XCTestCase {
    func testDeviceContinuationRequiresPermissionAndAReadyConnection() async throws {
        for scope in [TaskScope.observe, .control] {
            for ready in [false, true] {
                let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
                fixture.seedContinuation(scope: scope)
                fixture.model.scope = ready ? .chat : .control
                if !ready { fixture.model.deviceStatus = .unavailable(reason: "Disconnected") }
                await fixture.model.continueInterruptedRun()
                XCTAssertEqual(fixture.factory.running.requests.count, 0)
                XCTAssertEqual(fixture.model.errorMessage, String(localized: ready ? "run.enable_control_first" : "run.reconnect_first", table: "Runtime"))
                XCTAssertFalse(fixture.model.isBusy)
            }
        }
    }

    func testChatContinuationDoesNotRequireDevicePermissionOrConnection() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.seedContinuation(scope: .chat)
        fixture.model.scope = .chat; fixture.model.deviceStatus = .unavailable(reason: "Disconnected")
        await fixture.model.continueInterruptedRun()
        XCTAssertEqual(fixture.factory.running.requests.first?.mode, .resume)
        XCTAssertEqual(fixture.model.runs.first?.scope, .chat)
        XCTAssertEqual(fixture.factory.toolNames, [])
        XCTAssertEqual(fixture.background.begins, 0)
        let events = await fixture.actuator.events
        XCTAssertEqual(events, [])
    }

    func testHistoricalObserveContinuationRegistersOnlyObservationTools() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.seedContinuation(scope: .observe)
        fixture.model.scope = .control
        await fixture.model.continueInterruptedRun()
        XCTAssertEqual(Set(fixture.factory.toolNames), [DeviceToolSpec.screenshot.rawValue, DeviceToolSpec.listApplications.rawValue])
        XCTAssertEqual(fixture.model.runs.first?.scope, .observe)
        XCTAssertEqual(fixture.factory.running.requests.first?.mode, .resume)
    }

    func testPendingMessageWithoutRunRecordShowsNoticeAndContinuesAsChat() async throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        let message = AgentMessage(role: .user, text: "Saved before the run journal existed")
        let conversation = Conversation(messages: [message], pendingRequestID: message.id)
        fixture.model.conversations = [conversation]; fixture.model.selectedConversationID = conversation.id
        fixture.factory.configured.recovery = .init(messages: [], hasInterruptedRun: false)
        XCTAssertEqual(fixture.model.continuationNotice, String(localized: "run.missing_record_chat", table: "Runtime"))
        await fixture.model.continueInterruptedRun()
        XCTAssertEqual(fixture.factory.running.requests.first?.requestID, message.id)
        XCTAssertEqual(fixture.factory.running.requests.first?.mode, .message)
        XCTAssertEqual(fixture.model.runs.first?.scope, .chat)
        XCTAssertEqual(fixture.factory.toolNames, [])
    }

    func testDeviceContinuationLocksControlAcrossConversationSelectionButChatDoesNot() throws {
        let fixture = try ControlCoordinatorFixture(); defer { fixture.remove() }
        fixture.seedContinuation(scope: .control)
        fixture.model.selectedConversationID = UUID()
        XCTAssertFalse(fixture.model.canChangeDeviceControl)
        fixture.model.runs[0] = fixture.record(scope: .chat, conversationID: fixture.model.runs[0].conversationID, requestID: fixture.model.runs[0].requestID)
        XCTAssertTrue(fixture.model.canChangeDeviceControl)
    }
}

@MainActor private struct ControlCoordinatorFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-control-\(UUID())")
    let suite = "eiscue.control.coordinator.\(UUID())"
    let preferences: UserDefaults
    let credentials: CredentialStore
    let model: AppModel
    let actuator: CoordinatorActuator
    let factory = CoordinatorAgentFactory()
    let background = CoordinatorBackground()
    let notifications = CoordinatorNotifications()

    init(failRelease: Bool = false, releaseGate: CoordinatorGate? = nil, disconnectGate: CoordinatorGate? = nil, statusGate: CoordinatorGate? = nil, releaseConfirmed: Bool = true,
         method: DeviceConnectionMethod = .localVPN, releaseFailureMessage: String = "Fixture release failed") throws {
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); credentials = CredentialStore(service: suite)
        actuator = CoordinatorActuator(failRelease: failRelease, releaseGate: releaseGate, disconnectGate: disconnectGate, statusGate: statusGate, releaseConfirmed: releaseConfirmed,
                                       releaseFailureMessage: releaseFailureMessage)
        let factory = factory
        model = AppModel(storageDirectory: directory, preferences: preferences, credentialStore: credentials,
                         background: background, notifications: notifications,
                         agentFactory: { configuration, _, tools in factory.make(configuration: configuration, tools: tools) })
        model.isLoading = false; model.hapticsEnabled = false
        var settings = ModelSettings(); settings.model = "fixture"
        try model.saveModelSettings(settings, newKey: "isolated-coordinator-fixture")
        factory.producingRun = true
        try model.deviceSession.configure(method: method, backend: .automatic, client: DeviceClient(actuator: actuator))
        model.deviceStatus = .ready(capabilities: Set(DeviceCapability.allCases))
        model.activeDeviceConnectionMethod = method
        model.activeDeviceControlBackend = method == .bluetoothBoard ? nil : .coreDevice
    }
    func record(scope: TaskScope, conversationID: UUID, requestID: UUID) -> RunRecord {
        var record = RunRecord(id: UUID(), conversationID: conversationID, requestID: requestID, startedAt: Date(),
                               scope: scope, model: "fixture", skill: nil, state: .interrupted, detail: "Interrupted", events: [])
        record.submission = .accepted
        return record
    }
    func seedContinuation(scope: TaskScope) {
        let message = AgentMessage(role: .user, text: "Continue previous task")
        let conversation = Conversation(messages: [message])
        model.conversations = [conversation]; model.selectedConversationID = conversation.id
        model.runs = [record(scope: scope, conversationID: conversation.id, requestID: message.id)]
        model.interruptedConversationIDs = [conversation.id]
        factory.configured.recovery = .init(messages: [message], hasInterruptedRun: true, acceptedRequestIDs: [message.id])
    }
    func remove() {
        try? credentials.deleteAll(); preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private final class CoordinatorAgentFactory {
    let configured = ControlCoordinatorEngine()
    let running = ControlCoordinatorEngine()
    var producingRun = false
    var toolNames: [String] = []
    func make(configuration: AgentConfiguration?, tools: [AgentTool]) -> AgentClient {
        guard producingRun else { return AgentClient(engine: configured) }
        toolNames = tools.map(\.name)
        return AgentClient(engine: running)
    }
}

/// Deliberately scripted event source for host fault and timing injection;
/// durable engine behavior is checked separately through CoordinatorEngine.
@MainActor private final class ControlCoordinatorEngine: AgentEngine {
    var availability: AgentAvailability { get async { .ready } }
    var requests: [AgentRequest] = []
    var recoveries = 0, cancellations = 0
    var recovery = AgentRecovery(messages: [], hasInterruptedRun: false)
    var onStart: ((AgentRequest) -> Void)?
    var onCancel: (() -> Void)?
    var holdStream = false
    var cancellationOutcome = AgentRunOutcome.cancelled
    var cancellationGate: CoordinatorGate?
    var cancellationFailure: AgentError?
    var trailingEvents: [AgentEvent] = [.finished(.completed)]
    private var stream: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    func run(request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        requests.append(request); onStart?(request)
        let (events, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        stream = continuation; continuation.yield(.requestAccepted(request.requestID))
        if !holdStream { for event in trailingEvents { continuation.yield(event) }; continuation.finish(); stream = nil }
        return events
    }
    func recover(conversationID: UUID) async throws -> AgentRecovery { recoveries += 1; return recovery }
    func toolResult(conversationID: UUID, requestID: UUID, toolCallID: String) async throws -> AgentToolCompletion? { nil }
    func yield(_ event: AgentEvent) { stream?.yield(event) }
    func cancel() async throws {
        cancellations += 1; onCancel?()
        if let cancellationGate { await cancellationGate.wait() }
        if let cancellationFailure { stream?.yield(.cleanupFailed(cancellationFailure.localizedDescription)) }
        stream?.yield(.finished(cancellationOutcome)); stream?.finish(); stream = nil
        if let cancellationFailure { throw cancellationFailure }
    }
    func cancel(conversationID: UUID) async throws { try await cancel() }
    func removeConversation(id: UUID) async throws {}
}

private actor CoordinatorActuator: DeviceFixtureActuator {
    var fixtureObservedFrameID: UUID?, fixtureGeometry: DeviceFrameGeometry?
    private(set) var events: [String] = []
    private(set) var releaseStarted = false
    private var connected = true
    private(set) var firstDisconnectStarted = false
    private(set) var statusStarted = false
    let disconnectGate: CoordinatorGate?
    let statusGate: CoordinatorGate?
    let failRelease: Bool
    let releaseGate: CoordinatorGate?
    let releaseConfirmed: Bool
    let releaseFailureMessage: String
    private var releaseConfirmations: [Bool] = []
    init(failRelease: Bool = false, releaseGate: CoordinatorGate? = nil, disconnectGate: CoordinatorGate? = nil, statusGate: CoordinatorGate? = nil, releaseConfirmed: Bool = true,
         releaseFailureMessage: String = "Fixture release failed") {
        self.failRelease = failRelease; self.releaseGate = releaseGate; self.disconnectGate = disconnectGate; self.statusGate = statusGate; self.releaseConfirmed = releaseConfirmed
        self.releaseFailureMessage = releaseFailureMessage
    }
    func status() async -> DeviceStatus {
        statusStarted = true; await statusGate?.wait()
        return connected ? .ready(capabilities: Set(DeviceCapability.allCases)) : .unavailable(reason: "Disconnected")
    }
    func fixtureReleaseInput() async throws {
        events.append("release"); releaseStarted = true
        await releaseGate?.wait()
        if failRelease { throw DeviceControlError.deliveryUnknown(releaseFailureMessage) }
    }
    func fixtureDisconnect() async {
        events.append("disconnect"); connected = false
        if !firstDisconnectStarted {
            firstDisconnectStarted = true
            await disconnectGate?.wait()
        }
    }
    func setReleaseConfirmations(_ values: [Bool]) { releaseConfirmations = values }
    func fixtureDisconnectAndConfirmRelease() async -> Bool {
        await fixtureDisconnect()
        return releaseConfirmations.isEmpty ? releaseConfirmed : releaseConfirmations.removeFirst()
    }
}

private actor CoordinatorGate {
    var opened = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() { opened = true; for item in waiting { item.resume() }; waiting = [] }
}

@MainActor private final class CoordinatorBackground: RunBackgroundExecuting {
    var isExecuting = false
    var begins = 0
    var blocksBegin = false
    var successes: [Bool] = []
    var onEnd: ((UUID) -> Void)?
    func register() throws {}
    func begin(taskID: UUID, title: String, subtitle: String, totalUnitCount: Int64, onExpiration: @escaping @Sendable () -> Void) async throws {
        begins += 1; isExecuting = true
        if blocksBegin { try await Task.sleep(for: .seconds(30)) }
    }
    func update(taskID: UUID, completedUnitCount: Int64, totalUnitCount: Int64, title: String?, subtitle: String?) -> Bool { isExecuting }
    func end(taskID: UUID, success: Bool) -> Bool { onEnd?(taskID); successes.append(success); isExecuting = false; return true }
}

@MainActor private final class CoordinatorNotifications: RunNotifying {
    var isEnabled = true, isRequestingAuthorization = false
    var states: [RunState] = []
    var authorizationDescription = "Fixture", lastError: String?
    func refreshAuthorization() async {}
    func setEnabled(_ enabled: Bool) async { isEnabled = enabled }
    func notify(runID: UUID, state: RunState, systemActivityUpdated: Bool) async { states.append(state) }
}

@MainActor private func coordinatorEventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CoordinatorRegressionError.timedOut
}

private enum CoordinatorRegressionError: Error { case timedOut }
