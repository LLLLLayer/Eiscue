import EiscueDeviceCore
import Foundation
import XCTest
@testable import EiscueHID

@MainActor final class HIDBuildTests: XCTestCase {
    func testFreshAndSavedNetworkRoutesStartDisconnectedOnHID() throws {
        for saved in [nil, "localVPN", "usbBoard", "wirelessBoard", "bluetoothBoard"] as [String?] {
            let fixture = try HIDFixture(savedMethod: saved)
            XCTAssertEqual(fixture.model.deviceConnectionMethod, .bluetoothBoard)
            XCTAssertNil(fixture.model.networkDeviceClient)
            XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
            XCTAssertFalse(fixture.model.isDeviceReady)
            XCTAssertFalse(fixture.model.isConnecting)
            XCTAssertEqual(DeviceBuildCapabilities.methods, [.bluetoothBoard])
        }
    }

    func testUnsupportedRouteSelectionNeverReleasesOrReplacesHIDClient() async throws {
        let fixture = try HIDFixture()
        let controller = HIDRecordingController()
        fixture.model.deviceClient = DeviceClient(controller: controller)
        for method in [DeviceConnectionMethod.localVPN, .usbBoard] {
            await fixture.model.selectDeviceConnectionMethod(method)
            XCTAssertEqual(fixture.model.deviceConnectionMethod, .bluetoothBoard)
            XCTAssertNil(fixture.model.networkDeviceClient)
            XCTAssertFalse(fixture.model.isChangingDeviceConnectionMethod)
        }
        let disconnects = await controller.disconnects
        XCTAssertEqual(disconnects, 0)
        let status = await fixture.model.deviceClient.status()
        XCTAssertEqual(status, .unavailable(reason: "injected HID controller"))
    }

    func testHIDTunnelIsUnavailableAndScreenSharingUsesItsOwnAppGroup() async throws {
        let tunnel = LocalTunnelManager()
        do {
            try await tunnel.start()
            XCTFail("The HID distribution cannot start a network tunnel.")
        } catch { XCTAssertEqual(error as? DeviceControlError, .unsupported) }
        XCTAssertFalse(tunnel.isConnected)
        XCTAssertFalse(tunnel.isTransitioning)
        XCTAssertEqual(Bundle.main.bundleIdentifier, "org.eiscue.hid")
        XCTAssertEqual(ScreenBroadcastStore.configuredAppGroupIdentifier, "group.org.eiscue.hid")
    }
}

@MainActor private final class HIDFixture {
    let suite = "HIDBuildTests.\(UUID().uuidString)"
    let model: AppModel

    init(savedMethod: String? = nil) throws {
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        if let savedMethod { preferences.set(savedMethod, forKey: "deviceConnectionMethod") }
        model = AppModel(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
                         preferences: preferences, credentialStore: CredentialStore(service: suite))
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

private actor HIDRecordingController: DeviceController {
    var disconnects = 0
    func status() async -> DeviceStatus { .unavailable(reason: "injected HID controller") }
    func disconnect() async { disconnects += 1 }
}
