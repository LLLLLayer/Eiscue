#if DEBUG
import EiscueDeviceCore
import Foundation
import UIKit

enum DebugDevicePageFixture {
    static var isEnabled: Bool {
        guard DeviceBuildCapabilities.supportsDeveloperServices else { return false }
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--local-device-ready-fixture")
    }

    static var isSpeechEnabled: Bool {
        isEnabled && ProcessInfo.processInfo.arguments.contains("--speech-device-ready-fixture")
    }

    static var failsSpeechReconnection: Bool {
        isSpeechEnabled && ProcessInfo.processInfo.arguments.contains("--speech-device-reconnect-failure")
    }

    static var delaysSpeechReconnection: Bool {
        isSpeechEnabled && ProcessInfo.processInfo.arguments.contains("--speech-device-reconnect-delay")
    }

    static var isOnboardingEnabled: Bool {
        guard DeviceBuildCapabilities.supportsDeveloperServices else { return false }
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") &&
            (arguments.contains("--onboarding-pairing-fixture") || arguments.contains("--onboarding-saved-pairing-fixture"))
    }
}

extension AppModel {
    func installOnboardingPairingFixture() {
        guard DebugDevicePageFixture.isOnboardingEnabled else { return }
        bluetoothMonitor?.cancel(); bluetoothMonitor = nil
        localTunnel.onDisconnect = nil
        let saved = ProcessInfo.processInfo.arguments.contains("--onboarding-saved-pairing-fixture")
        let client = DeviceClient(controller: OnboardingPairingFixtureController(hasIdentity: saved))
        // Both sides of the route switch remain in memory; this fixture must not
        // read a pairing Keychain item or connect to any device.
        deviceClient = client
        networkDeviceClient = client
        deviceConnectionMethod = .localVPN
        activeDeviceConnectionMethod = nil
        activeDeviceControlBackend = nil
        hasPairingIdentity = saved
        deviceStatus = .unavailable(reason: String(localized: "connection.disconnected", table: "Runtime"))
        deviceConnectionError = nil
        showsOnboarding = true
        isLoading = false
        didLoad = true
    }

    func installLocalDevicePageFixture() {
        guard DebugDevicePageFixture.isEnabled else { return }
        // This view fixture never starts a real connection or reads a device screen.
        bluetoothMonitor?.cancel(); bluetoothMonitor = nil
        localTunnel.onDisconnect = nil
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 640), format: format).image { context in
            UIColor.systemGray6.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 640))
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 20, y: 80, width: 280, height: 200), cornerRadius: 24).fill()
            UIColor.darkGray.setFill()
            UIBezierPath(roundedRect: CGRect(x: 40, y: 108, width: 100, height: 16), cornerRadius: 8).fill()
            UIColor.lightGray.setFill()
            for index in 0..<3 {
                UIBezierPath(roundedRect: CGRect(x: 40, y: 152 + index * 32, width: 240, height: 12), cornerRadius: 6).fill()
            }
        }
        let speechFixture = DebugDevicePageFixture.isSpeechEnabled
        let client = DeviceClient(controller: DevicePageFixtureController(imageData: image.pngData()!,
            allowsReconnection: speechFixture, failsReconnection: DebugDevicePageFixture.failsSpeechReconnection,
            delaysReconnection: DebugDevicePageFixture.delaysSpeechReconnection))
        deviceClient = client
        networkDeviceClient = client
        // Exercise the same CoreDevice media handoff without a simulator VPN.
        if speechFixture { deviceControlBackend = .coreDevice }
        deviceConnectionMethod = speechFixture ? .usbBoard : .localVPN
        activeDeviceConnectionMethod = deviceConnectionMethod
        activeDeviceControlBackend = deviceControlBackend.resolved(on: ProcessInfo.processInfo.operatingSystemVersion)
        hasPairingIdentity = true
        deviceStatus = .ready(capabilities: [.screenshot, .tap, .swipe, .textInput])
        deviceConnectionError = nil
        connectionMessage = String(localized: "connection.ready")
        showsOnboarding = false
        isLoading = false
        didLoad = true
    }
}

private actor OnboardingPairingFixtureController: DeviceController {
    private var hasIdentity: Bool

    init(hasIdentity: Bool) { self.hasIdentity = hasIdentity }

    func status() async -> DeviceStatus { .unavailable(reason: String(localized: "connection.disconnected", table: "Runtime")) }
    func hasPairingIdentity() async throws -> Bool { hasIdentity }
    func removePairingIdentity() async throws { hasIdentity = false }
}

private actor DevicePageFixtureController: DeviceController {
    private let imageData: Data
    private let allowsReconnection: Bool
    private let failsReconnection: Bool
    private let delaysReconnection: Bool
    private var connected = true

    init(imageData: Data, allowsReconnection: Bool, failsReconnection: Bool, delaysReconnection: Bool) {
        self.imageData = imageData
        self.allowsReconnection = allowsReconnection
        self.failsReconnection = failsReconnection
        self.delaysReconnection = delaysReconnection
    }

    func status() async -> DeviceStatus {
        connected ? .ready(capabilities: [.screenshot, .tap, .swipe, .textInput]) : .unavailable(reason: "Fixture disconnected")
    }

    func hasPairingIdentity() async throws -> Bool { true }
    func disconnect() async { connected = false }
    func disconnectAndConfirmRelease() async -> Bool { await disconnect(); return true }

    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws {
        try await reconnect(backend: backend)
    }

    func connectUSBBoard(backend: DeviceControlBackend) async throws {
        try await reconnect(backend: backend)
    }

    private func reconnect(backend: DeviceControlBackend) async throws {
        guard allowsReconnection, backend == .coreDevice else { throw DeviceControlError.unsupported }
        guard !failsReconnection else { throw DeviceControlError.notConnected }
        if delaysReconnection { try await Task.sleep(for: .seconds(30)) }
        connected = true
    }

    func captureScreenshot() async throws -> DeviceScreenshot {
        guard connected else { throw DeviceControlError.notConnected }
        return DeviceScreenshot(width: 320, height: 640, mimeType: "image/png", data: imageData)
    }
}
#endif
