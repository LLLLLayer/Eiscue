@_exported import EiscueDeviceCore
import Foundation

/// The full product preserves developer-services defaults. The HID product
/// exposes only controller injection and cannot link this backend implicitly.
public extension DeviceClient {
    init() {
        self.init(identityStore: KeychainPairingIdentityStore())
    }

    init(identityStore: any PairingIdentityStore) {
        let local = LocalDeviceController(identityStore: identityStore)
        self.init(actuator: local, networkSetup: local)
    }

    #if DEBUG
    /// Explicit development probe. Never marks device control ready or sends input.
    func probeLegacyDeveloperServices(configuration: LocalVPNConfiguration = .defaults) async throws -> Data {
        guard let local = networkSetup else { throw DeviceControlError.routeUnsupported(.localVPN) }
        return try await local.probeLegacyDeveloperServices(configuration: configuration)
    }
    #endif
}
