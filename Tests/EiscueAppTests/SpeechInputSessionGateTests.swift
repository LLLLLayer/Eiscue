import Foundation
import XCTest
@testable import Eiscue

final class SpeechInputSessionGateTests: XCTestCase {
    func testOverlappingTapAndHoldCannotStartTwoSessions() throws {
        var gate = SpeechInputSessionGate()
        let token = try XCTUnwrap(gate.begin(mode: .toggle))
        XCTAssertNil(gate.begin(mode: .hold))
        XCTAssertTrue(gate.accepts(token))
        XCTAssertEqual(gate.mode, .toggle)
    }

    func testReleaseBeforePermissionCompletesRejectsLateStart() throws {
        var gate = SpeechInputSessionGate()
        let heldToken = try XCTUnwrap(gate.begin(mode: .hold))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(heldToken))
        XCTAssertNil(gate.mode)
        XCTAssertNil(gate.token)
    }

    func testOldRecognitionAndTimeoutCannotFinishANewerUtterance() throws {
        var gate = SpeechInputSessionGate()
        let old = try XCTUnwrap(gate.begin(mode: .hold))
        gate.invalidate()
        let current = try XCTUnwrap(gate.begin(mode: .toggle))
        XCTAssertFalse(gate.accepts(old))
        XCTAssertTrue(gate.accepts(current))
    }

    func testCompletionInvalidationMakesDeliveryAtMostOnce() throws {
        var gate = SpeechInputSessionGate()
        let token = try XCTUnwrap(gate.begin(mode: .toggle))
        XCTAssertTrue(gate.accepts(token))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(token))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(token))
    }
}
