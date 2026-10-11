import EiscueDeviceKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class DeviceConnectionMethodTests: XCTestCase {
    func testExistingPreferencesDefaultToAppConnectionAndSelectionPersists() async throws {
        let fixture = try Fixture()
        let model = fixture.model
        XCTAssertEqual(model.deviceConnectionMethod, .localVPN)
        await model.selectDeviceConnectionMethod(.usbBoard)
        XCTAssertEqual(model.deviceConnectionMethod, .usbBoard)
        XCTAssertEqual(fixture.preferences.string(forKey: "deviceConnectionMethod"), "usbBoard")
        let restored = AppModel(storageDirectory: fixture.directory, preferences: fixture.preferences)
        XCTAssertEqual(restored.deviceConnectionMethod, .usbBoard)
        XCTAssertNil(model.localTunnel.lastError, "Selecting a board must not try to start the VPN on a simulator.")
    }

    func testUnknownSavedMethodSafelyDefaultsToPreviousVPNMethod() throws {
        let fixture = try Fixture(savedMethod: "future-unsupported-method")
        XCTAssertEqual(fixture.model.deviceConnectionMethod, .localVPN)
    }

    func testBoardPrimaryActionNeverStartsLocalVPNAndUsesOnlyBoardKitAPI() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard")
        await fixture.model.enableDeviceControl()
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods, [.usbBoard])
        XCTAssertEqual(fixture.model.activeDeviceConnectionMethod, .usbBoard)
        XCTAssertNil(fixture.model.localTunnel.lastError)
        XCTAssertFalse(fixture.model.localTunnel.isConnected)
        XCTAssertTrue(fixture.model.isDeviceReady, "Only the injected control-capable backend can grant readiness here.")
        await fixture.model.disconnectDevice()
    }

    func testBoardFailureDoesNotFallBackToVPNOrReportReady() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", failure: .connection("synthetic board missing"))
        await fixture.model.enableDeviceControl()
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods, [.usbBoard])
        XCTAssertEqual(fixture.model.deviceConnectionError, "synthetic board missing")
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
        XCTAssertNil(fixture.model.localTunnel.lastError)
    }

    func testDiagnosticSuccessCannotBecomeReadyInApp() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", grantsControl: false)
        await fixture.model.connectDevice()
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertEqual(fixture.model.connectionMessage, "synthetic diagnostic only")
        XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
        XCTAssertNotEqual(fixture.model.connectionMessage, String(localized: "connection.ready"))
    }

    func testVPNDisconnectCallbackLeavesBoardSessionAndScreenshotUntouched() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard")
        let model = fixture.model
        await model.connectDevice()
        let frame = DeviceScreenshot(width: 4, height: 4, mimeType: "image/png", data: Data())
        model.screenshot = frame
        let operationID = model.deviceOperationID
        let message = model.connectionMessage
        model.localTunnel.onDisconnect?()
        await Task.yield()
        XCTAssertEqual(model.deviceOperationID, operationID)
        XCTAssertEqual(model.screenshot, frame)
        XCTAssertEqual(model.connectionMessage, message)
        XCTAssertTrue(model.isDeviceReady)
        XCTAssertNil(model.deviceConnectionError)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 0)
        await model.disconnectDevice()
    }

    func testVPNDisconnectCallbackStillClosesVPNDeviceSession() async throws {
        let fixture = try Fixture()
        fixture.model.activeDeviceConnectionMethod = .localVPN
        fixture.model.deviceStatus = .ready(capabilities: [.screenshot])
        fixture.model.localTunnel.onDisconnect?()
        for _ in 0..<1000 {
            if await fixture.controller.calls().disconnects > 0 { break }
            await Task.yield()
        }
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 1)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
    }

    func testVPNReplacementCancelsPairingListenerAndLeaseBeforeAnIdentityCanBeSaved() async throws {
        let fixture = try Fixture()
        let pending = simulatedPendingPairing(in: fixture.model)
        fixture.model.localTunnel.onDisconnect?()
        for _ in 0..<1000 {
            if !fixture.model.isPairing && !fixture.model.isConnecting { break }
            await Task.yield()
        }
        await pending.value
        XCTAssertNil(fixture.model.pairingLeaseID)
        XCTAssertNil(fixture.model.pairingTask)
        XCTAssertNil(fixture.model.pairingCode)
        XCTAssertFalse(fixture.model.isPairing)
        XCTAssertFalse(fixture.model.hasPairingIdentity)
        XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
    }

    func testStoppingLocalTunnelCancelsPairingAndClearsItsLease() async throws {
        let fixture = try Fixture()
        let pending = simulatedPendingPairing(in: fixture.model)
        await fixture.model.stopLocalTunnel()
        await pending.value
        XCTAssertNil(fixture.model.pairingLeaseID)
        XCTAssertNil(fixture.model.pairingTask)
        XCTAssertNil(fixture.model.pairingCode)
        XCTAssertFalse(fixture.model.isPairing)
        XCTAssertFalse(fixture.model.hasPairingIdentity)
        XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
    }

    func testStoppingOwnedTunnelDoesNotDisconnectBoardControlOrPolluteIndicator() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard")
        await fixture.model.connectDevice()
        await fixture.model.stopLocalTunnel()
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 0)
        XCTAssertEqual(fixture.model.activeDeviceConnectionMethod, .usbBoard)
        XCTAssertTrue(fixture.model.isDeviceReady)
        XCTAssertEqual(fixture.model.connectionIndicator, .ready)
        await fixture.model.disconnectDevice()
    }

    func testSwitchingCancelsInFlightBoardConnectionAndClearsOldScreenshotBeforeSavingChoice() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", suspendsConnection: true)
        let model = fixture.model
        let pending = Task { await model.connectDevice() }
        for _ in 0..<1000 {
            if await fixture.controller.calls().methods == [.usbBoard] { break }
            await Task.yield()
        }
        XCTAssertTrue(model.isConnecting)
        model.screenshot = DeviceScreenshot(width: 4, height: 4, mimeType: "image/png", data: Data())
        await model.selectDeviceConnectionMethod(.localVPN)
        await pending.value
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods, [.usbBoard])
        XCTAssertEqual(calls.disconnects, 1)
        XCTAssertEqual(calls.cancelledConnections, 1)
        XCTAssertEqual(model.deviceConnectionMethod, .localVPN)
        XCTAssertEqual(fixture.preferences.string(forKey: "deviceConnectionMethod"), "localVPN")
        XCTAssertNil(model.screenshot)
        XCTAssertNil(model.deviceConnectionTask)
        XCTAssertNil(model.activeDeviceConnectionMethod)
        XCTAssertFalse(model.isConnecting || model.isChangingDeviceConnectionMethod)
        XCTAssertFalse(model.isDeviceReady)
        XCTAssertNil(model.deviceConnectionError, "The cancelled old connection must not overwrite the new method's state.")
    }

    func testMethodChangeIsBusyAndBlocksNewControlWork() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard")
        fixture.model.isChangingDeviceConnectionMethod = true
        XCTAssertTrue(fixture.model.isBusy)
        await fixture.model.connectDevice()
        await fixture.model.enableDeviceControl()
        await fixture.model.startLocalTunnel()
        let calls = await fixture.controller.calls()
        XCTAssertTrue(calls.methods.isEmpty)
        XCTAssertNil(fixture.model.localTunnel.lastError)
    }

    func testAppConnectionRequiresLocalTunnelInsteadOfUsingBoardFallback() async throws {
        let fixture = try Fixture()
        await fixture.model.connectDevice()
        let calls = await fixture.controller.calls()
        XCTAssertTrue(calls.methods.isEmpty)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertEqual(fixture.model.connectionMessage, String(localized: "connection.startLocalFirst"))
    }

    func testBoardHardwareAndPairingConditionsResolveInBothLanguages() throws {
        let app = Bundle(for: AppModel.self)
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let requirement = bundle.localizedString(forKey: "device.boardHardwareRequirement", value: nil, table: "Localizable")
            XCTAssertTrue(requirement.contains("ESP32-S3") && requirement.contains("TRAE Passport C3"))
            for (table, keys) in [
                ("Localizable", ["device.connectionMethod", "device.appConnectionMethod", "device.boardConnectionMethod", "device.boardPairingRequired", "connection.boardSelected"]),
                ("Onboarding", ["setup.boardPairingDetail", "setup.boardConnection", "setup.boardConnectionDetail"]),
            ] {
                for key in keys {
                    let value = bundle.localizedString(forKey: key, value: nil, table: table)
                    XCTAssertFalse(value.isEmpty)
                    XCTAssertNotEqual(value, key)
                }
            }
        }
    }

    /// Reproduce an in-progress iOS 27 pairing on an iOS 26 simulator. The
    /// native pairing protocol is not started; these cases test App teardown
    /// of its task/lease and guard against delayed identity-save continuations.
    private func simulatedPendingPairing(in model: AppModel) -> Task<Void, Never> {
        model.isPairing = true
        // The listener must also stop if a callback lands before its connection
        // marker is recorded. This covers the original nil-marker regression.
        model.activeDeviceConnectionMethod = nil
        model.pairingCode = "123456"
        model.pairingLeaseID = UUID()
        model.pairingTask = Task {
            do {
                try await Task.sleep(for: .seconds(60))
                model.hasPairingIdentity = true
            } catch { }
        }
        return model.pairingTask!
    }
}

