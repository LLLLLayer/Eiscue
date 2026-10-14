import Foundation
import Testing
@testable import EiscueDeviceKit

@Suite struct DeviceKitTests {
    private func screenshot(width: Int = 100, height: Int = 200) -> DeviceScreenshot {
        DeviceScreenshot(width: width, height: height, mimeType: "image/jpeg", data: Data([1]))
    }

    @Test func coordinatesUseScreenshotPixelsAndFrameIsConsumedOnce() throws {
        var ledger = FrameLedger()
        let frame = screenshot()
        ledger.record(frame)
        let result = try ledger.consume(id: frame.frameID, points: [DevicePoint(x: 50, y: 100)])
        #expect(result.count == 1)
        #expect(result[0].0 == 32768)
        #expect(result[0].1 == 32768)
        #expect(throws: DeviceControlError.staleFrame) {
            try ledger.consume(id: frame.frameID, points: [DevicePoint(x: 0, y: 0)])
        }
    }

    @Test func expiredAndPreviousFramesCannotAuthorizeActions() throws {
        var ledger = FrameLedger()
        let time = ContinuousClock.now
        let old = screenshot(), current = screenshot()
        ledger.record(old, now: time)
        #expect(throws: DeviceControlError.staleFrame) {
            try ledger.consume(id: old.frameID, points: [], now: time.advanced(by: .seconds(31)))
        }
        ledger.record(current)
        #expect(throws: DeviceControlError.staleFrame) { try ledger.consume(id: old.frameID, points: []) }
        ledger.invalidate()
        #expect(throws: DeviceControlError.staleFrame) { try ledger.consume(id: current.frameID, points: []) }
    }

    @Test func invalidCoordinatesDoNotConsumeValidFrame() throws {
        var ledger = FrameLedger()
        let frame = screenshot()
        ledger.record(frame)
        for point in [DevicePoint(x: -1, y: 0), DevicePoint(x: 100, y: 0), DevicePoint(x: 0, y: 200), DevicePoint(x: .infinity, y: 0), DevicePoint(x: .nan, y: 0)] {
            #expect(throws: DeviceControlError.invalidCoordinates) { try ledger.consume(id: frame.frameID, points: [point]) }
        }
        #expect(try ledger.consume(id: frame.frameID, points: [DevicePoint(x: 99, y: 199)]).count == 1)
    }

    @Test func textConsumesAnObservationWithoutCoordinates() throws {
        var ledger = FrameLedger()
        let frame = screenshot()
        ledger.record(frame)
        #expect(try ledger.consume(id: frame.frameID, points: []).isEmpty)
        #expect(throws: DeviceControlError.staleFrame) { try ledger.consume(id: frame.frameID, points: []) }
    }

    @Test func validatesIdentitySchemaSizeAndCommitState() throws {
        let valid = try fixtureIdentity()
        #expect(try PairingIdentityCodec.decode(valid).committed)
        #expect(throws: DeviceControlError.invalidIdentity) { try PairingIdentityCodec.decode(Data(repeating: 1, count: 32769)) }
        #expect(throws: DeviceControlError.invalidIdentity) { try PairingIdentityCodec.decode(Data("bad".utf8)) }
        #expect(throws: DeviceControlError.invalidIdentity) { try PairingIdentityCodec.decode(fixtureIdentity(version: 2)) }
        #expect(throws: DeviceControlError.invalidIdentity) { try PairingIdentityCodec.decode(fixtureIdentity(committed: false)) }
        #expect(try PairingIdentityCodec.decode(fixtureIdentity(committed: false), requireCommitted: false).committed == false)
    }

    @Test func hostCanInjectProtectedStorageAndBadImportDoesNotOverwriteIt() async throws {
        let store = MemoryIdentityStore()
        let client = DeviceClient(identityStore: store)
        #expect(try await client.hasPairingIdentity() == false)
        try await client.importPairingIdentity(fixtureIdentity())
        #expect(try await client.hasPairingIdentity())
        let saved = try store.load()
        await #expect(throws: DeviceControlError.invalidIdentity) { try await client.importPairingIdentity(Data("broken".utf8)) }
        #expect(try store.load() == saved)
        try await client.removePairingIdentity()
        #expect(try await client.hasPairingIdentity() == false)
    }

    @Test func storageFailurePropagatesWithoutClaimingIdentityWasSaved() async throws {
        let store = MemoryIdentityStore(failWrites: true)
        let client = DeviceClient(identityStore: store)
        await #expect(throws: DeviceControlError.keychain(-1)) { try await client.importPairingIdentity(fixtureIdentity()) }
        #expect(try await client.hasPairingIdentity() == false)
    }

    @Test func defaultBackendCannotReportReadyOnHostOrSimulator() async throws {
        #if !os(iOS) || targetEnvironment(simulator)
        let client = DeviceClient(identityStore: MemoryIdentityStore())
        #expect(await client.status() == .unavailable(reason: DeviceControlError.unsupported.localizedDescription))
        await #expect(throws: DeviceControlError.unsupported) { try await client.connectLocalVPN() }
        let events = await client.beginPairing()
        await #expect(throws: DeviceControlError.unsupported) {
            for try await _ in events { Issue.record("Unsupported host must not yield pairing events") }
        }
        #endif
    }

    @Test func customControllerWorksWithoutNativeBackend() async throws {
        let frame = screenshot()
        let controller = RecordingController(frame: frame)
        let client = DeviceClient(controller: controller)
        #expect(try await client.captureScreenshot() == frame)
        try await client.tap(at: DevicePoint(x: 1, y: 2), frameID: frame.frameID)
        #expect(await controller.tappedFrame == frame.frameID)
        await client.disconnect()
        #expect(await controller.disconnected)
    }

    @Test func localVPNPairingNeverFallsBackToGenericPairing() async throws {
        let controller = RecordingController(frame: screenshot())
        let client = DeviceClient(controller: controller)
        let local = await client.beginPairing(configuration: .defaults)
        await #expect(throws: DeviceControlError.unsupported) {
            for try await _ in local { Issue.record("Unsupported local pairing must not yield events") }
        }
        #expect(await controller.genericPairingCalls == 0)
        let generic = await client.beginPairing()
        var completed = false
        for try await event in generic { if case .completed = event { completed = true } }
        #expect(completed)
        #expect(await controller.genericPairingCalls == 1)
    }

    @Test func unknownDeliveryIsMachineReadable() {
        #expect(DeviceControlError.deliveryUnknown("transport").isDeliveryUnknown)
        #expect(!DeviceControlError.staleFrame.isDeliveryUnknown)
    }

    @Test func inputValidationMatchesNativePayloadLimitsBeforeSubmission() throws {
        try DeviceInputValidation.text("你好，Eiscue")
        try DeviceInputValidation.text(String(repeating: "a", count: 8192))
        #expect(throws: DeviceControlError.invalidText) { try DeviceInputValidation.text(String(repeating: "a", count: 8193)) }
        #expect(throws: DeviceControlError.invalidText) { try DeviceInputValidation.text(String(repeating: "\"", count: 8192)) }
        #expect(throws: DeviceControlError.invalidText) { try DeviceInputValidation.text("a\0b") }
        try DeviceInputValidation.bundleID("org.eiscue.test-app_1")
        #expect(throws: DeviceControlError.invalidBundleID) { try DeviceInputValidation.bundleID("org.eiscue.应用") }
        #expect(throws: DeviceControlError.invalidBundleID) { try DeviceInputValidation.bundleID("org/eiscue") }
    }

    @Test func pairingCommitCannotChangeIdentityOrRegressCommitState() throws {
        let provisionalData = try fixtureIdentity(committed: false)
        let finalData = try fixtureIdentity()
        let final = try PairingIdentityCodec.decode(finalData)
        try PairingIdentityCodec.validateTransition(from: provisionalData, to: final)
        let provisional = try PairingIdentityCodec.decode(provisionalData, requireCommitted: false)
        #expect(throws: DeviceControlError.invalidIdentity) { try PairingIdentityCodec.validateTransition(from: finalData, to: provisional) }
        var modified = try #require(JSONSerialization.jsonObject(with: finalData) as? [String: Any])
        modified["peerID"] = "OTHER-PEER"
        let changed = try PairingIdentityCodec.decode(JSONSerialization.data(withJSONObject: modified))
        #expect(throws: DeviceControlError.invalidIdentity) { try PairingIdentityCodec.validateTransition(from: provisionalData, to: changed) }
    }
}

