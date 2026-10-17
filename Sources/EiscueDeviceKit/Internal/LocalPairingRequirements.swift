import EiscueDeviceCore
import Foundation

/// This backend implements the device-initiated PairableHost responder.
/// The matching Settings entry first exists in iOS 27; Developer Mode alone
/// does not enable that pairing direction on earlier systems.
/// Existing imported identities use a separate connection path.
enum LocalPairingRequirements {
    static func validateSystemPairing(on version: OperatingSystemVersion) throws {
        guard version.majorVersion >= 27 else {
            throw DeviceControlError.systemPairingUnavailable
        }
    }
}
