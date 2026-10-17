import Foundation

public struct DeviceClient: Sendable {
    public let device: GuardedDevice
    public let networkSetup: (any NetworkRouteSetup)?
    public let hidSetup: (any HIDRouteSetup)?

    public init(actuator: any DeviceActuator, networkSetup: (any NetworkRouteSetup)? = nil, hidSetup: (any HIDRouteSetup)? = nil) {
        device = GuardedDevice(actuator: actuator); self.networkSetup = networkSetup; self.hidSetup = hidSetup
    }
    public func status() async -> DeviceStatus { await device.status() }
    public func probe() async -> DeviceStatus { await device.probe() }
    public func hasPairingIdentity() async throws -> Bool { try await network().hasPairingIdentity() }
    public func importPairingIdentity(_ data: Data) async throws { await device.invalidate(); try await network().importPairingIdentity(data) }
    public func removePairingIdentity() async throws { await device.invalidate(); try await network().removePairingIdentity() }
    public func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        guard let networkSetup else { return AsyncThrowingStream { $0.finish(throwing: DeviceControlError.routeUnsupported(.localVPN)) } }
        await device.invalidate(); return await networkSetup.beginPairing()
    }
    public func beginPairing(configuration: LocalVPNConfiguration) async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        guard let networkSetup else { return AsyncThrowingStream { $0.finish(throwing: DeviceControlError.routeUnsupported(.localVPN)) } }
        await device.invalidate(); return await networkSetup.beginPairing(configuration: configuration)
    }
    public func connect(method: DeviceConnectionMethod, configuration: LocalVPNConfiguration = .defaults, backend: DeviceControlBackend = .automatic) async throws {
        await device.invalidate()
        switch method {
        case .bluetoothBoard:
            guard let hidSetup else { throw DeviceControlError.routeUnsupported(method) }
            try await hidSetup.connectBluetoothBoard()
        case .localVPN: try await network().connectLocalVPN(configuration: configuration, backend: backend)
        case .usbBoard: try await network(route: .usbBoard).connectUSBBoard(backend: backend)
        }
        await device.connectionDidOpen()
    }
    public func connectLocalVPN(configuration: LocalVPNConfiguration = .defaults, backend: DeviceControlBackend = .automatic) async throws { try await connect(method: .localVPN, configuration: configuration, backend: backend) }
    public func connectUSBBoard(backend: DeviceControlBackend = .automatic) async throws { try await connect(method: .usbBoard, backend: backend) }
    public func connectBluetoothBoard() async throws { try await connect(method: .bluetoothBoard) }
    public func finishTask() async throws { try await device.finishTask() }
    public func disconnect() async { _ = await device.disconnect() }
    public func disconnectAndConfirmRelease() async -> Bool { await device.disconnect() == .confirmed }
    public func captureScreenshot() async throws -> DeviceScreenshot { try await device.captureScreenshot() }
    public func perform(_ action: DeviceAction, frameID: UUID) async throws { try await device.perform(action, frameID: frameID) }
    public func tap(at point: DevicePoint, frameID: UUID) async throws { try await perform(.tap(point), frameID: frameID) }
    public func swipe(from: DevicePoint, to: DevicePoint, duration: Duration = .milliseconds(500), frameID: UUID) async throws { try await perform(.swipe(from, to, duration), frameID: frameID) }
    public func typeText(_ text: String, frameID: UUID) async throws { try await perform(.typeText(text), frameID: frameID) }
    public func launchApplication(bundleID: String, frameID: UUID) async throws { try await perform(.launch(bundleID: bundleID), frameID: frameID) }
    public func home(frameID: UUID) async throws { try await perform(.home, frameID: frameID) }
    public func pressKey(_ key: DeviceKeyboardAction, frameID: UUID) async throws { try await perform(.pressKey(key), frameID: frameID) }
    public func listApplications() async throws -> [DeviceApplication] { try await device.listApplications() }
    private func network(route: DeviceConnectionMethod = .localVPN) throws -> any NetworkRouteSetup {
        guard let networkSetup else { throw DeviceControlError.routeUnsupported(route) }
        return networkSetup
    }
}
