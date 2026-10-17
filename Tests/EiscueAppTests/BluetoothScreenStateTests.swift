import EiscueDeviceCore
import Foundation
import XCTest

@MainActor final class BluetoothScreenStateTests: XCTestCase {
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
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
