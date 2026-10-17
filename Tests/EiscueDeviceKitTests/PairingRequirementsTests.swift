import Foundation
import Testing
@testable import EiscueDeviceKit
@testable import EiscueDeviceCore

@Suite struct PairingRequirementsTests {
    @Test(arguments: [
        OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0),
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
        OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 2),
        OperatingSystemVersion(majorVersion: 26, minorVersion: 99, patchVersion: 99),
    ])
    func systemsWithoutDeviceInitiatedPairingFailImmediately(version: OperatingSystemVersion) {
        #expect(throws: DeviceControlError.systemPairingUnavailable) {
            try LocalPairingRequirements.validateSystemPairing(on: version)
        }
    }

    @Test(arguments: [
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
        OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0),
    ])
    func newerSystemsCanProceedToTheActualPairingChecks(version: OperatingSystemVersion) throws {
        try LocalPairingRequirements.validateSystemPairing(on: version)
    }

    @Test func unavailableReasonIsLocalizedAndKeepsTheAppMinimumSeparate() {
        let expected = NSLocalizedString("device.error.system-pairing-unavailable", bundle: EiscueDeviceResources.bundle,
                                         value: "MISSING RESOURCE", comment: "")
        #expect(expected != "MISSING RESOURCE")
        #expect(DeviceControlError.systemPairingUnavailable.localizedDescription == expected)
        #expect(expected.contains("27") && expected.contains("26"))
    }
}
