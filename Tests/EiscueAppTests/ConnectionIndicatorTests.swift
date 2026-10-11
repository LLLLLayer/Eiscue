import XCTest
@testable import Eiscue

final class ConnectionIndicatorTests: XCTestCase {
    func testPairingDoesNotImplyReadyAndNormalDisconnectionIsNotError() {
        XCTAssertEqual(ConnectionIndicatorState.resolve(isReady: false, isConnecting: false, hasIdentity: false, hasError: false), .unpaired)
        XCTAssertEqual(ConnectionIndicatorState.resolve(isReady: false, isConnecting: false, hasIdentity: true, hasError: false), .paired)
        XCTAssertEqual(ConnectionIndicatorState.resolve(isReady: true, isConnecting: false, hasIdentity: true, hasError: false), .ready)
    }
    func testFailureAndRetryAreVisible() {
        XCTAssertEqual(ConnectionIndicatorState.resolve(isReady: false, isConnecting: false, hasIdentity: true, hasError: true), .failed)
        XCTAssertEqual(ConnectionIndicatorState.resolve(isReady: false, isConnecting: true, hasIdentity: true, hasError: true), .connecting)
    }
}
