import EiscueDeviceCore
import EiscueDeviceKit
import Foundation

/// Test-only route fixture. Operation methods preserve each scenario's counters
/// and failure injection while the production GuardedDevice supplies authority.
protocol DeviceFixtureActuator: Actor, DeviceActuator, NetworkRouteSetup {
    var fixtureObservedFrameID: UUID? { get set }
    var fixtureGeometry: DeviceFrameGeometry? { get set }
    func status() async -> DeviceStatus
    func captureScreenshot() async throws -> DeviceScreenshot
    func tap(at point: DevicePoint, frameID: UUID) async throws
    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws
    func typeText(_ text: String, frameID: UUID) async throws
    func pressKey(_ key: DeviceKeyboardAction, frameID: UUID) async throws
    func home() async throws
    func launchApplication(bundleID: String) async throws
    func fixtureReleaseInput() async throws
    func fixtureDisconnect() async
    func fixtureDisconnectAndConfirmRelease() async -> Bool
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws
    func connectUSBBoard() async throws
}

extension DeviceFixtureActuator {
    func fixtureLog(_ kind: String, _ detail: String) {
        if kind == "observation.captured", let value = detail.components(separatedBy: "frame=").last {
            fixtureObservedFrameID = UUID(uuidString: value)
        }
    }
    func cachedStatus() async -> DeviceStatus { await status() }
    func probe() async -> DeviceStatus { await cachedStatus() }
    func capture() async throws -> DeviceScreenshot {
        let image = try await captureScreenshot()
        if fixtureGeometry?.width != image.width || fixtureGeometry?.height != image.height {
            fixtureGeometry = DeviceFrameGeometry(sessionID: UUID(), revision: UUID().uuidString, width: image.width, height: image.height)
        }
        return DeviceScreenshot(frameID: image.frameID, capturedAt: image.capturedAt, width: image.width,
            height: image.height, mimeType: image.mimeType, data: image.data, geometry: fixtureGeometry)
    }
    func frameState() async throws -> DeviceFrameState {
        guard let fixtureGeometry else { throw DeviceControlError.staleFrame }
        return DeviceFrameState(geometry: fixtureGeometry, isLive: true)
    }
    func perform(_ action: EiscueDeviceCore.DeviceAction, frame: FrameGrant) async throws -> SubmissionResult {
        do {
            switch action {
            case .tap(let p): try await tap(at: p, frameID: frame.frameID)
            case .swipe(let a, let b, let d): try await swipe(from: a, to: b, duration: d, frameID: frame.frameID)
            case .typeText(let text): try await typeText(text, frameID: frame.frameID)
            case .pressKey(let key): try await pressKey(key, frameID: frame.frameID)
            case .home: try await home()
            case .launch(let bundleID): try await launchApplication(bundleID: bundleID)
            }
            return .submitted
        } catch let error as DeviceControlError {
            if error.isDeliveryUnknown { throw error }
            return .notSubmitted(error)
        }
    }
    func releaseInput() async throws { fixtureGeometry = nil; try await fixtureReleaseInput() }
    func disconnect() async -> ReleaseConfirmation { fixtureGeometry = nil; return await fixtureDisconnectAndConfirmRelease() ? .confirmed : .unconfirmed }
    func fixtureDisconnectAndConfirmRelease() async -> Bool { await fixtureDisconnect(); return false }
    func fixtureDisconnect() async {}
    func fixtureReleaseInput() async throws {}
    func captureScreenshot() async throws -> DeviceScreenshot { throw DeviceControlError.notConnected }
    func tap(at point: DevicePoint, frameID: UUID) async throws { throw DeviceControlError.capabilityUnavailable(.tap) }
    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws { throw DeviceControlError.capabilityUnavailable(.swipe) }
    func typeText(_ text: String, frameID: UUID) async throws { throw DeviceControlError.capabilityUnavailable(.textInput) }
    func pressKey(_ key: DeviceKeyboardAction, frameID: UUID) async throws { throw DeviceControlError.capabilityUnavailable(.keyboardNavigation) }
    func home() async throws { throw DeviceControlError.capabilityUnavailable(.home) }
    func launchApplication(bundleID: String) async throws { throw DeviceControlError.capabilityUnavailable(.launchApplication) }
    func listApplications() async throws -> [DeviceApplication] { [] }
    func hasPairingIdentity() async throws -> Bool { false }
    func importPairingIdentity(_ data: Data) async throws {}
    func removePairingIdentity() async throws {}
    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func beginPairing(configuration: LocalVPNConfiguration) async -> AsyncThrowingStream<DevicePairingEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws { throw DeviceControlError.routeUnsupported(.localVPN) }
    func connectUSBBoard() async throws { throw DeviceControlError.routeUnsupported(.usbBoard) }
    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws {
        guard backend == .automatic else { throw DeviceControlError.serviceUnavailable(.developerServices) }
        try await connectLocalVPN(configuration: configuration)
    }
    func connectUSBBoard(backend: DeviceControlBackend) async throws {
        guard backend == .automatic else { throw DeviceControlError.serviceUnavailable(.developerServices) }
        try await connectUSBBoard()
    }
    #if DEBUG
    func probeLegacyDeveloperServices(configuration: LocalVPNConfiguration) async throws -> Data { Data() }
    #endif
}
