import Foundation
import Testing
@testable import EiscueDeviceCore

@Suite @MainActor struct GuardedDeviceTests {
    @Test(arguments: [DeviceAction.home, .launch(bundleID: "org.eiscue.app"), .typeText("hello"), .pressKey(.enter), .tap(DevicePoint(x: 2, y: 3)), .swipe(DevicePoint(x: 0, y: 0), DevicePoint(x: 5, y: 5), .milliseconds(100))])
    func everyActionConsumesOneObservation(action: DeviceAction) async throws {
        let route = GuardFixture()
        let guarded = GuardedDevice(actuator: route)
        await #expect(throws: DeviceControlError.staleFrame) { try await guarded.perform(action, frameID: UUID()) }
        let image = try await guarded.captureScreenshot()
        try await guarded.perform(action, frameID: image.frameID)
        await #expect(throws: DeviceControlError.staleFrame) { try await guarded.perform(action, frameID: image.frameID) }
        #expect(route.actions == [action])
    }

    @Test func captureMustRemainBoundToItsOriginalSession() async throws {
        let route = GuardFixture()
        route.captureGeometry = DeviceFrameGeometry(sessionID: UUID(), revision: "old", width: 10, height: 20)
        let device = GuardedDevice(actuator: route)
        await #expect(throws: DeviceControlError.staleFrame) { try await device.captureScreenshot() }
        #expect(route.actions.isEmpty)
    }

    @Test func recapturingAnUnchangedBackendFrameIssuesANewGrant() async throws {
        let route = GuardFixture()
        let guarded = GuardedDevice(actuator: route)
        let first = try await guarded.captureScreenshot(), second = try await guarded.captureScreenshot()
        #expect(first.frameID != second.frameID)
        await #expect(throws: DeviceControlError.staleFrame) { try await guarded.perform(.home, frameID: first.frameID) }
        try await guarded.perform(.home, frameID: second.frameID)
    }

    @Test func publicationChangesDoNotRenewDecisionOrRevokeItsGeometry() async throws {
        let clock = TestUptime(100), route = GuardFixture()
        route.confirmed = 100
        let device = GuardedDevice(actuator: route, uptime: { clock.value })
        let first = try await device.captureScreenshot()
        clock.value = 129.9; route.confirmed = 129.5
        try await device.perform(.home, frameID: first.frameID)
        let second = try await device.captureScreenshot()
        clock.value = 160; route.confirmed = 160
        await #expect(throws: DeviceControlError.staleFrame) { try await device.perform(.home, frameID: second.frameID) }
        #expect(route.actions.count == 1)
    }

    @Test(arguments: [false, true])
    func geometryChangeAndLivenessLossInvalidatePermanently(geometry: Bool) async throws {
        let clock = TestUptime(100), route = GuardFixture()
        route.confirmed = 100
        let device = GuardedDevice(actuator: route, uptime: { clock.value })
        let frame = try await device.captureScreenshot(), original = route.geometry
        if geometry { route.geometry = DeviceFrameGeometry(sessionID: original.sessionID, revision: "rotated", width: 20, height: 10) }
        else { clock.value = 104 }
        await #expect(throws: DeviceControlError.staleFrame) { try await device.perform(.home, frameID: frame.frameID) }
        route.geometry = original; clock.value = 100; route.confirmed = 100
        await #expect(throws: DeviceControlError.staleFrame) { try await device.perform(.home, frameID: frame.frameID) }
        #expect(route.actions.isEmpty)
    }

    @Test func pauseAndReconnectCannotReuseOldObservation() async throws {
        let route = GuardFixture()
        let guarded = GuardedDevice(actuator: route)
        let paused = try await guarded.captureScreenshot()
        guarded.invalidate()
        await #expect(throws: DeviceControlError.staleFrame) { try await guarded.perform(.home, frameID: paused.frameID) }
        let frame = try await guarded.captureScreenshot()
        route.live = false
        await #expect(throws: DeviceControlError.staleFrame) { try await guarded.perform(.home, frameID: frame.frameID) }
        route.live = true
        await #expect(throws: DeviceControlError.staleFrame) { try await guarded.perform(.home, frameID: frame.frameID) }
    }

