import EiscueDeviceKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class DeviceConnectionMethodTests: XCTestCase {
    func testDictationIsBlockedOnlyByConnectedCoreDeviceMediaOnIOS27() {
        let oldOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
        let newOS = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        for method in [DeviceConnectionMethod.localVPN, .usbBoard] {
            XCTAssertTrue(DeviceMicrophonePolicy.blocksDictation(method: method, backend: .coreDevice, isConnected: true, on: newOS))
            XCTAssertFalse(DeviceMicrophonePolicy.blocksDictation(method: method, backend: .coreDevice, isConnected: false, on: newOS))
            XCTAssertFalse(DeviceMicrophonePolicy.blocksDictation(method: method, backend: .coreDevice, isConnected: true, on: oldOS))
            XCTAssertFalse(DeviceMicrophonePolicy.blocksDictation(method: method, backend: .xcTest, isConnected: true, on: newOS))
            XCTAssertFalse(DeviceMicrophonePolicy.blocksDictation(method: method, backend: nil, isConnected: true, on: newOS))
        }
        XCTAssertFalse(DeviceMicrophonePolicy.blocksDictation(method: .bluetoothBoard, backend: .coreDevice, isConnected: true, on: newOS))
        XCTAssertFalse(DeviceMicrophonePolicy.blocksDictation(method: nil, backend: .coreDevice, isConnected: true, on: newOS))
    }

    func testDictationUsesTheActiveBackendRatherThanTheSelectedPreference() throws {
        let fixture = try Fixture(savedMethod: "usbBoard", savedBackend: "coreDevice")
        let model = fixture.model
        model.activeDeviceConnectionMethod = .usbBoard
        model.deviceStatus = .ready(capabilities: [.screenshot, .tap])
        model.activeDeviceControlBackend = .xcTest
        XCTAssertFalse(model.isDictationBlockedByDeviceConnection)
        model.deviceControlBackend = .xcTest
        model.activeDeviceControlBackend = .coreDevice
        XCTAssertEqual(model.isDictationBlockedByDeviceConnection, ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
        model.activeDeviceControlBackend = nil
        XCTAssertFalse(model.isDictationBlockedByDeviceConnection)
    }

    func testBothHIDOutputsKeepDictationAvailableAfterRestoringPreferences() throws {
        let fixture = try Fixture(savedMethod: "bluetoothBoard")
        let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        for route in BluetoothBoardInputRoute.allCases {
            fixture.preferences.set(route.rawValue, forKey: "bluetoothInputRoute")
            let model = AppModel(storageDirectory: fixture.directory, preferences: fixture.preferences,
                                 credentialStore: CredentialStore(service: fixture.suite))
            XCTAssertEqual(model.bluetoothInputRoute, route)
            XCTAssertEqual(model.deviceConnectionMethod, .bluetoothBoard)
            // Simulate readiness without contacting a board or starting ReplayKit.
            model.activeDeviceConnectionMethod = model.deviceConnectionMethod
            model.deviceStatus = .ready(capabilities: [.screenshot, .tap, .textInput])
            XCTAssertFalse(DeviceMicrophonePolicy.blocksDictation(method: model.activeDeviceConnectionMethod,
                backend: model.activeDeviceControlBackend, isConnected: model.isDeviceReady, on: version),
                "HID output \(route) must not inherit the USB network restriction.")
        }
    }

    func testDictationReleasesMediaAndRestoresTheCapturedBackendWithoutChangingPreferencesOrPairing() async throws {
        let fixture = try dictationFixture()
        let model = fixture.model
        await model.connectDevice()
        model.isLoading = false; model.draft = "Dictated message"; model.hasPairingIdentity = true
        model.screenshot = DeviceScreenshot(width: 4, height: 4, mimeType: "image/png", data: Data())
        let id = UUID()
        try await model.prepareDeviceForDictation(id: id)
        XCTAssertFalse(model.isDeviceReady)
        XCTAssertFalse(model.canSend, "A temporarily released connection must not accidentally choose chat scope.")
        XCTAssertNil(model.screenshot)
        XCTAssertNil(model.activeDeviceConnectionMethod)
        XCTAssertTrue(model.hasPairingIdentity)
        XCTAssertFalse(model.localTunnel.isConnected)
        let error = await model.finishDeviceDictation(id: id)
        XCTAssertNil(error)
        XCTAssertTrue(model.isDeviceReady)
        XCTAssertTrue(model.canSend)
        XCTAssertTrue(model.hasPairingIdentity)
        XCTAssertEqual(model.activeDeviceControlBackend, .coreDevice)
        XCTAssertEqual(model.deviceControlBackend, .automatic)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods, [.usbBoard, .usbBoard])
        XCTAssertEqual(calls.backends, [.automatic, .coreDevice])
        XCTAssertEqual(calls.disconnects, 1)
        XCTAssertEqual(calls.pairingMutations, 0)
        XCTAssertEqual(calls.events, ["connect:usbBoard", "disconnect:start", "disconnect:end", "connect:usbBoard"])
        _ = await model.finishDeviceDictation(id: id)
        let repeated = await fixture.controller.calls()
        XCTAssertEqual(repeated.methods.count, 2, "Finishing the same voice session twice must not reconnect twice.")
    }

    func testFinishingDuringDictationReleaseWaitsAndPreventsTheMicrophoneContinuation() async throws {
        let fixture = try dictationFixture(suspendsDisconnect: true)
        let model = fixture.model
        await model.connectDevice()
        let id = UUID()
        let preparation = Task { try await model.prepareDeviceForDictation(id: id) }
        try await waitUntil { await fixture.controller.calls().disconnects == 1 }
        let finish = Task { await model.finishDeviceDictation(id: id) }
        try await waitUntil { model.dictationDeviceRestoration?.isFinishing == true }
        let releasing = await fixture.controller.calls()
        XCTAssertEqual(releasing.methods.count, 1)
        XCTAssertTrue(model.isConnecting)
        await fixture.controller.completePendingDisconnect()
        do { try await preparation.value; XCTFail("Ended dictation must not start recording after release.") }
        catch is CancellationError { }
        let error = await finish.value
        XCTAssertNil(error)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.events, ["connect:usbBoard", "disconnect:start", "disconnect:end", "connect:usbBoard"])
        XCTAssertTrue(model.isDeviceReady)
        XCTAssertNil(model.dictationDeviceRestoration)
    }

    func testCancelledDictationPreparationStillRestoresAfterReleaseFinishes() async throws {
        let fixture = try dictationFixture(suspendsDisconnect: true)
        let model = fixture.model
        await model.connectDevice()
        let id = UUID()
        let preparation = Task { try await model.prepareDeviceForDictation(id: id) }
        try await waitUntil { await fixture.controller.calls().disconnects == 1 }
        preparation.cancel()
        let finish = Task { await model.finishDeviceDictation(id: id) }
        await fixture.controller.completePendingDisconnect()
        do { try await preparation.value; XCTFail("Cancelled preparation must not authorize microphone capture.") }
        catch is CancellationError { }
        let error = await finish.value
        XCTAssertNil(error)
        XCTAssertTrue(model.isDeviceReady)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods.count, 2)
    }

    func testDictationLeavesXCTestHIDOldOSAndDisconnectedRoutesAlone() async throws {
        for (method, backend, major, connected) in [
            (DeviceConnectionMethod.usbBoard, DeviceControlBackend.xcTest, 27, true),
            (.bluetoothBoard, .coreDevice, 27, true),
            (.usbBoard, .coreDevice, 26, true),
            (.usbBoard, .coreDevice, 27, false),
        ] {
            let fixture = try Fixture(savedMethod: method.rawValue, savedBackend: backend.rawValue,
                operatingSystemVersion: .init(majorVersion: major, minorVersion: 0, patchVersion: 0))
            let model = fixture.model
            // Model readiness is injected so the HID case never contacts a real board.
            model.deviceClient = DeviceClient(controller: fixture.controller)
            model.activeDeviceConnectionMethod = connected ? method : nil
            model.activeDeviceControlBackend = connected ? backend : nil
            if connected { model.deviceStatus = .ready(capabilities: [.screenshot, .tap]) }
            let original = model.deviceStatus
            let id = UUID()
            try await model.prepareDeviceForDictation(id: id)
            let error = await model.finishDeviceDictation(id: id)
            XCTAssertNil(error)
            XCTAssertEqual(model.deviceStatus, original)
            XCTAssertNil(model.dictationDeviceRestoration)
            let calls = await fixture.controller.calls()
            XCTAssertTrue(calls.methods.isEmpty)
            XCTAssertEqual(calls.disconnects, 0)
        }
    }

    func testNoninterferingConnectionsAllowDictationForPausedAndRecoverableRuns() async throws {
        for state in [RunState.paused, .interrupted] {
            for (method, backend, major, connected) in [
                (DeviceConnectionMethod.usbBoard, DeviceControlBackend.xcTest, 27, true),
                (.bluetoothBoard, .coreDevice, 27, true),
                (.usbBoard, .coreDevice, 26, true),
                (.usbBoard, .coreDevice, 27, false),
            ] {
                let fixture = try Fixture(savedMethod: method.rawValue, savedBackend: backend.rawValue,
                    operatingSystemVersion: .init(majorVersion: major, minorVersion: 0, patchVersion: 0))
                let model = fixture.model
                model.deviceClient = DeviceClient(controller: fixture.controller)
                model.activeDeviceConnectionMethod = connected ? method : nil
                model.activeDeviceControlBackend = connected ? backend : nil
                if connected { model.deviceStatus = .ready(capabilities: [.screenshot, .tap]) }
                let conversationID = UUID()
                model.selectedConversationID = conversationID
                model.runs = [RunRecord(id: UUID(), conversationID: conversationID, requestID: UUID(), startedAt: .now,
                    scope: .control, model: "fixture", skill: nil, state: state, detail: "", events: [])]
                if state == .interrupted { model.interruptedConversationIDs.insert(conversationID) }
                XCTAssertEqual(model.pausedRun != nil, state == .paused)
                XCTAssertEqual(model.needsRecovery, state == .interrupted)
                let original = model.deviceStatus
                let id = UUID()
                try await model.prepareDeviceForDictation(id: id)
                let error = await model.finishDeviceDictation(id: id)
                XCTAssertNil(error)
                XCTAssertEqual(model.deviceStatus, original)
                XCTAssertNil(model.dictationDeviceRestoration)
                let calls = await fixture.controller.calls()
                XCTAssertTrue(calls.methods.isEmpty)
                XCTAssertEqual(calls.disconnects, 0)
            }
        }
    }

    func testDictationNeverInterruptsActivePausedOrRecoverableRuns() async throws {
        for state in [RunState.running, .paused, .interrupted] {
            let fixture = try dictationFixture()
            let model = fixture.model
            await model.connectDevice()
            let conversationID = UUID()
            model.selectedConversationID = conversationID
            let run = RunRecord(id: UUID(), conversationID: conversationID, requestID: UUID(), startedAt: .now,
                scope: .control, model: "fixture", skill: nil, state: state, detail: "", events: [])
            if state == .running { model.activeRun = run } else { model.runs = [run] }
            if state == .interrupted { model.interruptedConversationIDs.insert(conversationID) }
            let id = UUID()
            do { try await model.prepareDeviceForDictation(id: id); XCTFail("Run state \(state) must block dictation handoff.") }
            catch DictationDevicePreparationError.busy { }
            _ = await model.finishDeviceDictation(id: id)
            let calls = await fixture.controller.calls()
            XCTAssertEqual(calls.disconnects, 0)
            XCTAssertEqual(calls.methods.count, 1)
            XCTAssertTrue(model.isDeviceReady)
        }
    }

    func testManualConnectionCommandsRevokeDictationRestoration() async throws {
        for action in ["disconnect", "connect", "route", "backend", "forget"] {
            let fixture = try dictationFixture()
            let model = fixture.model
            await model.connectDevice()
            let id = UUID()
            try await model.prepareDeviceForDictation(id: id)
            switch action {
            case "disconnect": await model.disconnectDevice()
            case "connect": await model.connectDevice()
            case "route": await model.selectDeviceConnectionMethod(.localVPN)
            case "backend": await model.selectDeviceControlBackend(.xcTest)
            default: await model.forgetPairingIdentity()
            }
            let beforeFinish = await fixture.controller.calls()
            let error = await model.finishDeviceDictation(id: id)
            let afterFinish = await fixture.controller.calls()
            XCTAssertNil(error)
            XCTAssertEqual(afterFinish.methods, beforeFinish.methods, "\(action) must replace the voice restoration intent.")
            XCTAssertEqual(afterFinish.disconnects, beforeFinish.disconnects)
            XCTAssertNil(model.dictationDeviceRestoration)
            XCTAssertEqual(afterFinish.methods.count, action == "connect" ? 2 : 1)
        }
    }

    func testManualConnectWaitsForDictationReleaseBeforeUsingTheController() async throws {
        let fixture = try dictationFixture(suspendsDisconnect: true)
        let model = fixture.model
        await model.connectDevice()
        let id = UUID()
        let preparation = Task { try await model.prepareDeviceForDictation(id: id) }
        try await waitUntil { await fixture.controller.calls().disconnects == 1 }
        let connect = Task { await model.connectDevice() }
        try await waitUntil { model.dictationPreparationID == nil }
        let beforeRelease = await fixture.controller.calls()
        XCTAssertEqual(beforeRelease.methods.count, 1)
        await fixture.controller.completePendingDisconnect()
        do { try await preparation.value; XCTFail("Manual connection intent must supersede preparation.") }
        catch is CancellationError { }
        await connect.value
        _ = await model.finishDeviceDictation(id: id)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.events, ["connect:usbBoard", "disconnect:start", "disconnect:end", "connect:usbBoard"])
        XCTAssertEqual(calls.backends, [.automatic, .automatic])
        XCTAssertTrue(model.isDeviceReady)
    }

    func testBackgroundAndExplicitNoReconnectPreventDictationRestoration() async throws {
        for background in [false, true] {
            let fixture = try dictationFixture()
            let model = fixture.model
            await model.connectDevice()
            let id = UUID()
            try await model.prepareDeviceForDictation(id: id)
            if background { model.sceneChanged(.background); model.sceneChanged(.active) }
            let error = await model.finishDeviceDictation(id: id, reconnect: background)
            XCTAssertNil(error)
            let calls = await fixture.controller.calls()
            XCTAssertEqual(calls.methods.count, 1)
            XCTAssertFalse(model.isDeviceReady)
            XCTAssertNil(model.dictationDeviceRestoration)
        }
    }

    func testBackgroundDuringReleasePreventsBothMicrophoneStartAndReconnect() async throws {
        let fixture = try dictationFixture(suspendsDisconnect: true)
        let model = fixture.model
        await model.connectDevice()
        let id = UUID()
        let preparation = Task { try await model.prepareDeviceForDictation(id: id) }
        try await waitUntil { await fixture.controller.calls().disconnects == 1 }
        model.sceneChanged(.background)
        let finish = Task { await model.finishDeviceDictation(id: id) }
        await fixture.controller.completePendingDisconnect()
        do { try await preparation.value; XCTFail("Background preparation must not start the microphone.") }
        catch is CancellationError { }
        _ = await finish.value
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods.count, 1)
        XCTAssertFalse(model.isDeviceReady)
        XCTAssertFalse(model.isConnecting)
    }

    func testNewVoiceSessionAndStaleFinishCannotRestoreAnOldConnection() async throws {
        let fixture = try dictationFixture()
        let model = fixture.model
        await model.connectDevice()
        let oldID = UUID(), newID = UUID()
        try await model.prepareDeviceForDictation(id: oldID)
        try await model.prepareDeviceForDictation(id: newID)
        _ = await model.finishDeviceDictation(id: oldID)
        XCTAssertEqual(model.dictationPreparationID, newID)
        _ = await model.finishDeviceDictation(id: newID)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods.count, 1)
        XCTAssertFalse(model.isDeviceReady)
    }

    func testDictationReconnectFailureIsReportedWithoutRetryOrFallback() async throws {
        let fixture = try dictationFixture()
        let model = fixture.model
        await model.connectDevice()
        let id = UUID()
        try await model.prepareDeviceForDictation(id: id)
        await fixture.controller.setConnectionFailure(.connection("synthetic restoration failure"))
        let error = await model.finishDeviceDictation(id: id)
        XCTAssertEqual(error, String(localized: "speech.deviceReconnectFailed", table: "Speech"))
        XCTAssertEqual(model.deviceConnectionError, error)
        XCTAssertFalse(model.isDeviceReady)
        XCTAssertFalse(model.isConnecting)
        XCTAssertNil(model.activeDeviceConnectionMethod)
        XCTAssertNil(model.dictationDeviceRestoration)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods, [.usbBoard, .usbBoard])
        XCTAssertEqual(calls.backends, [.automatic, .coreDevice])
        XCTAssertEqual(calls.disconnects, 2, "Failed restoration must clean up any partial media session.")
    }

    func testUnconfirmedMediaReleaseRejectsDictationAndNeverRestores() async throws {
        for finishDuringRelease in [false, true] {
            let fixture = try dictationFixture(suspendsDisconnect: finishDuringRelease)
            let model = fixture.model
            await model.connectDevice()
            await fixture.controller.setReleaseConfirmed(false)
            let id = UUID()
            let preparation = Task { try await model.prepareDeviceForDictation(id: id) }
            var finishing: Task<String?, Never>?
            if finishDuringRelease {
                try await waitUntil { await fixture.controller.calls().disconnects == 1 }
                finishing = Task { await model.finishDeviceDictation(id: id) }
                try await waitUntil { model.dictationDeviceRestoration?.isFinishing == true }
                await fixture.controller.completePendingDisconnect()
            }
            do { try await preparation.value; XCTFail("Unconfirmed release must not authorize microphone capture.") }
            catch DictationDevicePreparationError.releaseUnconfirmed { }
            if let finishing { _ = await finishing.value }
            let error = await model.finishDeviceDictation(id: id)
            XCTAssertNil(error)
            XCTAssertFalse(model.isDeviceReady)
            XCTAssertFalse(model.isConnecting)
            XCTAssertNil(model.dictationDeviceRestoration)
            let calls = await fixture.controller.calls()
            XCTAssertEqual(calls.methods, [.usbBoard])
            XCTAssertEqual(calls.disconnects, 1)
        }
    }

    func testManualDisconnectCancelsAnInFlightDictationRestoreAndWaitsForCleanup() async throws {
        let fixture = try dictationFixture()
        let model = fixture.model
        await model.connectDevice()
        let id = UUID()
        try await model.prepareDeviceForDictation(id: id)
        await fixture.controller.setSuspendsConnection(true)
        let finish = Task { await model.finishDeviceDictation(id: id) }
        try await waitUntil { await fixture.controller.calls().methods.count == 2 }
        await model.disconnectDevice()
        let error = await finish.value
        XCTAssertNil(error, "A superseded restoration must not overwrite the user's connection state with an error.")
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.cancelledConnections, 1)
        XCTAssertEqual(calls.methods.count, 2)
        XCTAssertFalse(model.isDeviceReady)
        XCTAssertNil(model.activeDeviceConnectionMethod)
        XCTAssertNil(model.dictationDeviceRestoration)
        XCTAssertFalse(model.isConnecting)
    }

    func testLocalVPNLossRevokesDictationRestorationWhileMediaIsReleased() async throws {
        let fixture = try Fixture(savedMethod: "localVPN", operatingSystemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        let model = fixture.model
        model.activeDeviceConnectionMethod = .localVPN; model.activeDeviceControlBackend = .coreDevice
        model.deviceStatus = .ready(capabilities: [.screenshot, .tap]); model.hasPairingIdentity = true
        let id = UUID()
        try await model.prepareDeviceForDictation(id: id)
        model.localTunnel.onDisconnect?()
        _ = await model.finishDeviceDictation(id: id)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 1)
        XCTAssertTrue(calls.methods.isEmpty)
        XCTAssertTrue(model.hasPairingIdentity)
        XCTAssertNil(model.localTunnel.lastError, "Dictation must never start a VPN to restore device control.")
        XCTAssertNil(model.dictationDeviceRestoration)
    }

    private func dictationFixture(suspendsDisconnect: Bool = false) throws -> Fixture {
        try Fixture(savedMethod: "usbBoard", suspendsDisconnect: suspendsDisconnect,
            operatingSystemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }

    func testNewPreferencesDefaultToLocalVPNAndSelectionPersists() async throws {
        let fixture = try Fixture(savedMethod: nil)
        let model = fixture.model
        XCTAssertEqual(model.deviceConnectionMethod, .localVPN)
        XCTAssertNil(model.networkDeviceClient)
        XCTAssertFalse(model.localTunnel.isConnected)
        await model.selectDeviceConnectionMethod(.usbBoard)
        XCTAssertEqual(model.deviceConnectionMethod, .usbBoard)
        XCTAssertEqual(fixture.preferences.string(forKey: "deviceConnectionMethod"), "usbBoard")
        let restored = AppModel(storageDirectory: fixture.directory, preferences: fixture.preferences)
        XCTAssertEqual(restored.deviceConnectionMethod, .usbBoard)
        XCTAssertNil(model.localTunnel.lastError, "Selecting a board must not try to start the VPN on a simulator.")
    }

    func testUnknownSavedMethodSafelyDefaultsToLocalVPN() throws {
        let fixture = try Fixture(savedMethod: "future-unsupported-method")
        XCTAssertEqual(fixture.model.deviceConnectionMethod, .localVPN)
    }

    func testBackendDefaultsToAutomaticAndExplicitPreferencePersistsWithoutConnecting() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard")
        XCTAssertEqual(fixture.model.deviceControlBackend, .automatic)
        XCTAssertNil(fixture.model.activeDeviceControlBackend)
        await fixture.model.selectDeviceControlBackend(.xcTest)
        XCTAssertEqual(fixture.preferences.string(forKey: "deviceControlBackend"), "xcTest")
        let restored = AppModel(storageDirectory: fixture.directory, preferences: fixture.preferences)
        XCTAssertEqual(restored.deviceControlBackend, .xcTest)
        XCTAssertNil(restored.activeDeviceControlBackend)
        XCTAssertFalse(restored.isConnecting || restored.isDeviceReady)
        let calls = await fixture.controller.calls()
        XCTAssertTrue(calls.methods.isEmpty)
        XCTAssertEqual(calls.pairingMutations, 0)
    }

    func testUnknownBackendDefaultsToAutomaticAndSavedExplicitChoiceIsPreserved() throws {
        let unknown = try Fixture(savedBackend: "future-backend")
        XCTAssertEqual(unknown.model.deviceControlBackend, .automatic)
        let saved = try Fixture(savedBackend: "coreDevice")
        XCTAssertEqual(saved.model.deviceControlBackend, .coreDevice)
        XCTAssertNil(saved.model.activeDeviceControlBackend)
    }

    func testBackendSwitchReleasesBeforeSavingAndBlocksCompetingChanges() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", suspendsDisconnect: true)
        let model = fixture.model
        await model.connectDevice()
        model.screenshot = DeviceScreenshot(width: 4, height: 4, mimeType: "image/png", data: Data())
        let switching = Task { await model.selectDeviceControlBackend(.xcTest) }
        try await waitUntil { await fixture.controller.calls().disconnects == 1 }
        XCTAssertTrue(model.isChangingDeviceConnectionMethod)
        XCTAssertFalse(model.canChangeDeviceControlBackend)
        XCTAssertEqual(model.deviceControlBackend, .automatic)
        XCTAssertNil(model.activeDeviceControlBackend)
        await model.selectDeviceControlBackend(.coreDevice)
        await model.selectDeviceConnectionMethod(.bluetoothBoard)
        await model.connectDevice()
        await fixture.controller.completePendingDisconnect()
        await switching.value
        XCTAssertEqual(model.deviceConnectionMethod, .usbBoard)
        XCTAssertEqual(model.deviceControlBackend, .xcTest)
        XCTAssertNil(model.activeDeviceConnectionMethod)
        XCTAssertNil(model.screenshot)
        XCTAssertFalse(model.isConnecting || model.isChangingDeviceConnectionMethod || model.isDeviceReady)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods, [.usbBoard])
        XCTAssertEqual(calls.disconnects, 1)
        XCTAssertEqual(calls.pairingMutations, 0)
    }

    func testBackendSwitchCancelsPendingConnectionAndReconnectUsesNewChoice() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", suspendsConnection: true)
        let model = fixture.model
        let pending = Task { await model.connectDevice() }
        try await waitUntil { await fixture.controller.calls().methods == [.usbBoard] }
        XCTAssertEqual(model.activeDeviceControlBackend, DeviceControlBackend.automatic.resolved(on: ProcessInfo.processInfo.operatingSystemVersion))
        XCTAssertTrue(model.canChangeDeviceControlBackend)
        await model.selectDeviceControlBackend(.xcTest)
        await pending.value
        XCTAssertNil(model.activeDeviceControlBackend)
        XCTAssertNil(model.deviceConnectionError)
        let reconnect = Task { await model.connectDevice() }
        try await waitUntil { await fixture.controller.calls().methods.count == 2 }
        await fixture.controller.completePendingConnection()
        await reconnect.value
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.backends, [.automatic, .xcTest])
        XCTAssertEqual(calls.disconnects, 1)
        XCTAssertEqual(calls.cancelledConnections, 1)
        XCTAssertEqual(model.activeDeviceControlBackend, .xcTest)
        XCTAssertTrue(model.isDeviceReady)
        await model.disconnectDevice()
        XCTAssertNil(model.activeDeviceControlBackend)
    }

    func testExplicitBackendFailureDoesNotFallBackOrKeepAnActiveBackend() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", savedBackend: "xcTest", failure: .connection("synthetic backend unavailable"))
        await fixture.model.connectDevice()
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.backends, [.xcTest])
        XCTAssertEqual(calls.methods, [.usbBoard])
        XCTAssertEqual(fixture.model.deviceControlBackend, .xcTest)
        XCTAssertNil(fixture.model.activeDeviceControlBackend)
        XCTAssertEqual(fixture.model.deviceConnectionError, "synthetic backend unavailable")
    }

    func testBackendPreferenceSurvivesBluetoothRoundTripWithoutExtraNetworkDisconnect() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", savedBackend: "xcTest")
        let model = fixture.model
        await model.connectDevice()
        await model.selectDeviceConnectionMethod(.bluetoothBoard)
        XCTAssertEqual(model.deviceControlBackend, .xcTest)
        XCTAssertNil(model.activeDeviceControlBackend)
        let operationID = model.deviceOperationID
        let message = model.connectionMessage
        await model.selectDeviceControlBackend(.automatic)
        XCTAssertEqual(model.deviceOperationID, operationID)
        XCTAssertEqual(model.connectionMessage, message)
        await model.selectDeviceConnectionMethod(.usbBoard)
        await model.connectDevice()
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.backends, [.xcTest, .automatic])
        XCTAssertEqual(calls.disconnects, 1)
        XCTAssertEqual(calls.pairingMutations, 0)
        await model.disconnectDevice()
    }

    func testBackendSwitchIsRejectedDuringActivePausedAndRecoverableRuns() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard")
        let model = fixture.model
        let conversationID = UUID()
        model.selectedConversationID = conversationID
        for state in [RunState.running, .paused, .interrupted] {
            let run = RunRecord(id: UUID(), conversationID: conversationID, requestID: UUID(), startedAt: .now,
                                scope: .control, model: "fixture", skill: nil, state: state, detail: "", events: [])
            if state == .running { model.activeRun = run }
            else { model.runs = [run] }
            if state == .interrupted { model.interruptedConversationIDs.insert(conversationID) }
            XCTAssertFalse(model.canChangeDeviceControlBackend)
            await model.selectDeviceControlBackend(.xcTest)
            XCTAssertEqual(model.deviceControlBackend, .automatic)
            model.activeRun = nil; model.runs = []; model.interruptedConversationIDs.removeAll()
        }
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 0)
        XCTAssertTrue(model.canChangeDeviceControlBackend)
    }

    func testLegacyInjectedControllerKeepsAutomaticBehaviorAndRejectsExplicitSelection() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard")
        let controller = LegacyAppConnectionController()
        fixture.model.deviceClient = DeviceClient(controller: controller)
        await fixture.model.connectDevice()
        XCTAssertTrue(fixture.model.isDeviceReady)
        await fixture.model.selectDeviceControlBackend(.xcTest)
        await fixture.model.connectDevice()
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertNil(fixture.model.activeDeviceControlBackend)
        XCTAssertEqual(fixture.model.deviceConnectionError, DeviceControlError.unsupported.localizedDescription)
        let connections = await controller.connections
        XCTAssertEqual(connections, 1, "An explicit unsupported backend must not invoke the legacy automatic connection.")
    }

    func testConnectionRetentionIsDefaultAndAutomaticDisconnectPreferencePersists() throws {
        let fixture = try Fixture(savedMethod: nil)
        XCTAssertFalse(fixture.model.disconnectAfterTask)
        fixture.model.disconnectAfterTask = true
        let restored = AppModel(storageDirectory: fixture.directory, preferences: fixture.preferences)
        XCTAssertTrue(restored.disconnectAfterTask)
        restored.disconnectAfterTask = false
        XCTAssertFalse(fixture.preferences.bool(forKey: "disconnectAfterTask"))
    }

    func testRemovedWirelessPreferenceLoadsDisconnectedWithoutConnectingOrPairing() async throws {
        let fixture = try Fixture(savedMethod: "wirelessBoard")
        let model = fixture.model
        defer {
            model.bluetoothMonitor?.cancel()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        await model.load()
        XCTAssertEqual(model.deviceConnectionMethod, .localVPN)
        XCTAssertNil(model.networkDeviceClient)
        XCTAssertNil(model.activeDeviceConnectionMethod)
        XCTAssertNil(model.deviceConnectionTask)
        XCTAssertNil(model.pairingTask)
        XCTAssertFalse(model.isDeviceReady || model.isConnecting || model.isPairing)
        XCTAssertFalse(model.localTunnel.isConnected || model.localTunnel.isTransitioning)
        let calls = await fixture.controller.calls()
        XCTAssertTrue(calls.methods.isEmpty)
        XCTAssertEqual(calls.pairingMutations, 0)
    }

    func testSavedBluetoothSelectionKeepsItsController() throws {
        let fixture = try Fixture(savedMethod: "bluetoothBoard")
        XCTAssertEqual(fixture.model.deviceConnectionMethod, .bluetoothBoard)
        XCTAssertNotNil(fixture.model.networkDeviceClient)
        XCTAssertFalse(fixture.model.localTunnel.isConnected)
    }

    func testNetworkMethodChangesKeepTheInjectedController() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard")
        await fixture.model.connectDevice()
        await fixture.model.selectDeviceConnectionMethod(.localVPN)
        await fixture.model.selectDeviceConnectionMethod(.usbBoard)
        await fixture.model.connectDevice()
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods, [.usbBoard, .usbBoard])
        XCTAssertEqual(calls.disconnects, 2)
        XCTAssertTrue(fixture.model.isDeviceReady)
        await fixture.model.disconnectDevice()
    }

    func testBluetoothRoundTripRestoresTheInjectedNetworkController() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard")
        await fixture.model.connectDevice()
        await fixture.model.selectDeviceConnectionMethod(.bluetoothBoard)
        XCTAssertFalse(fixture.model.isDeviceReady)
        await fixture.model.selectDeviceConnectionMethod(.usbBoard)
        await fixture.model.connectDevice()
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.methods, [.usbBoard, .usbBoard])
        XCTAssertEqual(calls.disconnects, 1)
        XCTAssertTrue(fixture.model.isDeviceReady)
        await fixture.model.disconnectDevice()
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

    func testSystemAuthorizationBackgroundKeepsThePendingConnectionAlive() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", suspendsConnection: true)
        let model = fixture.model
        let pending = Task { await model.connectDevice() }
        try await waitUntil { await fixture.controller.calls().methods == [.usbBoard] }
        let operationID = model.deviceOperationID
        model.sceneChanged(.background)
        await Task.yield()
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 0)
        XCTAssertEqual(calls.cancelledConnections, 0)
        XCTAssertEqual(model.deviceOperationID, operationID)
        XCTAssertTrue(model.isConnecting)
        model.sceneChanged(.active)
        await fixture.controller.completePendingConnection()
        await pending.value
        XCTAssertTrue(model.isDeviceReady)
        await model.disconnectDevice()
    }

    func testCompletingConnectionInBackgroundKeepsItUntilExplicitDisconnect() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", suspendsConnection: true)
        let model = fixture.model
        let pending = Task { await model.connectDevice() }
        try await waitUntil { await fixture.controller.calls().methods == [.usbBoard] }
        model.sceneChanged(.background)
        await fixture.controller.completePendingConnection()
        await pending.value
        XCTAssertFalse(model.isConnecting)
        XCTAssertTrue(model.isDeviceReady)
        let initial = await fixture.controller.calls()
        XCTAssertEqual(initial.disconnects, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.isDeviceReady)
        XCTAssertEqual(model.activeDeviceConnectionMethod, .usbBoard)
        let completed = await fixture.controller.calls()
        XCTAssertEqual(completed.disconnects, 0)
        XCTAssertEqual(completed.cancelledConnections, 0)
        await model.disconnectDevice()
        XCTAssertFalse(model.isDeviceReady)
        XCTAssertNil(model.activeDeviceConnectionMethod)
    }

    func testReturningFromSystemAuthorizationKeepsTheCompletedConnection() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", suspendsConnection: true)
        let model = fixture.model
        let pending = Task { await model.connectDevice() }
        try await waitUntil { await fixture.controller.calls().methods == [.usbBoard] }
        model.sceneChanged(.background)
        await fixture.controller.completePendingConnection()
        await pending.value
        model.sceneChanged(.active)
        try await Task.sleep(for: .milliseconds(300))
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 0)
        XCTAssertTrue(model.isDeviceReady)
        await model.disconnectDevice()
    }

    func testOldCompletionCannotReleaseANewerPendingConnection() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", suspendsConnection: true)
        let model = fixture.model
        let first = Task { await model.connectDevice() }
        try await waitUntil { await fixture.controller.calls().methods.count == 1 }
        model.sceneChanged(.background)
        await fixture.controller.completePendingConnection()
        await first.value
        await model.disconnectDevice()
        let newer = Task { await model.connectDevice() }
        try await waitUntil { await fixture.controller.calls().methods.count == 2 }
        let operationID = model.deviceOperationID
        try await Task.sleep(for: .milliseconds(300))
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 1, "Only the explicit disconnect should release a session.")
        XCTAssertEqual(calls.cancelledConnections, 0)
        XCTAssertEqual(model.deviceOperationID, operationID)
        XCTAssertTrue(model.isConnecting)
        model.sceneChanged(.active)
        await fixture.controller.completePendingConnection()
        await newer.value
        XCTAssertTrue(model.isDeviceReady)
        await model.disconnectDevice()
    }

    func testDeviceRunStartedAfterBackgroundConnectionKeepsItsConnection() async throws {
        let fixture = try Fixture(savedMethod: "usbBoard", suspendsConnection: true)
        let model = fixture.model
        let pending = Task { await model.connectDevice() }
        try await waitUntil { await fixture.controller.calls().methods == [.usbBoard] }
        model.sceneChanged(.background)
        await fixture.controller.completePendingConnection()
        await pending.value
        model.activeRun = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: Date(),
                                    scope: .control, model: "synthetic", skill: nil, state: .running, detail: "", events: [])
        try await Task.sleep(for: .milliseconds(300))
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 0)
        XCTAssertTrue(model.isDeviceReady)
        model.activeRun = nil
        model.sceneChanged(.active)
        await model.disconnectDevice()
    }

    func testIdleAndChatBackgroundTransitionsKeepTheConnectionWhileChatStillStops() async throws {
        for hasChat in [false, true] {
            let fixture = try Fixture(savedMethod: "usbBoard")
            let model = fixture.model
            await model.connectDevice()
            if hasChat {
                model.activeRun = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: .now,
                                            scope: .chat, model: "fixture", skill: nil, state: .running, detail: "", events: [])
            }
            model.sceneChanged(.background)
            try await Task.sleep(for: .milliseconds(30))
            let calls = await fixture.controller.calls()
            XCTAssertEqual(calls.disconnects, 0)
            XCTAssertTrue(model.isDeviceReady)
            XCTAssertEqual(model.stopRequested, hasChat)
            model.activeRun = nil
            await model.disconnectDevice()
        }
    }

    func testAutomationAuthorizationGuidanceIsLocalizedAndUsesTheSystemScreen() throws {
        let app = Bundle(for: AppModel.self)
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let text = bundle.localizedString(forKey: "connection.automationAuthorization", value: nil, table: "Localizable")
            XCTAssertNotEqual(text, "connection.automationAuthorization")
            XCTAssertTrue(text.contains(language == "en" ? "passcode" : "密码"))
            XCTAssertTrue(text.contains(language == "en" ? "system screen" : "系统页面"))
        }
    }

    private func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        XCTFail("The synthetic connection did not reach the expected state in time.")
        throw NSError(domain: "DeviceConnectionMethodTests", code: 1)
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
            XCTAssertTrue(requirement.contains("ESP32-S3") && requirement.contains("USB"))
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

    init(savedMethod: String? = "localVPN", savedBackend: String? = nil, failure: DeviceControlError? = nil,
         grantsControl: Bool = true, suspendsConnection: Bool = false, suspendsDisconnect: Bool = false,
         operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws {
        suite = "DeviceConnectionMethodTests.\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        if let savedMethod { preferences.set(savedMethod, forKey: "deviceConnectionMethod") }
        if let savedBackend { preferences.set(savedBackend, forKey: "deviceControlBackend") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        controller = AppConnectionRecordingController(failure: failure, grantsControl: grantsControl,
            suspendsConnection: suspendsConnection, suspendsDisconnect: suspendsDisconnect)
        model = AppModel(storageDirectory: directory, preferences: preferences,
                         credentialStore: CredentialStore(service: suite), operatingSystemVersion: operatingSystemVersion)
        let client = DeviceClient(controller: controller)
        if model.deviceConnectionMethod == .bluetoothBoard { model.networkDeviceClient = client }
        else { model.deviceClient = client }
    }
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

private actor LegacyAppConnectionController: DeviceController {
    var connections = 0
    var connected = false
    func status() async -> DeviceStatus {
        connected ? .ready(capabilities: [.screenshot, .tap]) : .unavailable(reason: "Fixture disconnected")
    }
    func connectUSBBoard() async throws { connections += 1; connected = true }
    func disconnect() async { connected = false }
}

private actor AppConnectionRecordingController: DeviceController {
    var failure: DeviceControlError?
    let grantsControl: Bool
    var suspendsConnection: Bool
    var suspendsDisconnect: Bool
    var releaseConfirmed = true
    var methods: [DeviceConnectionMethod] = []
    var backends: [DeviceControlBackend] = []
    var disconnects = 0
    var cancelledConnections = 0
    var pairingMutations = 0
    var connected = false
    var events: [String] = []
    var pending: CheckedContinuation<Void, Error>?
    var pendingDisconnect: CheckedContinuation<Void, Never>?
    init(failure: DeviceControlError?, grantsControl: Bool, suspendsConnection: Bool, suspendsDisconnect: Bool) {
        self.failure = failure; self.grantsControl = grantsControl; self.suspendsConnection = suspendsConnection
        self.suspendsDisconnect = suspendsDisconnect
    }
    func status() async -> DeviceStatus {
        if connected && grantsControl { .ready(capabilities: [.screenshot, .tap]) }
        else { .unavailable(reason: "synthetic diagnostic only") }
    }
    func importPairingIdentity(_ data: Data) async throws {
        pairingMutations += 1
        throw DeviceControlError.unsupported
    }
    func removePairingIdentity() async throws {
        pairingMutations += 1
        throw DeviceControlError.unsupported
    }
    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        pairingMutations += 1
        return AsyncThrowingStream { $0.finish(throwing: DeviceControlError.unsupported) }
    }
    func connectLocalVPN(configuration: LocalVPNConfiguration) async throws { methods.append(.localVPN); connected = true }
    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws {
        backends.append(backend)
        try await connectLocalVPN(configuration: configuration)
    }
    func connectUSBBoard(backend: DeviceControlBackend) async throws {
        backends.append(backend)
        try await connectUSBBoard()
    }
    func connectUSBBoard() async throws {
        methods.append(.usbBoard)
        events.append("connect:usbBoard")
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
    func completePendingConnection() {
        guard let pending else { return }
        self.pending = nil
        pending.resume()
    }
    private func cancelPending() {
        guard let pending else { return }
        self.pending = nil; cancelledConnections += 1
        pending.resume(throwing: CancellationError())
    }
    func disconnect() async {
        events.append("disconnect:start")
        disconnects += 1; connected = false; cancelPending()
        if suspendsDisconnect {
            suspendsDisconnect = false
            await withCheckedContinuation { pendingDisconnect = $0 }
        }
        events.append("disconnect:end")
    }
    func disconnectAndConfirmRelease() async -> Bool {
        await disconnect()
        return releaseConfirmed
    }
    func completePendingDisconnect() {
        pendingDisconnect?.resume()
        pendingDisconnect = nil
    }
    func setConnectionFailure(_ failure: DeviceControlError?) { self.failure = failure }
    func setSuspendsConnection(_ value: Bool) { suspendsConnection = value }
    func setReleaseConfirmed(_ value: Bool) { releaseConfirmed = value }
    func calls() -> (methods: [DeviceConnectionMethod], backends: [DeviceControlBackend], disconnects: Int,
                     cancelledConnections: Int, pairingMutations: Int, events: [String]) {
        (methods, backends, disconnects, cancelledConnections, pairingMutations, events)
    }
}
