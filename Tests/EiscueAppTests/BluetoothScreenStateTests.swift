@testable import EiscueDeviceCore
import Foundation
import XCTest

@MainActor final class BluetoothScreenStateTests: XCTestCase {
    func testObservedGeometryChangesCannotRestoreThePreviousCalibration() async throws {
        for (orientation, width, height) in [(ScreenBroadcastOrientation.down, 100, 200), (.up, 200, 100), (.right, 200, 100)] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let session = try fixture.writer.beginSession()
            try fixture.publish(session: session)
            try await fixture.calibratePublishedScreen()

            try fixture.publish(session: session, orientation: orientation, width: width, height: height)
            await fixture.controller.refreshScreenState()
            XCTAssertFalse(fixture.controller.isPointerVerified)
            XCTAssertNil(fixture.controller.calibration)
            XCTAssertNil(fixture.controller.relativeCalibration)

            try fixture.publish(session: session)
            await fixture.controller.refreshScreenState()
            XCTAssertTrue(fixture.controller.screenState?.isActive == true)
            XCTAssertFalse(fixture.controller.isPointerVerified, "Returning to the verified geometry requires a fresh calibration.")
        }
    }

    func testNewPixelsAndHeartbeatsPreserveCalibrationWithoutUIFileReads() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try fixture.writer.beginSession()
        let originalID = try fixture.publish(session: session)
        try await fixture.calibratePublishedScreen()

        let changedID = try fixture.publish(session: session, pixel: 2)
        XCTAssertNotEqual(originalID, changedID)
        await fixture.controller.refreshScreenState()
        XCTAssertTrue(fixture.controller.isPointerVerified)
        XCTAssertNotNil(fixture.controller.relativeCalibration)
        try fixture.writer.heartbeat(sessionID: session, frameID: changedID, newerFramePending: false)
        await fixture.controller.refreshScreenState()
        await fixture.controller.refreshScreenState()
        XCTAssertTrue(fixture.controller.isPointerVerified)
        XCTAssertNotNil(fixture.controller.relativeCalibration)

        let beforeUI = fixture.reader.readMetrics
        _ = fixture.controller.screenState
        _ = fixture.controller.isPointerVerified
        _ = await fixture.controller.cachedStatus()
        XCTAssertEqual(fixture.reader.readMetrics, beforeUI)
        XCTAssertEqual(fixture.reader.readMetrics.mainThreadDecodeCount, 0)
    }

    func testSameSessionPauseOnlyBlocksReadinessUntilTheSameScreenReturns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try fixture.writer.beginSession()
        try fixture.publish(session: session)
        try await fixture.calibratePublishedScreen()

        try fixture.writer.setPaused(true, sessionID: session)
        await fixture.controller.refreshScreenState()
        XCTAssertEqual(fixture.controller.screenState?.phase, .paused)
        XCTAssertFalse(fixture.controller.isPointerVerified)
        XCTAssertNotNil(fixture.controller.calibration)
        XCTAssertNotNil(fixture.controller.relativeCalibration)
        try fixture.writer.setPaused(false, sessionID: session)
        await fixture.controller.refreshScreenState()
        XCTAssertEqual(fixture.controller.screenState?.phase, .starting)
        XCTAssertFalse(fixture.controller.isPointerVerified)
        XCTAssertNotNil(fixture.controller.calibration)
        XCTAssertNotNil(fixture.controller.relativeCalibration)
        try fixture.publish(session: session)
        await fixture.controller.refreshScreenState()
        XCTAssertTrue(fixture.controller.screenState?.isActive == true)
        XCTAssertTrue(fixture.controller.isPointerVerified)
    }

    func testObservedSessionEndAndReplacementClearCalibration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try fixture.writer.beginSession()
        try fixture.publish(session: session)
        try await fixture.calibratePublishedScreen()

        try fixture.writer.finishSession(sessionID: session)
        await fixture.controller.refreshScreenState()
        XCTAssertEqual(fixture.controller.screenState?.phase, .ended)
        XCTAssertNil(fixture.controller.calibration)
        XCTAssertNil(fixture.controller.relativeCalibration)

        let nextSession = try fixture.writer.beginSession()
        try fixture.publish(session: nextSession)
        try await fixture.calibratePublishedScreen()
        let replacement = try fixture.writer.beginSession()
        try fixture.publish(session: replacement)
        await fixture.controller.refreshScreenState()
        XCTAssertNil(fixture.controller.calibration)
        XCTAssertNil(fixture.controller.relativeCalibration)
        XCTAssertFalse(fixture.controller.isPointerVerified)
    }

    func testUnreadableMetadataOnlyBlocksReadinessUntilTheSameScreenReturns() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try fixture.writer.beginSession()
        try fixture.publish(session: session)
        try await fixture.calibratePublishedScreen()
        let recordURL = fixture.directory.appendingPathComponent("ScreenBroadcast/latest.plist")
        let record = try Data(contentsOf: recordURL)
        try Data([0]).write(to: recordURL, options: .atomic)

        await fixture.controller.refreshScreenState()
        XCTAssertEqual(fixture.controller.screenState?.phase, .unavailable)
        XCTAssertFalse(fixture.controller.isPointerVerified)
        XCTAssertNotNil(fixture.controller.calibration)
        XCTAssertNotNil(fixture.controller.relativeCalibration)

        try record.write(to: recordURL, options: .atomic)
        await fixture.controller.refreshScreenState()
        XCTAssertTrue(fixture.controller.isPointerVerified)
        XCTAssertEqual(fixture.reader.readMetrics.mainThreadDecodeCount, 0)
    }

    func testUIGettersDoNotOpenAnUncachedPublishedFrame() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try fixture.writer.beginSession()
        try fixture.writer.publish(jpegData: Data([0xff, 0xd8, 1, 0xff, 0xd9]), width: 100, height: 200, orientation: .up, sessionID: session)
        let baseline = fixture.reader.readMetrics
        XCTAssertNil(fixture.controller.screenState)
        XCTAssertFalse(fixture.controller.isPointerVerified)
        _ = await fixture.controller.cachedStatus()
        XCTAssertEqual(fixture.reader.readMetrics, baseline)
        _ = await fixture.controller.probe()
        XCTAssertEqual(fixture.controller.screenState?.width, 100)
        XCTAssertEqual(fixture.reader.readMetrics.decodeCount, 1)
        XCTAssertEqual(fixture.reader.readMetrics.mainThreadDecodeCount, 0)
        let refreshed = fixture.reader.readMetrics
        try fixture.writer.setPaused(true, sessionID: session)
        XCTAssertTrue(fixture.controller.screenState?.isActive == true)
        _ = await fixture.controller.cachedStatus()
        XCTAssertEqual(fixture.reader.readMetrics, refreshed)
        await fixture.controller.refreshScreenState()
        XCTAssertEqual(fixture.controller.screenState?.phase, .paused)
        XCTAssertEqual(fixture.reader.readMetrics.mainThreadDecodeCount, 0)
    }

    func testChangingLargePublicationsDecodeOffMainWhileUIReadsNoFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = try fixture.writer.beginSession()
        let started = ContinuousClock.now
        for index in 0..<34 {
            let jpeg = Data([0xff, 0xd8]) + Data(repeating: UInt8(index), count: 1_490_000) + Data([0xff, 0xd9])
            try fixture.writer.publish(jpegData: jpeg, width: 1600, height: 900, orientation: .right, sessionID: session)
            let beforeUI = fixture.reader.readMetrics
            for _ in 0..<4 {
                _ = fixture.controller.screenState
                _ = fixture.controller.isPointerVerified
                _ = await fixture.controller.cachedStatus()
            }
            XCTAssertEqual(fixture.reader.readMetrics, beforeUI)
            await fixture.controller.refreshScreenState()
            XCTAssertEqual(fixture.controller.screenState?.width, 1600)
            XCTAssertEqual(fixture.controller.screenState?.height, 900)
        }
        let metrics = fixture.reader.readMetrics
        XCTAssertEqual(metrics.decodeCount, 34)
        XCTAssertEqual(metrics.mainThreadDecodeCount, 0)
        XCTAssertGreaterThan(metrics.decodedBytes, 50_000_000)
        print("ReplayKit changing-frame UI fixture: publications=34 decodes=\(metrics.decodeCount) mainThreadDecodes=\(metrics.mainThreadDecodeCount) decodedBytes=\(metrics.decodedBytes) elapsed=\(started.duration(to: .now))")
    }

    @MainActor private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writer: ScreenBroadcastStore
        let reader: ScreenBroadcastStore
        let controller: BluetoothDeviceController
        init() throws {
            writer = ScreenBroadcastStore(containerURL: directory)
            reader = ScreenBroadcastStore(containerURL: directory)
            controller = BluetoothDeviceController(screenStore: reader)
        }
        @discardableResult
        func publish(session: UUID, pixel: UInt8 = 1, orientation: ScreenBroadcastOrientation = .up,
                     width: Int = 100, height: Int = 200) throws -> UUID {
            try writer.publish(jpegData: Data([0xff, 0xd8, pixel, 0xff, 0xd9]), width: width, height: height,
                orientation: orientation, sessionID: session)
        }
        func calibratePublishedScreen() async throws {
            await controller.refreshScreenState()
            let source = writer
            let reading = try await Task.detached { try source.readCurrentFrame() }.value
            controller.calibration = try BluetoothDeviceController.Calibration(observed: [
                DevicePoint(x: 0.25, y: 0.25), DevicePoint(x: 0.75, y: 0.25),
                DevicePoint(x: 0.25, y: 0.75), DevicePoint(x: 0.62, y: 0.61)
            ], frame: BluetoothDeviceController.ObservedFrame(reading))
            controller.relativeCalibration = try BluetoothRelativeDragCalibration(observed:
                BluetoothRelativeCalibrationProbe.allCases.map { probe in
                    let stroke = probe.stroke
                    return BluetoothRelativeCalibrationObservation(probe: probe, receiptToken: UUID(), start: probe.anchor,
                        end: DevicePoint(x: probe.anchor.x + Double(stroke.totalDX) / 400,
                                         y: probe.anchor.y + Double(stroke.totalDY) / 800),
                        contactCount: 1, movedEventCount: 8, endedNormally: true,
                        startedUptime: 100, endedUptime: 100 + Double(stroke.durationMS + 8) / 1000)
                }, viewport: DevicePoint(x: 400, y: 800))
            XCTAssertTrue(controller.isPointerVerified)
        }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
