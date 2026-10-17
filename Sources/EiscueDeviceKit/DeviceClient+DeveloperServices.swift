@_exported import EiscueDeviceCore
import Foundation

/// The full product preserves developer-services defaults. The HID product
/// exposes only controller injection and cannot link this backend implicitly.
public extension DeviceClient {
    init() {
        self.init(controller: LocalDeviceController(identityStore: KeychainPairingIdentityStore()))
    }

    init(identityStore: any PairingIdentityStore) {
        self.init(controller: LocalDeviceController(identityStore: identityStore))
    }

    #if DEBUG
    /// Explicit development probe. Never marks device control ready or sends input.
    func probeLegacyDeveloperServices(configuration: LocalVPNConfiguration = .defaults) async throws -> Data {
        guard let local = controller as? LocalDeviceController else { throw DeviceControlError.unsupported }
        return try await local.probeLegacyDeveloperServices(configuration: configuration)
    }
    #endif
}
