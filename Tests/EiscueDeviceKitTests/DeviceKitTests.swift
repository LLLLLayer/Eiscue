import Foundation
import Testing
@testable import EiscueDeviceKit
@testable import EiscueDeviceCore

@Suite struct DeviceKitTests {
    private func screenshot(width: Int = 100, height: Int = 200) -> DeviceScreenshot {
        DeviceScreenshot(width: width, height: height, mimeType: "image/jpeg", data: Data([1]))
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
        let client = DeviceClient(actuator: controller)
        let observation = try await client.captureScreenshot()
        #expect(observation.data == frame.data && observation.width == frame.width)
        try await client.tap(at: DevicePoint(x: 1, y: 2), frameID: observation.frameID)
        #expect(await controller.tappedFrame == observation.frameID)
        await client.disconnect()
        #expect(await controller.disconnected)
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
        try DeviceInputValidation.bundleID("org.eiscue.test-app-1")
        #expect(throws: DeviceControlError.invalidBundleID) { try DeviceInputValidation.bundleID("org.eiscue.test_app") }
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

private actor RecordingController: DeviceActuator {
    let frame: DeviceScreenshot
    let session = UUID()
    var tappedFrame: UUID?
    var disconnected = false
    init(frame: DeviceScreenshot) { self.frame = frame }
    func cachedStatus() async -> DeviceStatus { .ready(capabilities: [.screenshot, .tap]) }
    func probe() async -> DeviceStatus { await cachedStatus() }
    func capture() async throws -> DeviceScreenshot {
        DeviceScreenshot(width: frame.width, height: frame.height, mimeType: frame.mimeType, data: frame.data,
            geometry: DeviceFrameGeometry(sessionID: session, revision: "1", width: frame.width, height: frame.height))
    }
    func frameState() async throws -> DeviceFrameState { DeviceFrameState(geometry: DeviceFrameGeometry(sessionID: session, revision: "1", width: frame.width, height: frame.height), isLive: true) }
    func perform(_ action: DeviceAction, frame: FrameGrant) async throws -> SubmissionResult { tappedFrame = frame.frameID; return .submitted }
    func releaseInput() async throws {}
    func disconnect() async -> ReleaseConfirmation { disconnected = true; return .unconfirmed }
    func listApplications() async throws -> [DeviceApplication] { [] }
}
