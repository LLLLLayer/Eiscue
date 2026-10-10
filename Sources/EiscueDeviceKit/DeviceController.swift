import Foundation

public enum DeviceCapability: String, Codable, Sendable, CaseIterable {
    case screenshot
    case tap
    case swipe
    case textInput
    case launchApplication
    case home
    case listApplications
}

public enum DeviceStatus: Sendable, Equatable {
    case unavailable(reason: String)
    case ready(capabilities: Set<DeviceCapability>)
}

/// Replaceable control surface. Hosts may inject their own implementation.
public protocol DeviceController: Sendable {
    func status() async -> DeviceStatus
    func hasPairingIdentity() async throws -> Bool
    func importPairingIdentity(_ data: Data) async throws
    func removePairingIdentity() async throws
    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error>
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws
    func disconnect() async
    func captureScreenshot() async throws -> DeviceScreenshot
    func tap(at point: DevicePoint, frameID: UUID) async throws
    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws
    func typeText(_ text: String) async throws
    func typeText(_ text: String, frameID: UUID) async throws
    func launchApplication(bundleID: String) async throws
    func home() async throws
    func listApplications() async throws -> [DeviceApplication]
}

public extension DeviceController {
    func hasPairingIdentity() async throws -> Bool { false }
    func importPairingIdentity(_ data: Data) async throws { throw DeviceControlError.unsupported }
    func removePairingIdentity() async throws { throw DeviceControlError.unsupported }
    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: DeviceControlError.unsupported) }
    }
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws { throw DeviceControlError.unsupported }
    func disconnect() async {}
    func captureScreenshot() async throws -> DeviceScreenshot { throw DeviceControlError.notConnected }
    func tap(at point: DevicePoint, frameID: UUID) async throws { throw DeviceControlError.notConnected }
    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws { throw DeviceControlError.notConnected }
    func typeText(_ text: String) async throws { throw DeviceControlError.notConnected }
    func typeText(_ text: String, frameID: UUID) async throws { try await typeText(text) }
    func launchApplication(bundleID: String) async throws { throw DeviceControlError.notConnected }
    func home() async throws { throw DeviceControlError.notConnected }
    func listApplications() async throws -> [DeviceApplication] { throw DeviceControlError.notConnected }
}
