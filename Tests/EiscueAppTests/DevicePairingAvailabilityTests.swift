import Foundation
import XCTest
@testable import Eiscue

final class DevicePairingAvailabilityTests: XCTestCase {
    func testSystemPairingStartsWithIOS27WithoutRaisingAppMinimum() {
        XCTAssertFalse(DevicePairingSupport.supportsSystemPairing(on: version(26, 0, 0)))
        XCTAssertFalse(DevicePairingSupport.supportsSystemPairing(on: version(26, 5, 2)))
        XCTAssertTrue(DevicePairingSupport.supportsSystemPairing(on: version(27, 0, 0)))
        XCTAssertTrue(DevicePairingSupport.supportsSystemPairing(on: version(28, 0, 0)))
    }

    @MainActor
    func testIOS26PairingReturnsImportGuidanceBeforeStartingWork() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 else {
            throw XCTSkip("This case verifies the iOS 26 early rejection.")
        }
        let model = AppModel()
        let originalOperationID = model.deviceOperationID

        model.startPairing()

        XCTAssertEqual(model.connectionMessage, String(localized: "connection.requiresUSBPairing"))
        XCTAssertFalse(model.isPairing)
        XCTAssertNil(model.pairingTask)
        XCTAssertNil(model.pairingLeaseID)
        XCTAssertNil(model.pairingCode)
        XCTAssertEqual(model.deviceOperationID, originalOperationID)
    }

    private func version(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }
}
