import EiscueDeviceKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class DeviceConnectionRepairTests: XCTestCase {
    func testRepairPreservesConfigurationAndBlocksActionsUntilMicrophoneCheckFinishes() async throws {
        let fixture = try RepairFixture(method: .localVPN)
        let model = fixture.model
        model.draft = "Keep this draft"
        model.selectedConversationID = UUID()
        model.modelSettings.model = "Configured model"
        model.screenshot = DeviceScreenshot(width: 4, height: 4, mimeType: "image/png", data: Data())
        let preferences = fixture.preferences.dictionaryRepresentation() as NSDictionary
        let settings = model.modelSettings
        let conversationID = model.selectedConversationID
        let tunnel = model.localTunnel
        let tunnelStatus = tunnel.statusTitle
        let tunnelConnected = tunnel.isConnected
        model.bluetoothMonitor = Task { try? await Task.sleep(for: .seconds(60)) }

        let result = await model.repairDeviceConnection()
        XCTAssertEqual(result, .released)
        XCTAssertTrue(model.isRepairingDeviceConnection)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canChangeDeviceControlBackend)
        XCTAssertFalse(model.canRepairDeviceConnection)
        XCTAssertNil(model.bluetoothMonitor)
        XCTAssertNil(model.activeDeviceConnectionMethod)
        XCTAssertNil(model.activeDeviceControlBackend)
        XCTAssertNil(model.screenshot)
        XCTAssertFalse(model.isDeviceReady)
        XCTAssertEqual(model.deviceSession.owner, .repair)
        XCTAssertEqual(model.deviceSession.state, .idle(route: .localVPN))
        XCTAssertFalse(model.deviceSession.hasUnconfirmedRelease)
        XCTAssertThrowsError(try model.deviceSession.acquire(.run(UUID())))

        await model.connectDevice()
        await model.enableDeviceControl()
        await model.selectDeviceConnectionMethod(.usbBoard)
        await model.selectDeviceControlBackend(.xcTest)
        await model.sendMessage()
        model.startPairing()
        XCTAssertTrue(model.hasPairingIdentity)
        XCTAssertTrue(model.localTunnel === tunnel)
        XCTAssertEqual(tunnel.statusTitle, tunnelStatus)
        XCTAssertEqual(tunnel.isConnected, tunnelConnected)
        XCTAssertEqual(model.modelSettings, settings)
        XCTAssertEqual(model.selectedConversationID, conversationID)
        XCTAssertEqual(model.draft, "Keep this draft")
        XCTAssertEqual(fixture.preferences.dictionaryRepresentation() as NSDictionary, preferences)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.confirmedReleases, 1)
        XCTAssertEqual(calls.connections, 0)
        XCTAssertEqual(calls.pairingMutations, 0)

        model.finishDeviceConnectionRepair()
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.deviceSession.owner)
        XCTAssertTrue(model.canSend)
        XCTAssertNotNil(model.bluetoothMonitor)
        model.bluetoothMonitor?.cancel(); model.bluetoothMonitor = nil
    }

    func testHIDDisconnectDoesNotRequireNetworkMediaConfirmation() async throws {
        let fixture = try RepairFixture(method: .bluetoothBoard, releaseConfirmed: false)
        let result = await fixture.model.repairDeviceConnection()
        XCTAssertEqual(result, .released)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.disconnects, 0)
        XCTAssertEqual(calls.confirmedReleases, 1, "The shared actuator returns release evidence; HID repair must ignore an unconfirmed network-media result.")
        XCTAssertEqual(calls.connections, 0)
        fixture.model.finishDeviceConnectionRepair()
    }

    func testHIDRepairAlsoChecksRetainedNetworkCleanup() async throws {
        for confirmed in [true, false] {
            let fixture = try RepairFixture(method: .bluetoothBoard, connected: false)
            let network = RepairController(connected: true, releaseConfirmed: confirmed)
            fixture.model.networkDeviceClient = DeviceClient(actuator: network, networkSetup: network)
            let result = await fixture.model.repairDeviceConnection()
            XCTAssertEqual(result, confirmed ? .released : .unconfirmed)
            let calls = await network.calls()
            XCTAssertEqual(calls.confirmedReleases, 1)
            XCTAssertEqual(calls.connections, 0)
            XCTAssertEqual(calls.pairingMutations, 0)
            XCTAssertNotNil(fixture.model.networkDeviceClient)
            fixture.model.finishDeviceConnectionRepair()
        }
    }

    func testDisconnectedNoopCannotClaimAnOrphanWasReleased() async throws {
        let fixture = try RepairFixture(connected: false)
        let result = await fixture.model.repairDeviceConnection()
        XCTAssertEqual(result, .notConnected)
        XCTAssertTrue(fixture.model.isRepairingDeviceConnection)
        fixture.model.finishDeviceConnectionRepair()
    }

    func testUnconfirmedOrStillReadyConnectionNeverReportsReleased() async throws {
        for (confirmed, staysConnected) in [(false, false), (true, true)] {
            let fixture = try RepairFixture(releaseConfirmed: confirmed, staysConnected: staysConnected)
            let result = await fixture.model.repairDeviceConnection()
            XCTAssertEqual(result, .unconfirmed)
            XCTAssertTrue(fixture.model.isRepairingDeviceConnection)
            XCTAssertNil(fixture.model.activeDeviceConnectionMethod)
            XCTAssertTrue(fixture.model.deviceSession.hasUnconfirmedRelease)
            let calls = await fixture.controller.calls()
            XCTAssertEqual(calls.connections, 0)
            fixture.model.finishDeviceConnectionRepair()
        }
    }

    func testConfirmedRepairAfterUnconfirmedDictationReleaseAllowsANewRunOnlyAfterMicrophoneTeardown() async throws {
        let fixture = try RepairFixture()
        let model = fixture.model, dictationID = UUID()
        await fixture.controller.setReleaseConfirmed(false)
        do { try await model.prepareDeviceForDictation(id: dictationID); XCTFail("Unconfirmed media cannot authorize capture.") }
        catch DictationDevicePreparationError.releaseUnconfirmed { }
        _ = await model.finishDeviceDictation(id: dictationID)
        XCTAssertTrue(model.deviceSession.hasUnconfirmedRelease)
        XCTAssertNil(model.deviceSession.owner)
        XCTAssertThrowsError(try model.deviceSession.acquire(.run(UUID())))

        await fixture.controller.setReleaseConfirmed(true)
        let result = await model.repairDeviceConnection()
        XCTAssertEqual(result, .notConnected, "The current disconnected client cannot prove release of an orphan session.")
        XCTAssertFalse(model.deviceSession.hasUnconfirmedRelease)
        XCTAssertEqual(model.deviceSession.owner, .repair)
        XCTAssertThrowsError(try model.deviceSession.acquire(.run(UUID())))
        model.finishDeviceConnectionRepair()
        let run = try model.deviceSession.acquire(.run(UUID()))
        run.release()
        XCTAssertNil(model.deviceSession.owner)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.confirmedReleases, 2); XCTAssertEqual(calls.connections, 0)
    }

    func testIdleRepairKeepsReleaseProgressHiddenWhileRetainingTheRepairClaim() async throws {
        let fixture = try RepairFixture(connected: false, suspendsRelease: true)
        let repair = Task { await fixture.model.repairDeviceConnection() }
        try await waitForRelease(fixture.controller)
        XCTAssertEqual(fixture.model.deviceSession.owner, .repair)
        XCTAssertTrue(fixture.model.deviceSession.isTransitioning)
        XCTAssertFalse(fixture.model.isConnecting)
        await fixture.controller.completeRelease()
        let result = await repair.value
        XCTAssertEqual(result, .notConnected)
        fixture.model.finishDeviceConnectionRepair()
    }

    func testRepairRejectsLoadingBackgroundConnectionAndSpeechPreparation() async throws {
        let blockers: [(AppModel) -> Void] = [
            { $0.isLoading = true }, { $0.currentScenePhase = .background },
            { $0.isSaving = true }, { $0.isPairing = true }, { $0.isConnecting = true },
            { $0.isManagingTunnel = true },
            { model in
                model.runCoordinator.publish(RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: .now,
                    scope: .control, model: "fixture", skill: nil, state: .running, detail: "", events: []))
                model.runCoordinator.updateSnapshot { $0.isCancelling = true }
            },
            { $0.dictationPreparationID = UUID() },
            { model in
                model.dictationDeviceRestoration = DictationDeviceRestoration(id: UUID(), operationID: UUID(),
                    method: .usbBoard, preference: .automatic, backend: .coreDevice, client: model.deviceClient)
            },
        ]
        for block in blockers {
            let fixture = try RepairFixture()
            block(fixture.model)
            XCTAssertFalse(fixture.model.canRepairDeviceConnection)
            let result = await fixture.model.repairDeviceConnection()
            XCTAssertEqual(result, .busy)
            XCTAssertFalse(fixture.model.isRepairingDeviceConnection)
            let calls = await fixture.controller.calls()
            XCTAssertEqual(calls.confirmedReleases, 0)
        }
    }

    func testRepairRejectsActiveRunAndPreservesSettledPausedAndInterruptedRuns() async throws {
        for state in [RunState.running, .paused, .interrupted] {
            let fixture = try RepairFixture()
            let model = fixture.model
            let conversationID = UUID()
            let run = RunRecord(id: UUID(), conversationID: conversationID, requestID: UUID(), startedAt: .now,
                scope: .control, model: "fixture", skill: nil, state: state, detail: "", events: [])
            model.selectedConversationID = conversationID
            if state == .running { model.runCoordinator.publish(run) }
            else { model.runs = [run] }
            if state == .interrupted { model.interruptedConversationIDs.insert(conversationID) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let storedRuns = try encoder.encode(model.runs)
            let interruptions = model.interruptedConversationIDs
            let scope = model.scope
            let activeRunID = model.activeRun?.id
            XCTAssertEqual(model.canRepairDeviceConnection, state != .running)
            let result = await model.repairDeviceConnection()
            XCTAssertEqual(result, state == .running ? .busy : .released)
            XCTAssertEqual(try encoder.encode(model.runs), storedRuns)
            XCTAssertEqual(model.interruptedConversationIDs, interruptions)
            XCTAssertEqual(model.selectedConversationID, conversationID)
            XCTAssertEqual(model.scope, scope)
            XCTAssertEqual(model.activeRun?.id, activeRunID)
            XCTAssertEqual(model.pausedRun?.id, state == .paused ? run.id : nil)
            XCTAssertEqual(model.needsRecovery, state == .interrupted)
            let calls = await fixture.controller.calls()
            XCTAssertEqual(calls.confirmedReleases, state == .running ? 0 : 1)
            XCTAssertEqual(calls.connections, 0)
            if state != .running { model.finishDeviceConnectionRepair() }
        }
    }

    func testCancelledRepairWaitsForReleaseAndCannotUnlockEarlyOrReconnect() async throws {
        for finishEarly in [false, true] {
            let fixture = try RepairFixture(suspendsRelease: true)
            let model = fixture.model
            let repair = Task { await model.repairDeviceConnection() }
            try await waitForRelease(fixture.controller)
            repair.cancel()
            if finishEarly { model.finishDeviceConnectionRepair() }
            XCTAssertTrue(model.isRepairingDeviceConnection)
            let duplicate = await model.repairDeviceConnection()
            XCTAssertEqual(duplicate, .busy)
            await model.connectDevice()
            await fixture.controller.completeRelease()
            let result = await repair.value
            XCTAssertEqual(result, .cancelled)
            XCTAssertEqual(model.isRepairingDeviceConnection, !finishEarly)
            XCTAssertFalse(model.isDeviceReady)
            let calls = await fixture.controller.calls()
            XCTAssertEqual(calls.confirmedReleases, 1)
            XCTAssertEqual(calls.connections, 0)
            XCTAssertFalse(calls.releaseWasCancelled)
            model.finishDeviceConnectionRepair()
            XCTAssertFalse(model.isRepairingDeviceConnection)
        }
    }

    func testBackgroundingDuringReleaseReturnsCancelledAndKeepsGateUntilFinish() async throws {
        let fixture = try RepairFixture(suspendsRelease: true)
        let repair = Task { await fixture.model.repairDeviceConnection() }
        try await waitForRelease(fixture.controller)
        fixture.model.sceneChanged(.background)
        await fixture.controller.completeRelease()
        let result = await repair.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(fixture.model.isRepairingDeviceConnection)
        fixture.model.finishDeviceConnectionRepair()
        XCTAssertFalse(fixture.model.isRepairingDeviceConnection)
    }

    func testCancellationBeforeOwnershipReturnsBusyWithoutAcquiringGate() async throws {
        let fixture = try RepairFixture()
        let repair = Task { await fixture.model.repairDeviceConnection() }
        repair.cancel()
        let result = await repair.value
        XCTAssertEqual(result, .busy)
        XCTAssertFalse(fixture.model.isRepairingDeviceConnection)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.confirmedReleases, 0)
    }

    func testSettledInvalidDictationRestorationCannotReconnectAfterRepair() async throws {
        let fixture = try RepairFixture()
        let model = fixture.model
        let restoration = DictationDeviceRestoration(id: UUID(), operationID: model.deviceOperationID,
            method: .usbBoard, preference: .automatic, backend: .coreDevice, client: model.deviceClient)
        restoration.isValid = false; restoration.releaseFinished = true
        model.dictationDeviceRestoration = restoration
        let result = await model.repairDeviceConnection()
        XCTAssertEqual(result, .released)
        XCTAssertNil(model.dictationDeviceRestoration)
        _ = await model.finishDeviceDictation(id: restoration.id)
        let calls = await fixture.controller.calls()
        XCTAssertEqual(calls.connections, 0)
        model.finishDeviceConnectionRepair()
    }

    private func waitForRelease(_ controller: RepairController) async throws {
        for _ in 0..<200 {
            if await controller.hasPendingRelease() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Repair never reached the controlled release.")
        throw CancellationError()
    }
}

