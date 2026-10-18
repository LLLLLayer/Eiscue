#if DEBUG
import EiscueDeviceCore
import Foundation
@preconcurrency import PhoneAgentNCM

@MainActor protocol LocalDeviceConnectionDiagnosing: AnyObject, Sendable {
    var connectionDiagnostic: [String: String] { get }
}
extension LocalDeviceController: LocalDeviceConnectionDiagnosing {}

public extension DeviceClient {
    /// Allowlisted phase/category/numeric codes only. Retained across disconnect
    /// so DEBUG acceptance can read the original failure after normal cleanup.
    func debugConnectionDiagnostic() async -> [String: String]? {
        guard let source = networkSetup as? any LocalDeviceConnectionDiagnosing else { return nil }
        return await source.connectionDiagnostic
    }
}

enum LocalDeviceConnectionDiagnostic {
    static func metadata(_ error: any Error) -> [String: String] {
        switch error {
        case NativeBackendError.protocolFailure(let stage, let cause):
            ["category": "nativeProtocol", "stage": String(stage), "cause": String(cause)]
        case NativeBackendError.touchPreparationFailure(let stage, let cause):
            ["category": "nativeTouchPreparation", "stage": String(stage), "cause": String(cause)]
        case NativeBackendError.transport(let code):
            ["category": "nativeTransport", "code": String(code)]
        case LocalVPNError.inactive: ["category": "vpnInactive"]
        case LocalVPNError.ambiguousInterface: ["category": "vpnAmbiguousInterface"]
        case LocalVPNError.serviceNotFound: ["category": "vpnServiceNotFound"]
        case LocalVPNError.ambiguousService: ["category": "vpnAmbiguousService"]
        case LocalVPNError.discoveryDenied: ["category": "vpnDiscoveryDenied"]
        case LocalVPNError.invalidConfiguration: ["category": "vpnInvalidConfiguration"]
        case NCMError.timeout: ["category": "timeout"]
        case is CancellationError: ["category": "cancelled"]
        default: ["category": "other"]
        }
    }
}
#endif
