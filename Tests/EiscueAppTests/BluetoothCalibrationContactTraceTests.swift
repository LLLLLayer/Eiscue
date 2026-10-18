import EiscueDeviceCore
import UIKit
import XCTest
@testable import Eiscue

final class BluetoothCalibrationContactTraceTests: XCTestCase {
    func testContinuousContactRecordsActualDisplacementAndReceipt() throws {
        var trace = BluetoothCalibrationContactTrace()
        let start = DevicePoint(x: 0.35, y: 0.35), end = DevicePoint(x: 0.55, y: 0.36)
        trace.record(id: 1, phase: .began, point: start, uptime: 10)
        XCTAssertNil(trace.observation(probe: .horizontalLarge, receipt: UUID()))
        trace.record(id: 1, phase: .moved, point: end, uptime: 10.1)
        trace.record(id: 1, phase: .ended, point: end, uptime: 10.2)
        let receipt = UUID()
        let observation = try XCTUnwrap(trace.observation(probe: .horizontalLarge, receipt: receipt))
        XCTAssertEqual(observation.receiptToken, receipt)
        XCTAssertEqual(observation.start, start)
        XCTAssertEqual(observation.end, end)
        XCTAssertEqual(observation.contactCount, 1)
        XCTAssertEqual(observation.movedEventCount, 1)
        XCTAssertTrue(observation.endedNormally)
        XCTAssertEqual(observation.startedUptime, 10)
        XCTAssertEqual(observation.endedUptime, 10.2)
    }

    func testBrokenTouchAndCancellationRemainVisibleToCoreValidation() throws {
        var trace = BluetoothCalibrationContactTrace()
        let point = DevicePoint(x: 0.35, y: 0.35)
        trace.record(id: 1, phase: .began, point: point, uptime: 10)
        trace.record(id: 1, phase: .ended, point: point, uptime: 10.02)
        trace.record(id: 2, phase: .began, point: point, uptime: 10)
        trace.record(id: 2, phase: .moved, point: DevicePoint(x: 0.5, y: 0.35), uptime: 10.1)
        let broken = try XCTUnwrap(trace.observation(probe: .horizontalLarge, receipt: UUID()))
        XCTAssertEqual(broken.contactCount, 2)
        XCTAssertEqual(broken.movedEventCount, 0)
        XCTAssertEqual(broken.end, point)

        var cancelled = BluetoothCalibrationContactTrace()
        cancelled.record(id: 1, phase: .began, point: point, uptime: 10)
        cancelled.record(id: 1, phase: .moved, point: DevicePoint(x: 0.5, y: 0.35), uptime: 10.1)
        cancelled.record(id: 1, phase: .cancelled, point: point, uptime: 10.2)
        XCTAssertFalse(try XCTUnwrap(cancelled.observation(probe: .horizontalLarge, receipt: UUID())).endedNormally)
    }
}