@MainActor private final class RepairFixture {
    let suite = "DeviceConnectionRepairTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let model: AppModel
    let controller: RepairController

    init(method: DeviceConnectionMethod = .usbBoard, connected: Bool = true, releaseConfirmed: Bool = true,
         staysConnected: Bool = false, suspendsRelease: Bool = false) throws {
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(method.rawValue, forKey: "deviceConnectionMethod")
        preferences.set(DeviceControlBackend.automatic.rawValue, forKey: "deviceControlBackend")
        controller = RepairController(connected: connected, releaseConfirmed: releaseConfirmed,
            staysConnected: staysConnected, suspendsRelease: suspendsRelease)
        model = AppModel(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
            preferences: preferences, credentialStore: CredentialStore(service: suite),
            operatingSystemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        model.deviceClient = DeviceClient(actuator: controller, networkSetup: controller)
        model.networkDeviceClient = nil
        model.isLoading = false; model.hasPairingIdentity = true
        if connected {
            model.deviceStatus = .ready(capabilities: [.screenshot, .tap])
            model.activeDeviceConnectionMethod = method
            model.activeDeviceControlBackend = method == .bluetoothBoard ? nil : .coreDevice
        }
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

private actor RepairController: DeviceFixtureActuator {
    var fixtureObservedFrameID: UUID?
    var fixtureGeometry: DeviceFrameGeometry?
    private var connected: Bool
    private var releaseConfirmed: Bool
    private let staysConnected: Bool
    private let suspendsRelease: Bool
    private var pendingRelease: CheckedContinuation<Void, Never>?
    private var disconnects = 0
    private var confirmedReleases = 0
    private var connections = 0
    private var pairingMutations = 0
    private var releaseWasCancelled = false

    init(connected: Bool, releaseConfirmed: Bool, staysConnected: Bool = false, suspendsRelease: Bool = false) {
        self.connected = connected; self.releaseConfirmed = releaseConfirmed
        self.staysConnected = staysConnected; self.suspendsRelease = suspendsRelease
    }
    func status() async -> DeviceStatus {
        connected ? .ready(capabilities: [.screenshot, .tap]) : .unavailable(reason: "Fixture disconnected")
    }
    func hasPairingIdentity() async throws -> Bool { true }
    func importPairingIdentity(_ data: Data) async throws { pairingMutations += 1 }
    func removePairingIdentity() async throws { pairingMutations += 1 }
    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        pairingMutations += 1
        return AsyncThrowingStream { $0.finish() }
    }
    func connectUSBBoard(backend: DeviceControlBackend) async throws { connections += 1; connected = true }
    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws {
        connections += 1; connected = true
    }
    func connectBluetoothBoard() async throws { connections += 1; connected = true }
    func fixtureDisconnect() async { disconnects += 1; connected = staysConnected }
    func fixtureDisconnectAndConfirmRelease() async -> Bool {
        confirmedReleases += 1
        if suspendsRelease { await withCheckedContinuation { pendingRelease = $0 } }
        releaseWasCancelled = Task.isCancelled
        connected = staysConnected
        return releaseConfirmed
    }
    func hasPendingRelease() -> Bool { pendingRelease != nil }
    func setReleaseConfirmed(_ value: Bool) { releaseConfirmed = value }
    func completeRelease() { pendingRelease?.resume(); pendingRelease = nil }
    func calls() -> (disconnects: Int, confirmedReleases: Int, connections: Int, pairingMutations: Int, releaseWasCancelled: Bool) {
        (disconnects, confirmedReleases, connections, pairingMutations, releaseWasCancelled)
    }
}
