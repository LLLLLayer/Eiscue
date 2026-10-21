import EiscueDeviceCore
import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class ForegroundTunnelReconciliationTests: XCTestCase {
    func testReturningVPNConnectWaitsForForegroundReadBeforePublishingReady() async throws {
        let fixture = try RestoringFixture(method: .localVPN); defer { fixture.close() }
        let id = try await fixture.prepare()
        let restoration = try XCTUnwrap(fixture.model.dictationDeviceRestoration)
        let finish = Task { await fixture.model.finishDeviceDictation(id: id) }
        try await waitUntil { await fixture.controller.hasPendingConnection }
        fixture.model.sceneChanged(.inactive)
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 1 }
        await fixture.controller.completeConnection()
        try await waitUntil { restoration.foregroundWaiter != nil }
        XCTAssertTrue(fixture.model.isReconcilingForegroundTunnel)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertEqual(fixture.model.deviceSession.owner, .dictation(id))
        XCTAssertTrue(fixture.model.deviceSession.isTransitioning)
        fixture.reads.complete(1)
        try await waitUntil { fixture.model.dictationDeviceRestoration == nil }
        let error = await finish.value
        XCTAssertNil(error)
        XCTAssertTrue(fixture.model.isDeviceReady)
        XCTAssertFalse(fixture.model.isReconcilingForegroundTunnel)
        XCTAssertNil(fixture.model.deviceSession.owner)
        XCTAssertNil(fixture.model.dictationDeviceRestoration)
        let calls = await fixture.controller.calls
        XCTAssertEqual(calls.connections, 2)
        XCTAssertEqual(calls.disconnects, 1)
    }

    func testForegroundReadLossCleansReturnedVPNConnectBeforeReleasingLease() async throws {
        let fixture = try RestoringFixture(method: .localVPN); defer { fixture.close() }
        let id = try await fixture.prepare()
        let restoration = try XCTUnwrap(fixture.model.dictationDeviceRestoration)
        let finish = Task { await fixture.model.finishDeviceDictation(id: id) }
        try await waitUntil { await fixture.controller.hasPendingConnection }
        fixture.model.sceneChanged(.inactive)
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 1 }
        await fixture.controller.completeConnection()
        try await waitUntil { restoration.foregroundWaiter != nil }
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertEqual(fixture.model.deviceSession.owner, .dictation(id))
        await fixture.controller.suspendNextDisconnect()
        fixture.reads.complete(1, disconnected: true)
        try await waitUntil { await fixture.controller.hasPendingDisconnect }
        XCTAssertFalse(restoration.isValid)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertEqual(fixture.model.deviceSession.owner, .dictation(id))
        await fixture.controller.completeDisconnect()
        try await waitUntil { fixture.model.dictationDeviceRestoration == nil }
        let error = await finish.value
        XCTAssertNil(error)
        XCTAssertFalse(fixture.model.isDeviceReady)
        XCTAssertNil(fixture.model.deviceSession.owner)
        XCTAssertNil(fixture.model.dictationDeviceRestoration)
        XCTAssertFalse(fixture.model.deviceSession.hasUnconfirmedRelease)
        let calls = await fixture.controller.calls
        XCTAssertEqual(calls.connections, 2)
        XCTAssertEqual(calls.disconnects, 2)
    }

    func testReturningUSBConnectDoesNotWaitForUnrelatedVPNRead() async throws {
        let fixture = try RestoringFixture(method: .usbBoard); defer { fixture.close() }
        let id = try await fixture.prepare()
        let finish = Task { await fixture.model.finishDeviceDictation(id: id) }
        try await waitUntil { await fixture.controller.hasPendingConnection }
        fixture.model.sceneChanged(.inactive)
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 1 }
        await fixture.controller.completeConnection()
        try await waitUntil { fixture.model.dictationDeviceRestoration == nil }
        let error = await finish.value
        XCTAssertNil(error)
        XCTAssertTrue(fixture.model.isReconcilingForegroundTunnel)
        XCTAssertTrue(fixture.model.isDeviceReady)
        XCTAssertEqual(fixture.model.activeDeviceConnectionMethod, .usbBoard)
        XCTAssertNil(fixture.model.deviceSession.owner)
        fixture.reads.complete(1)
    }

    func testForegroundWaitsForTunnelReadBeforeWakingDictation() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let pending = await fixture.waitingRestoration()
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 1 }
        XCTAssertFalse(pending.woke)
        fixture.reads.complete(1)
        try await waitUntil { pending.woke }
        XCTAssertEqual(pending.validWhenWoken, true)
    }

    func testInactiveAndNewActiveIgnoreLatePriorCompletion() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let pending = await fixture.waitingRestoration()
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 1 }
        fixture.model.sceneChanged(.inactive)
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 2 }
        fixture.model.connectionMessage = "Newer connection notice"
        fixture.reads.complete(1, failure: true)
        try await waitUntil { fixture.reads.returned.contains(1) }
        XCTAssertFalse(pending.woke)
        XCTAssertEqual(fixture.model.connectionMessage, "Newer connection notice")
        fixture.reads.complete(2)
        try await waitUntil { pending.woke }
        XCTAssertEqual(pending.validWhenWoken, true)
    }

    func testBackgroundInvalidatesOldRestorationAndLateReadCannotWakeNewOne() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let old = await fixture.waitingRestoration()
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 1 }
        fixture.model.sceneChanged(.background)
        try await waitUntil { old.woke }
        XCTAssertEqual(old.validWhenWoken, false)
        let newer = await fixture.waitingRestoration()
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 2 }
        fixture.reads.complete(1)
        try await waitUntil { fixture.reads.returned.contains(1) }
        XCTAssertFalse(newer.woke)
        fixture.reads.complete(2)
        try await waitUntil { newer.woke }
        XCTAssertEqual(newer.validWhenWoken, true)
    }

    func testCurrentSceneReadReleasesReplacementRestorationWaitingOnSameGate() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let old = await fixture.waitingRestoration()
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 1 }
        fixture.model.invalidateDictationDeviceRestoration()
        try await waitUntil { old.woke }
        let newer = await fixture.waitingRestoration()
        fixture.reads.complete(1)
        try await waitUntil { newer.woke }
        XCTAssertEqual(newer.validWhenWoken, true)
    }

    func testObservedTunnelLossInvalidatesBeforeWakingRestoration() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let pending = await fixture.waitingRestoration()
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 1 }
        // Simulate refresh discovering a lost tunnel, without delivering an NE
        // notification. Use the production loss callback and invalidation path.
        fixture.reads.complete(1, disconnected: true)
        try await waitUntil { pending.woke }
        XCTAssertEqual(pending.validWhenWoken, false)
        XCTAssertFalse(fixture.model.isDeviceReady)
    }

    func testSuccessfulReadDoesNotDisconnectAnIdleReadyConnection() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.model.activeDeviceConnectionMethod = .localVPN
        fixture.model.activeDeviceControlBackend = .coreDevice
        fixture.model.deviceStatus = .ready(capabilities: [.screenshot, .tap])
        let identity = fixture.model.deviceSession.identity
        fixture.model.sceneChanged(.background)
        fixture.model.sceneChanged(.active)
        try await waitUntil { fixture.reads.started == 1 }
        fixture.reads.complete(1)
        try await waitUntil { fixture.reads.returned.contains(1) }
        XCTAssertTrue(fixture.model.isDeviceReady)
        XCTAssertEqual(fixture.model.activeDeviceConnectionMethod, .localVPN)
        XCTAssertTrue(fixture.model.deviceSession.isCurrent(identity))
        XCTAssertNil(fixture.model.deviceConnectionTask)
    }

    func testUnreadableTunnelInvalidatesOnlyItsPendingRestoration() async throws {
        for method in [DeviceConnectionMethod.localVPN, .usbBoard] {
            let fixture = try Fixture(); defer { fixture.close() }
            let pending = await fixture.waitingRestoration(method: method)
            fixture.model.sceneChanged(.active)
            try await waitUntil { fixture.reads.started == 1 }
            fixture.reads.complete(1, failure: true)
            try await waitUntil { pending.woke && fixture.reads.returned.contains(1) }
            XCTAssertEqual(pending.validWhenWoken, method != .localVPN)
            XCTAssertEqual(fixture.model.connectionMessage, ReadFailure.unavailable.localizedDescription)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Foreground reconciliation did not reach the expected boundary.")
        throw ReadFailure.unavailable
    }
}

