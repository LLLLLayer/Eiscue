import Foundation

public enum DeviceCapability: String, Codable, Sendable, CaseIterable {
    case screenshot
    case tap
    case swipe
    case textInput
    case launchApplication
    case home
    case listApplications
    case keyboardNavigation
}

public enum DeviceKeyboardAction: String, Codable, Sendable, CaseIterable {
    case search
    case enter
    case escape
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
    func beginPairing(configuration: LocalVPNConfiguration) async -> AsyncThrowingStream<DevicePairingEvent, Error>
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws
    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws
    func connectUSBBoard() async throws
    func connectUSBBoard(backend: DeviceControlBackend) async throws
    func connectBluetoothBoard() async throws
    /// End this task's input and invalidate its observations. Controllers may
    /// retain their connection; the default closes it for existing integrations.
    func finishTask() async throws
    func disconnect() async
    /// Disconnect and report whether the backend confirmed media release.
    /// Existing controllers return false because closure alone is not proof.
    func disconnectAndConfirmRelease() async -> Bool
    func captureScreenshot() async throws -> DeviceScreenshot
    func tap(at point: DevicePoint, frameID: UUID) async throws
    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws
    func typeText(_ text: String) async throws
    func typeText(_ text: String, frameID: UUID) async throws
    func launchApplication(bundleID: String) async throws
    func home() async throws
    func pressKey(_ key: DeviceKeyboardAction, frameID: UUID) async throws
    func listApplications() async throws -> [DeviceApplication]
}

public extension DeviceController {
    func hasPairingIdentity() async throws -> Bool { false }
    func importPairingIdentity(_ data: Data) async throws { throw DeviceControlError.unsupported }
    func removePairingIdentity() async throws { throw DeviceControlError.unsupported }
    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: DeviceControlError.unsupported) }
    }
    func beginPairing(configuration: LocalVPNConfiguration) async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: DeviceControlError.unsupported) }
    }
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws { throw DeviceControlError.unsupported }
    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws {
        guard backend == .automatic else { throw DeviceControlError.unsupported }
        try await connectLocalVPN(configuration: configuration)
    }
    func connectUSBBoard() async throws { throw DeviceControlError.unsupported }
    func connectUSBBoard(backend: DeviceControlBackend) async throws {
        guard backend == .automatic else { throw DeviceControlError.unsupported }
        try await connectUSBBoard()
    }
    func connectBluetoothBoard() async throws { throw DeviceControlError.unsupported }
    func finishTask() async throws { await disconnect() }
    func disconnect() async {}
    func disconnectAndConfirmRelease() async -> Bool { await disconnect(); return false }
    func captureScreenshot() async throws -> DeviceScreenshot { throw DeviceControlError.notConnected }
    func tap(at point: DevicePoint, frameID: UUID) async throws { throw DeviceControlError.notConnected }
    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws { throw DeviceControlError.notConnected }
    func typeText(_ text: String) async throws { throw DeviceControlError.notConnected }
    func typeText(_ text: String, frameID: UUID) async throws { try await typeText(text) }
    func launchApplication(bundleID: String) async throws { throw DeviceControlError.notConnected }
    func home() async throws { throw DeviceControlError.notConnected }
    func pressKey(_ key: DeviceKeyboardAction, frameID: UUID) async throws { throw DeviceControlError.unsupported }
    func listApplications() async throws -> [DeviceApplication] { throw DeviceControlError.notConnected }
}