    @Test func validationRejectsBeforeSubmissionAndPreservesFrame() async throws {
        let route = GuardFixture()
        let guarded = GuardedDevice(actuator: route), frame = try await guarded.captureScreenshot()
        await #expect(throws: DeviceControlError.invalidCoordinates) { try await guarded.perform(.tap(DevicePoint(x: .nan, y: 0)), frameID: frame.frameID) }
        await #expect(throws: DeviceControlError.invalidDuration) { try await guarded.perform(.swipe(DevicePoint(x: 1, y: 1), DevicePoint(x: 2, y: 2), .seconds(3)), frameID: frame.frameID) }
        await #expect(throws: DeviceControlError.invalidText) { try await guarded.perform(.typeText("a\0b"), frameID: frame.frameID) }
        await #expect(throws: DeviceControlError.invalidBundleID) { try await guarded.perform(.launch(bundleID: "org/eiscue"), frameID: frame.frameID) }
        try await guarded.perform(.home, frameID: frame.frameID)
        #expect(route.actions == [.home])
    }

    @Test func onlyExplicitNotSubmittedIsSafeToRetry() async throws {
        let route = GuardFixture()
        let guarded = GuardedDevice(actuator: route)
        route.result = .notSubmitted(.busy)
        let frame = try await guarded.captureScreenshot()
        await #expect(throws: DeviceControlError.busy) { try await guarded.perform(.home, frameID: frame.frameID) }
        route.failure = DeviceControlError.busy
        let second = try await guarded.captureScreenshot()
        await #expect(throws: DeviceControlError.deliveryUnknown("")) { try await guarded.perform(.home, frameID: second.frameID) }
        #expect(route.disconnects == 1)
        await #expect(throws: DeviceControlError.connectionLost) { try await guarded.captureScreenshot() }
        guarded.connectionDidOpen()
        _ = try await guarded.captureScreenshot()
    }

    @Test func disconnectAfterAcknowledgementIsUnknownAndConcurrentActionsAreBusy() async throws {
        let route = GuardFixture()
        let guarded = GuardedDevice(actuator: route), frame = try await guarded.captureScreenshot()
        route.suspend = true
        let submitted = Task { try await guarded.perform(.home, frameID: frame.frameID) }
        while route.pending == nil { await Task.yield() }
        await #expect(throws: DeviceControlError.busy) { try await guarded.captureScreenshot() }
        _ = await guarded.disconnect()
        route.pending?.resume(); route.pending = nil
        await #expect(throws: DeviceControlError.deliveryUnknown("")) { try await submitted.value }
        #expect(route.disconnects == 1 && route.actions == [.home])
    }

    @Test func cancellationAfterSubmissionCannotBecomeStopped() async throws {
        let route = GuardFixture()
        let device = GuardedDevice(actuator: route), frame = try await device.captureScreenshot()
        route.suspend = true
        let pending = Task { try await device.perform(.home, frameID: frame.frameID) }
        while route.pending == nil { await Task.yield() }
        pending.cancel(); route.pending?.resume(); route.pending = nil
        await #expect(throws: DeviceControlError.deliveryUnknown("")) { try await pending.value }
    }

    @Test func taskFinishOnlyReleasesInputAndInvalidatesObservation() async throws {
        let route = GuardFixture()
        let guarded = GuardedDevice(actuator: route), frame = try await guarded.captureScreenshot()
        route.releaseChangesCalibration = true
        try await guarded.finishTask()
        #expect(route.releases == 1 && route.disconnects == 0 && !route.ready)
        await #expect(throws: DeviceControlError.staleFrame) { try await guarded.perform(.home, frameID: frame.frameID) }
    }