@MainActor private final class Fixture {
    let suite = "ForegroundTunnelReconciliationTests.\(UUID().uuidString)"
    let reads = PendingReads()
    let model: AppModel
    init() throws {
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set("localVPN", forKey: "deviceConnectionMethod")
        let reads = reads
        model = AppModel(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
            preferences: preferences, credentialStore: CredentialStore(service: suite),
            refreshLocalTunnel: { try await reads.read($0) })
    }
    func waitingRestoration(method: DeviceConnectionMethod = .localVPN) async -> WaitingRestoration {
        let restoration = DictationDeviceRestoration(id: UUID(), operationID: model.deviceOperationID,
            method: method, preference: model.deviceControlBackend, backend: .coreDevice, client: model.deviceClient)
        model.dictationDeviceRestoration = restoration
        let pending = WaitingRestoration(restoration)
        Task { await pending.wait() }
        while restoration.foregroundWaiter == nil { await Task.yield() }
        return pending
    }
    func close() {
        model.sceneChanged(.inactive)
        model.invalidateDictationDeviceRestoration()
        for id in Array(reads.pending.keys) { reads.complete(id) }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

@MainActor private final class WaitingRestoration {
    let restoration: DictationDeviceRestoration
    var woke = false
    var validWhenWoken: Bool?
    init(_ restoration: DictationDeviceRestoration) { self.restoration = restoration }
    func wait() async {
        await withCheckedContinuation { restoration.foregroundWaiter = $0 }
        validWhenWoken = restoration.isValid
        woke = true
    }
}

@MainActor private final class PendingReads {
    var started = 0
    var cachedConnected = true
    var returned: Set<Int> = []
    var pending: [Int: (LocalTunnelManager, CheckedContinuation<Void, any Error>)] = [:]
    func read(_ tunnel: LocalTunnelManager) async throws {
        started += 1
        let id = started
        defer { returned.insert(id) }
        // Intentionally ignores cancellation, like an already submitted system
        // preference read; AppModel must reject its late completion by identity.
        try await withCheckedThrowingContinuation { pending[id] = (tunnel, $0) }
    }
    func complete(_ id: Int, disconnected: Bool = false, failure: Bool = false) {
        guard let (tunnel, completion) = pending.removeValue(forKey: id) else { return }
        if disconnected { cachedConnected = false; tunnel.onDisconnect?() }
        if failure { completion.resume(throwing: ReadFailure.unavailable) }
        else { completion.resume() }
    }
}

@MainActor private final class RestoringFixture {
    let suite = "ForegroundTunnelRestorationTests.\(UUID().uuidString)"
    let reads = PendingReads()
    let controller = ReturningConnection()
    let model: AppModel
    let method: DeviceConnectionMethod
    init(method: DeviceConnectionMethod) throws {
        self.method = method
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(method.rawValue, forKey: "deviceConnectionMethod")
        preferences.set("coreDevice", forKey: "deviceControlBackend")
        let reads = reads
        model = AppModel(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite),
            preferences: preferences, credentialStore: CredentialStore(service: suite),
            operatingSystemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            refreshLocalTunnel: { try await reads.read($0) })
        model.deviceClient = DeviceClient(actuator: controller, networkSetup: controller)
        model.dictationSession = DictationSession(model: model, isLocalTunnelConnected: { _ in reads.cachedConnected })
    }
    func prepare() async throws -> UUID {
        let connection = try model.deviceSession.beginConnection(method: method, backend: .coreDevice)
        try await model.deviceClient.connect(method: method, backend: .coreDevice)
        let status = await model.deviceClient.status()
        XCTAssertTrue(model.deviceSession.completeConnection(connection, status: status))
        let id = UUID()
        try await model.prepareDeviceForDictation(id: id)
        await controller.suspendNextConnection()
        return id
    }
    func close() {
        model.sceneChanged(.background)
        for id in Array(reads.pending.keys) { reads.complete(id) }
        Task { await controller.completeConnection(); await controller.completeDisconnect() }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

private actor ReturningConnection: DeviceFixtureActuator {
    var fixtureObservedFrameID: UUID?
    var fixtureGeometry: DeviceFrameGeometry?
    private var connected = false
    private var connections = 0
    private var disconnects = 0
    private var holdsConnection = false
    private var holdsDisconnect = false
    private var connection: CheckedContinuation<Void, Never>?
    private var disconnection: CheckedContinuation<Void, Never>?
    var hasPendingConnection: Bool { connection != nil }
    var hasPendingDisconnect: Bool { disconnection != nil }
    var calls: (connections: Int, disconnects: Int) { (connections, disconnects) }
    func status() async -> DeviceStatus {
        connected ? .ready(capabilities: [.screenshot, .tap]) : .unavailable(reason: "Fixture disconnected")
    }
    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws { await connect() }
    func connectUSBBoard(backend: DeviceControlBackend) async throws { await connect() }
    private func connect() async {
        connections += 1
        if holdsConnection {
            holdsConnection = false
            await withCheckedContinuation { connection = $0 }
        }
        connected = true
    }
    func fixtureDisconnectAndConfirmRelease() async -> Bool {
        disconnects += 1
        connected = false
        if holdsDisconnect {
            holdsDisconnect = false
            await withCheckedContinuation { disconnection = $0 }
        }
        return true
    }
    func suspendNextConnection() { holdsConnection = true }
    func suspendNextDisconnect() { holdsDisconnect = true }
    func completeConnection() { let pending = connection; connection = nil; pending?.resume() }
    func completeDisconnect() { let pending = disconnection; disconnection = nil; pending?.resume() }
}

private enum ReadFailure: Error { case unavailable }