private func fixtureIdentity(version: Int = 1, committed: Bool = true) throws -> Data {
    // Synthetic values only; never captured from a real device.
    try JSONSerialization.data(withJSONObject: [
        "version": version, "seed": Array(repeating: 66, count: 32), "controllerID": "TEST-CONTROLLER",
        "peerID": "TEST-PEER", "peerPublicKey": Array(repeating: 68, count: 32),
        "alternateIRK": Array(repeating: 51, count: 16), "peerUDID": "TEST-UDID", "peerModel": "TEST-MODEL", "committed": committed,
    ])
}

private final class MemoryIdentityStore: PairingIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private let failWrites: Bool
    init(failWrites: Bool = false) { self.failWrites = failWrites }
    func load() throws -> Data? { lock.withLock { data } }
    func save(_ data: Data) throws {
        if failWrites { throw DeviceControlError.keychain(-1) }
        lock.withLock { self.data = data }
    }
    func remove() throws { lock.withLock { data = nil } }
}

private actor RecordingController: DeviceController {
    var genericPairingCalls = 0
    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error> {
        genericPairingCalls += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed); continuation.finish()
        }
    }
    let frame: DeviceScreenshot
    var tappedFrame: UUID?
    var disconnected = false
    init(frame: DeviceScreenshot) { self.frame = frame }
    func status() async -> DeviceStatus { .ready(capabilities: [.screenshot, .tap]) }
    func captureScreenshot() async throws -> DeviceScreenshot { frame }
    func tap(at point: DevicePoint, frameID: UUID) async throws { tappedFrame = frameID }
    func disconnect() async { disconnected = true }
}