@MainActor private final class Fixture {
    let suite: String
    let preferences: UserDefaults
    let directory: URL
    let controller: AppConnectionRecordingController
    let model: AppModel

    init(savedMethod: String? = nil, failure: DeviceControlError? = nil,
         grantsControl: Bool = true, suspendsConnection: Bool = false) throws {
        suite = "DeviceConnectionMethodTests.\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        if let savedMethod { preferences.set(savedMethod, forKey: "deviceConnectionMethod") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        controller = AppConnectionRecordingController(failure: failure, grantsControl: grantsControl, suspendsConnection: suspendsConnection)
        model = AppModel(storageDirectory: directory, preferences: preferences)
        model.deviceClient = DeviceClient(controller: controller)
    }
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

private actor AppConnectionRecordingController: DeviceController {
    let failure: DeviceControlError?
    let grantsControl: Bool
    let suspendsConnection: Bool
    var methods: [DeviceConnectionMethod] = []
    var disconnects = 0
    var cancelledConnections = 0
    var connected = false
    var pending: CheckedContinuation<Void, Error>?
    init(failure: DeviceControlError?, grantsControl: Bool, suspendsConnection: Bool) {
        self.failure = failure; self.grantsControl = grantsControl; self.suspendsConnection = suspendsConnection
    }
    func status() async -> DeviceStatus {
        if connected && grantsControl { .ready(capabilities: [.screenshot, .tap]) }
        else { .unavailable(reason: "synthetic diagnostic only") }
    }
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws { methods.append(.localVPN); connected = true }
    func connectUSBBoard() async throws {
        methods.append(.usbBoard)
        if let failure { throw failure }
        if suspendsConnection {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { pending = $0 }
            } onCancel: {
                Task { await self.cancelPending() }
            }
        }
        connected = true
    }
    private func cancelPending() {
        guard let pending else { return }
        self.pending = nil; cancelledConnections += 1
        pending.resume(throwing: CancellationError())
    }
    func disconnect() async { disconnects += 1; connected = false; cancelPending() }
    func calls() -> (methods: [DeviceConnectionMethod], disconnects: Int, cancelledConnections: Int) {
        (methods, disconnects, cancelledConnections)
    }
}