    @Test func cachedStatusDoesNotProbeAndProbeFailureOnlyDowngrades() async throws {
        let route = GuardFixture()
        let guarded = GuardedDevice(actuator: route)
        for _ in 0..<10 { _ = await guarded.status() }
        #expect(route.probes == 0 && route.actions.isEmpty && route.disconnects == 0)
        route.probeFails = true
        _ = await guarded.probe()
        #expect(route.probes == 1 && route.disconnects == 0)
        #expect(await guarded.status() == .unavailable(reason: "fixture"))
    }

    @Test func capabilityFilteringIsEnforcedAtTheSharedGate() async throws {
        let route = GuardFixture()
        route.capabilities = [.screenshot, .tap]
        let device = GuardedDevice(actuator: route), frame = try await device.captureScreenshot()
        await #expect(throws: DeviceControlError.capabilityUnavailable(.home)) { try await device.perform(.home, frameID: frame.frameID) }
        #expect(route.actions.isEmpty)
        try await device.perform(.tap(DevicePoint(x: 1, y: 2)), frameID: frame.frameID)
    }

    @Test func nonFiniteAndOverflowingDurationsAreRejectedBeforeConversion() throws {
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 0, 2.001] {
            #expect(throws: DeviceControlError.invalidDuration) { try DeviceInputValidation.swipeDuration(seconds: value) }
        }
        #expect(try DeviceInputValidation.swipeDuration(seconds: 0.1) == .milliseconds(100))
        #expect(try DeviceInputValidation.swipeDuration(seconds: 2) == .seconds(2))
    }

    @Test func invalidClocksNeverAuthorizeInput() {
        for invalid in [Double.nan, .infinity, -.infinity, 101] {
            #expect(!FrameGrant.permits(decisionIssuedUptime: invalid, currentConfirmedUptime: 100, now: 100))
            #expect(!FrameGrant.permits(decisionIssuedUptime: 95, currentConfirmedUptime: invalid, now: 100))
        }
        #expect(FrameGrant.permits(decisionIssuedUptime: 95, currentConfirmedUptime: 97, now: 100))
        #expect(!FrameGrant.permits(decisionIssuedUptime: 70, currentConfirmedUptime: 100, now: 100))
    }
}

@MainActor private final class GuardFixture: DeviceActuator {
    let sourceFrameID = UUID()
    var geometry = DeviceFrameGeometry(sessionID: UUID(), revision: "1", width: 10, height: 20)
    var live = true, ready = true, probeFails = false, releaseChangesCalibration = false, suspend = false
    var confirmed: TimeInterval?
    var captureGeometry: DeviceFrameGeometry?
    var capabilities = Set(DeviceCapability.allCases)
    var actions: [DeviceAction] = [], probes = 0, releases = 0, disconnects = 0
    var result: SubmissionResult = .submitted
    var failure: (any Error)?
    var pending: CheckedContinuation<Void, Never>?
    func cachedStatus() async -> DeviceStatus { ready ? .ready(capabilities: capabilities) : .unavailable(reason: "fixture") }
    func probe() async -> DeviceStatus { probes += 1; if probeFails { ready = false }; return await cachedStatus() }
    func capture() async throws -> DeviceScreenshot { DeviceScreenshot(frameID: sourceFrameID, width: geometry.width, height: geometry.height, mimeType: "image/jpeg", data: Data([1]), geometry: captureGeometry ?? geometry) }
    func frameState() async throws -> DeviceFrameState { DeviceFrameState(geometry: geometry, isLive: live, confirmedUptime: confirmed) }
    func perform(_ action: DeviceAction, frame: FrameGrant) async throws -> SubmissionResult {
        actions.append(action)
        if suspend { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
        return result
    }
    func releaseInput() async throws { releases += 1; if releaseChangesCalibration { ready = false } }
    func disconnect() async -> ReleaseConfirmation { disconnects += 1; return .confirmed }
    func listApplications() async throws -> [DeviceApplication] { [] }
}
private final class TestUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval
    init(_ current: TimeInterval) { self.current = current }
    var value: TimeInterval { get { lock.withLock { current } } set { lock.withLock { current = newValue } } }
}
