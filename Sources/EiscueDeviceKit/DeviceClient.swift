import Foundation

public struct DeviceClient: Sendable {
    private let controller: any DeviceController

    public init() {
        controller = LocalDeviceController(identityStore: KeychainPairingIdentityStore())
    }

    public init(identityStore: any PairingIdentityStore) {
        controller = LocalDeviceController(identityStore: identityStore)
    }

    public init(controller: any DeviceController) {
        self.controller = controller
    }

    public func status() async -> DeviceStatus {
        await controller.status()
    }
    public func hasPairingIdentity() async throws -> Bool { try await controller.hasPairingIdentity() }
    public func importPairingIdentity(_ data: Data) async throws { try await controller.importPairingIdentity(data) }
    public func removePairingIdentity() async throws { try await controller.removePairingIdentity() }
    public func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> { await controller.beginPairing() }
    public func beginPairing(configuration: LocalVPNConfiguration) async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        await controller.beginPairing(configuration: configuration)
    }
    public func connect(method: DeviceConnectionMethod, configuration: LocalVPNConfiguration = .defaults) async throws {
        switch method {
        case .bluetoothBoard: try await controller.connectBluetoothBoard()
        case .localVPN: try await controller.connectLocalVPN(configuration: configuration)
        case .usbBoard: try await controller.connectUSBBoard()
        }
    }
    public func connectLocalVPN(configuration: LocalVPNConfiguration = .defaults) async throws { try await controller.connectLocalVPN(configuration: configuration) }
    public func connectUSBBoard() async throws { try await controller.connectUSBBoard() }
    public func connectBluetoothBoard() async throws { try await controller.connectBluetoothBoard() }
    #if DEBUG
    /// Explicit development probe. Never marks device control ready or sends input.
    public func probeLegacyDeveloperServices(configuration: LocalVPNConfiguration = .defaults) async throws -> Data {
        guard let local = controller as? LocalDeviceController else { throw DeviceControlError.unsupported }
        return try await local.probeLegacyDeveloperServices(configuration: configuration)
    }
    #endif
    public func finishTask() async throws { try await controller.finishTask() }
    public func disconnect() async { await controller.disconnect() }
    public func captureScreenshot() async throws -> DeviceScreenshot { try await controller.captureScreenshot() }
    public func tap(at point: DevicePoint, frameID: UUID) async throws { try await controller.tap(at: point, frameID: frameID) }
    public func swipe(from: DevicePoint, to: DevicePoint, duration: Duration = .milliseconds(500), frameID: UUID) async throws {
        try await controller.swipe(from: from, to: to, duration: duration, frameID: frameID)
    }
    public func typeText(_ text: String) async throws { try await controller.typeText(text) }
    public func typeText(_ text: String, frameID: UUID) async throws { try await controller.typeText(text, frameID: frameID) }
    public func launchApplication(bundleID: String) async throws { try await controller.launchApplication(bundleID: bundleID) }
    public func home() async throws { try await controller.home() }
    public func pressKey(_ key: DeviceKeyboardAction, frameID: UUID) async throws { try await controller.pressKey(key, frameID: frameID) }
    public func listApplications() async throws -> [DeviceApplication] { try await controller.listApplications() }
}
