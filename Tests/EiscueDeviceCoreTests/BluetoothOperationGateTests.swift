import Foundation
import Testing
@testable import EiscueDeviceCore

@Suite("Bluetooth monitoring and action handoff")
@MainActor
struct BluetoothOperationGateTests {
    @Test func taskCleanupWaitsForPollAndReservesTheNextOperation() async throws {
        let gate = BluetoothOperationGate()
        #expect(gate.beginStatus())
        let cleanup = Task { try await gate.beginAction() }
        try await waitForAction(gate)
        #expect(!gate.beginStatus())
        await #expect(throws: DeviceControlError.busy) { try await gate.beginAction() }
        gate.endStatus()
        try await cleanup.value
        #expect(gate.isBusy)
        #expect(!gate.beginStatus())
        gate.endAction()
        #expect(gate.beginStatus())
        gate.endStatus()
    }

    @Test func cancellingWaitingActionDoesNotCancelPollOrBlockNextAction() async throws {
        let gate = BluetoothOperationGate()
        #expect(gate.beginStatus())
        let cancelled = Task { try await gate.beginAction() }
        try await waitForAction(gate)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(gate.isBusy)
        let next = Task { try await gate.beginAction() }
        try await waitForAction(gate)
        gate.endStatus()
        try await next.value
        gate.endAction()
        #expect(!gate.isBusy)
    }

    @Test func cancellationAtHandoffReleasesOnlyTheReservedAction() async throws {
        let gate = BluetoothOperationGate()
        #expect(gate.beginStatus())
        let cancelled = Task { try await gate.beginAction() }
        try await waitForAction(gate)
        gate.endStatus()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!gate.isBusy)
        try await gate.beginAction()
        gate.endAction()
    }

    @Test func concurrentUserActionsStillFailWithoutQueuingOrReplay() async throws {
        let gate = BluetoothOperationGate()
        try await gate.beginAction()
        await #expect(throws: DeviceControlError.busy) { try await gate.beginAction() }
        #expect(!gate.beginStatus())
        gate.endAction()
    }

    private func waitForAction(_ gate: BluetoothOperationGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.hasWaitingAction, ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.hasWaitingAction)
    }
}
