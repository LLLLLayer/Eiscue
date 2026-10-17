import EiscueDeviceCore
import Foundation
import XCTest
@testable import Eiscue

@MainActor final class BluetoothDeviceEventTests: XCTestCase {
    private typealias Projection = BluetoothSessionEventProjection

    func testNewPixelsAndHeartbeatsDoNotInvalidateTheObservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenBroadcastStore(containerURL: directory)
        let session = try store.beginSession()
        let first = try store.publish(jpegData: Data([0xff, 0xd8, 1, 0xff, 0xd9]), width: 100, height: 200, orientation: .up, sessionID: session)
        var projection = Projection()
        XCTAssertNil(projection.update(.init(screen: store.state())))
        let second = try store.publish(jpegData: Data([0xff, 0xd8, 2, 0xff, 0xd9]), width: 100, height: 200, orientation: .up, sessionID: session)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(projection.update(.init(screen: store.state())))
        try store.heartbeat(sessionID: session, frameID: second, newerFramePending: false)
        XCTAssertNil(projection.update(.init(screen: store.state())))
    }

    func testSharingStopIsDetectedWhileIdleAndOnlyOnce() throws {
        let geometry = geometry()
        var projection = Projection()
        XCTAssertNil(projection.update(.init(geometry: geometry)))
        XCTAssertEqual(projection.update(.init(sharing: false, geometry: nil)), .screenSharingStopped)
        XCTAssertNil(projection.update(.init(sharing: false, geometry: nil)))
        XCTAssertNil(projection.update(.init(geometry: geometry)))
    }

    func testSessionOrientationAndDimensionsEachInvalidateGeometry() {
        let original = geometry()
        for changed in [geometry(sessionID: UUID()), geometry(orientation: .right), geometry(width: 200), geometry(height: 300)] {
            var projection = Projection()
            XCTAssertNil(projection.update(.init(geometry: original)))
            XCTAssertEqual(projection.update(.init(geometry: changed)), .geometryChanged)
            XCTAssertNil(projection.update(.init(geometry: changed)))
        }
    }

    func testAuthenticationFailureHasPriorityOverConcurrentTransportAndSharingLoss() {
        for error in [BluetoothBoardError.authenticationFailed, .authenticationKeyUnavailable, .enrollmentClosed, .enrollmentConflict] {
            var projection = Projection()
            XCTAssertNil(projection.update(.init(geometry: geometry())))
            let failed = Projection.Snapshot(boardState: .failed(error), connected: false, sharing: false, geometry: nil)
            XCTAssertEqual(projection.update(failed), .authenticationFailed)
            XCTAssertNil(projection.update(failed))
        }
    }

    func testTransportLossHasPriorityAndDoesNotRepeatForAnotherDisconnectedState() {
        var projection = Projection()
        XCTAssertNil(projection.update(.init(geometry: geometry())))
        XCTAssertEqual(projection.update(.init(boardState: .disconnected, connected: false, sharing: false, geometry: nil)), .transportLost)
        XCTAssertNil(projection.update(.init(boardState: .idle, connected: false, sharing: false, geometry: nil)))
    }

    func testOwnedConnectionTransitionsRebaseWithoutExternalCancellation() {
        var projection = Projection()
        XCTAssertNil(projection.update(.init(geometry: geometry())))
        XCTAssertNil(projection.update(.init(boardState: .disconnected, connected: false, sharing: false, geometry: nil), acceptsEvents: false))
        XCTAssertNil(projection.update(.init(boardState: .idle, connected: false, sharing: false, geometry: nil)))
        XCTAssertNil(projection.update(.init(geometry: geometry()), acceptsEvents: false))
        XCTAssertEqual(projection.update(.init(sharing: false, geometry: nil)), .screenSharingStopped)
    }

    func testOnlyCurrentTransportOperationsRebaseExpectedConnectionChanges() throws {
        let session = makeSession()
        try session.configure(method: .bluetoothBoard, backend: .automatic)
        var projection = Projection()
        XCTAssertNil(projection.update(.init(geometry: geometry()), session: session))
        let connection = try session.beginConnection(method: .bluetoothBoard, backend: .automatic)
        XCTAssertTrue(session.expectsTransportChanges)
        XCTAssertNil(projection.update(.init(boardState: .disconnected, connected: false, sharing: false, geometry: nil), session: session))
        session.handle(.transportLost)
        XCTAssertTrue(session.isTransitioning)
        XCTAssertFalse(session.expectsTransportChanges, "An invalidated operation cannot suppress newer external events.")
        XCTAssertFalse(session.completeConnection(connection, status: .ready(capabilities: [.screenshot])))
        XCTAssertNil(projection.update(.init(geometry: geometry()), session: session))
        let release = try session.beginRelease()
        XCTAssertTrue(session.expectsTransportChanges)
        XCTAssertNil(projection.update(.init(boardState: .disconnected, connected: false, sharing: false, geometry: nil), session: session))
        XCTAssertTrue(session.completeRelease(release, confirmed: true))
        XCTAssertFalse(session.expectsTransportChanges)
    }

    func testSetupConnectionFailuresInvalidateCompletionImmediately() throws {
        for (snapshot, event) in [
            (Projection.Snapshot(boardState: .disconnected, connected: false, sharing: false, geometry: nil), DeviceSession.ExternalEvent.transportLost),
            (Projection.Snapshot(boardState: .failed(.authenticationFailed), connected: false, sharing: false, geometry: nil), .authenticationFailed)
        ] {
            try assertSetupEvent(snapshot, event: event, showsProgress: true)
        }
    }

    func testPreviewSharingAndGeometryEventsCannotRestoreCapturedReadyStatus() throws {
        for (snapshot, event) in [
            (Projection.Snapshot(sharing: false, geometry: nil), DeviceSession.ExternalEvent.screenSharingStopped),
            (Projection.Snapshot(geometry: geometry(orientation: .right)), .geometryChanged)
        ] {
            for showsProgress in [false, true] { try assertSetupEvent(snapshot, event: event, showsProgress: showsProgress) }
        }
    }

    func testHardwareStopUsesItsDedicatedEventWithoutASecondTransportCancellation() {
        var projection = Projection()
        let original = geometry()
        XCTAssertNil(projection.update(.init(geometry: original)))
        XCTAssertNil(projection.update(.init(hardwareStopped: true, geometry: original)))
        XCTAssertNil(projection.update(.init(boardState: .disconnected, connected: false, sharing: false, geometry: nil)))
    }

    func testCalibrationRefusesAnotherDeviceBorrower() throws {
        let session = makeSession()
        let run = try session.acquire(.run(UUID()))
        XCTAssertThrowsError(try BluetoothCalibrationOwnership(session: session))
        run.release()
        let calibration = try BluetoothCalibrationOwnership(session: session)
        XCTAssertEqual(session.owner, .setup)
        XCTAssertThrowsError(try session.acquire(.dictation(UUID())))
        calibration.lease.release()
    }

    func testCalibrationKeepsOwnershipUntilCancelledInputAndCleanupBothFinish() async throws {
        let session = makeSession(), input = Barrier(), cleanup = Barrier()
        let calibration = try BluetoothCalibrationOwnership(session: session)
        let operation = Task { await input.wait() }
        var cleanupCalls = 0
        let completion = Task {
            await calibration.finish(after: operation) { cleanupCalls += 1; await cleanup.wait() }
        }
        await input.waitUntilEntered()
        operation.cancel()
        XCTAssertEqual(session.owner, .setup)
        XCTAssertEqual(cleanupCalls, 0)
        XCTAssertThrowsError(try session.acquire(.run(UUID())))
        input.resume()
        await cleanup.waitUntilEntered()
        let repeated = Task { await calibration.finish(after: nil) { cleanupCalls += 100 } }
        await Task.yield()
        XCTAssertEqual(session.owner, .setup); XCTAssertEqual(cleanupCalls, 1)
        cleanup.resume()
        await completion.value; await repeated.value
        XCTAssertNil(session.owner); XCTAssertEqual(cleanupCalls, 1)
    }

    func testLateCalibrationDismissalCannotReleaseANewerSetupOwner() async throws {
        let session = makeSession(), calibration = try BluetoothCalibrationOwnership(session: session)
        await calibration.finish(after: nil) {}
        let next = try session.acquire(.setup)
        await calibration.finish(after: nil) { XCTFail("Cleanup must run once.") }
        XCTAssertEqual(session.owner, .setup)
        next.release()
    }

    private let sessionID = UUID()
    private func geometry(sessionID: UUID? = nil, orientation: ScreenBroadcastOrientation = .up,
                          width: Int = 100, height: Int = 200) -> Projection.Geometry {
        .init(sessionID: sessionID ?? self.sessionID, orientation: orientation, width: width, height: height)
    }
    private func makeSession() -> DeviceSession {
        DeviceSession(client: DeviceClient(actuator: CalibrationActuator()))
    }
    private func assertSetupEvent(_ snapshot: Projection.Snapshot, event: DeviceSession.ExternalEvent, showsProgress: Bool) throws {
        let session = makeSession(), ready = DeviceStatus.ready(capabilities: [.screenshot, .tap])
        try session.configure(method: .bluetoothBoard, backend: .automatic)
        let connection = try session.beginConnection(method: .bluetoothBoard, backend: .automatic)
        XCTAssertTrue(session.completeConnection(connection, status: ready))
        var projection = Projection()
        XCTAssertNil(projection.update(.init(geometry: geometry()), session: session))
        let lease = try session.acquire(.setup)
        defer { lease.release() }
        let preview = try session.beginSetup(owner: lease.owner, showsProgress: showsProgress)
        let captured = session.identity, unavailable = DeviceStatus.unavailable(reason: "external event during setup")
        XCTAssertTrue(session.isTransitioning); XCTAssertFalse(session.expectsTransportChanges)
        let detected = try XCTUnwrap(projection.update(snapshot, session: session))
        XCTAssertEqual(detected, event)
        let outcome = session.handle(detected, expected: captured, status: unavailable)
        XCTAssertFalse(outcome.isIgnored); XCTAssertTrue(outcome.invalidatesPreview)
        XCTAssertFalse(session.isCurrent(captured))
        XCTAssertEqual(session.status, unavailable)
        XCTAssertFalse(session.completeSetup(preview, status: ready, transportConnected: true))
        XCTAssertEqual(session.status, unavailable)
        let transportLost = event == .transportLost || event == .authenticationFailed
        XCTAssertEqual(session.activeMethod, transportLost ? nil : .bluetoothBoard)
        XCTAssertFalse(session.isTransitioning)
        XCTAssertEqual(session.state, transportLost ? .idle(route: .bluetoothBoard) : .connected(route: .bluetoothBoard, backend: nil, status: unavailable))
        XCTAssertNil(projection.update(snapshot, session: session))
    }
    @MainActor private final class Barrier {
        private var continuation: CheckedContinuation<Void, Never>?
        private var entered = false
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func waitUntilEntered() async { while !entered { await Task.yield() } }
        func resume() { continuation?.resume(); continuation = nil }
    }
}

private actor CalibrationActuator: DeviceFixtureActuator {
    var fixtureObservedFrameID: UUID?
    var fixtureGeometry: DeviceFrameGeometry?
    func status() async -> DeviceStatus { .unavailable(reason: "test") }
}
