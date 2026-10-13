#if DEBUG
import EiscueDeviceKit
import Foundation
import UIKit

enum DebugDevicePageFixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--local-device-ready-fixture")
    }
}

extension AppModel {
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
        let client = DeviceClient(controller: DevicePageFixtureController(imageData: image.pngData()!))
        deviceClient = client
        networkDeviceClient = client
        deviceConnectionMethod = .localVPN
        activeDeviceConnectionMethod = .localVPN
        hasPairingIdentity = true
        deviceStatus = .ready(capabilities: [.screenshot, .tap, .swipe, .textInput])
        deviceConnectionError = nil
        connectionMessage = String(localized: "connection.ready")
        showsOnboarding = false
        isLoading = false
        didLoad = true
    }
}

private actor DevicePageFixtureController: DeviceController {
    private let imageData: Data
    private var connected = true

    init(imageData: Data) { self.imageData = imageData }

    func status() async -> DeviceStatus {
        connected ? .ready(capabilities: [.screenshot, .tap, .swipe, .textInput]) : .unavailable(reason: "Fixture disconnected")
    }

    func hasPairingIdentity() async throws -> Bool { true }
    func disconnect() async { connected = false }

    func captureScreenshot() async throws -> DeviceScreenshot {
        guard connected else { throw DeviceControlError.notConnected }
        return DeviceScreenshot(width: 320, height: 640, mimeType: "image/png", data: imageData)
    }
}
#endif
