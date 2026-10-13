import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import EiscueDeviceKit

@Suite struct ScreenBroadcastStoreTests {
    @Test func anIdenticalPublicationKeepsADelayedObservationCurrent() async throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.store.beginSession()
        try fixture.publish(session)
        let observed = try fixture.store.readCurrentFrame()
        try await Task.sleep(for: .seconds(ScreenBroadcastStore.maximumFrameAge + 0.15))
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.readCurrentFrame() }

        try fixture.publish(session)
        let current = try fixture.store.readCurrentFrame()
        #expect(current.frame.frameID == observed.frame.frameID)
        #expect(current.frame.capturedAt > observed.frame.capturedAt)
        #expect(current.frame.capturedUptime > observed.frame.capturedUptime + ScreenBroadcastStore.maximumFrameAge)
        #expect(BluetoothFrameAuthority.permits(decisionIssuedUptime: observed.confirmedUptime,
            currentConfirmedUptime: current.confirmedUptime, now: ProcessInfo.processInfo.systemUptime))
        // Identity reuse alone cannot extend the broadcast's liveness window.
        #expect(!BluetoothFrameAuthority.permits(decisionIssuedUptime: observed.confirmedUptime,
            currentConfirmedUptime: current.confirmedUptime,
            now: current.confirmedUptime + ScreenBroadcastStore.maximumFrameAge + 0.01))
    }

    @Test func returningToEarlierPixelsCannotReviveTheirIdentity() throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.store.beginSession()
        let original = try fixture.publish(session)
        let changed = try fixture.store.publish(jpegData: BroadcastStoreFixture.makeJPEG(gray: 0.8),
            width: 8, height: 4, orientation: .right, sessionID: session)
        let returned = try fixture.publish(session)
        #expect(changed != original)
        #expect(returned != original && returned != changed)
        #expect(try fixture.publish(session) == returned)
    }

    @Test func changedScreenContentDoesNotRevokeARecentModelDecision() throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.store.beginSession()
        let original = try fixture.publish(session)
        let changed = try fixture.store.publish(jpegData: BroadcastStoreFixture.makeJPEG(gray: 0.8),
            width: 8, height: 4, orientation: .right, sessionID: session)
        #expect(changed != original)
        let current = try fixture.store.readCurrentFrame()
        let now = ProcessInfo.processInfo.systemUptime
        #expect(BluetoothFrameAuthority.permits(decisionIssuedUptime: now - 5,
            currentConfirmedUptime: current.confirmedUptime, now: now))
    }

    @Test func geometryAndSessionChangesRequireNewIdentities() throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.store.beginSession()
        let original = try fixture.publish(session)
        let rotated = try fixture.store.publish(jpegData: fixture.jpeg,
            width: 8, height: 4, orientation: .left, sessionID: session)
        let resized = try fixture.store.publish(jpegData: fixture.jpeg,
            width: 4, height: 8, orientation: .left, sessionID: session)
        let returned = try fixture.publish(session)
        #expect(Set([original, rotated, resized, returned]).count == 4)
        let replacement = try fixture.store.beginSession()
        let reconnected = try fixture.publish(replacement)
        #expect(reconnected != returned)
        #expect(throws: ScreenBroadcastError.self) { try fixture.publish(session) }
    }

    @Test func pauseResumeAndFinishRequireANewFrame() throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.store.state().phase == .idle)
        let session = try fixture.store.beginSession()
        #expect(fixture.store.state().phase == .starting)
        try fixture.publish(session)
        let first = try fixture.store.observation()
        #expect(first.sessionID == session)
        #expect(first.screenshot.width == 8 && first.screenshot.height == 4)
        #expect(first.orientation == .right && first.screenshot.data == fixture.jpeg)

        try fixture.store.setPaused(true, sessionID: session)
        #expect(fixture.store.state().phase == .paused)
        #expect(fixture.store.state().frameID == nil)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.snapshot() }
        try fixture.store.setPaused(false, sessionID: session)
        #expect(fixture.store.state().phase == .starting)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.snapshot() }
        try fixture.publish(session)
        #expect(try fixture.store.snapshot().frameID != first.screenshot.frameID)
        try fixture.store.finishSession(sessionID: session)
        #expect(fixture.store.state().phase == .ended)
        #expect(fixture.store.state().frameID == nil)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.snapshot() }
    }

    @Test func stopIsImmediateAndCannotAffectANewerSession() throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        let oldSession = try fixture.store.beginSession()
        try fixture.publish(oldSession)
        try fixture.store.requestStop()
        #expect(fixture.store.state().phase == .ended)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.snapshot() }
        #expect(throws: ScreenBroadcastError.self) { try fixture.publish(oldSession) }

        let newSession = try fixture.store.beginSession()
        #expect(try !fixture.store.stopRequested(sessionID: newSession))
        try fixture.publish(newSession)
        let currentFrame = try fixture.store.snapshot()
        #expect(throws: ScreenBroadcastError.self) { try fixture.publish(oldSession) }
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.finishSession(sessionID: oldSession) }
        #expect(try fixture.store.snapshot() == currentFrame)
        #expect(fixture.store.state().sessionID == newSession)
    }

    @Test func aSilentOrTerminatedExtensionCannotLeaveAnActionableFrame() async throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.store.beginSession()
        try fixture.publish(session)
        #expect(fixture.store.state().isActive)
        // Use the real freshness window so this covers both monotonic and wall
        // clocks without exposing a production-only testing API.
        try await Task.sleep(for: .seconds(ScreenBroadcastStore.maximumFrameAge + 0.15))
        #expect(fixture.store.state().phase == .stale)
        #expect(!fixture.store.state().isActive)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.snapshot() }
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.readCurrentFrame() }
    }

    @Test func aLiveHeartbeatKeepsAnUnchangedScreenCurrent() async throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.store.beginSession()
        let frameID = try fixture.publish(session)
        try await Task.sleep(for: .seconds(ScreenBroadcastStore.maximumFrameAge + 0.15))
        #expect(fixture.store.state().phase == .stale)

        try fixture.store.heartbeat(sessionID: session, frameID: frameID, newerFramePending: false)
        #expect(fixture.store.state().isActive)
        let reading = try fixture.store.readCurrentFrame()
        #expect(reading.frame.frameID == frameID)
        #expect(reading.confirmedUptime > reading.frame.capturedUptime + ScreenBroadcastStore.maximumFrameAge)
        // The legacy strict reader still refuses an old capture.
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.readFrame() }
    }

    @Test func aHeartbeatCannotConfirmAFrameThatIsNoLongerCurrent() async throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.store.beginSession()
        let frameID = try fixture.publish(session)
        try await Task.sleep(for: .seconds(ScreenBroadcastStore.maximumFrameAge + 0.15))

        // A newer buffer is waiting: the extension is alive but this frame is old.
        try fixture.store.heartbeat(sessionID: session, frameID: frameID, newerFramePending: true)
        #expect(fixture.store.state().isActive)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.readCurrentFrame() }
        // A heartbeat naming another frame or another session confirms nothing.
        try fixture.store.heartbeat(sessionID: session, frameID: UUID(), newerFramePending: false)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.readCurrentFrame() }
        try fixture.store.heartbeat(sessionID: UUID(), frameID: frameID, newerFramePending: false)
        #expect(fixture.store.state().phase == .stale)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.readCurrentFrame() }
    }

    @Test func pausingOrStoppingEndsHeartbeatConfirmation() throws {
        let fixture = try BroadcastStoreFixture()
        defer { fixture.cleanUp() }
        let session = try fixture.store.beginSession()
        let frameID = try fixture.publish(session)
        try fixture.store.heartbeat(sessionID: session, frameID: frameID, newerFramePending: false)
        try fixture.store.setPaused(true, sessionID: session)
        #expect(fixture.store.state().phase == .paused)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.readCurrentFrame() }

        try fixture.store.setPaused(false, sessionID: session)
        let resumed = try fixture.publish(session)
        try fixture.store.heartbeat(sessionID: session, frameID: resumed, newerFramePending: false)
        try fixture.store.requestStop()
        #expect(fixture.store.state().phase == .ended)
        #expect(throws: ScreenBroadcastError.self) { try fixture.store.readCurrentFrame() }
    }
}

private struct BroadcastStoreFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: ScreenBroadcastStore
    let jpeg: Data

    init() throws {
        store = ScreenBroadcastStore(containerURL: directory)
        jpeg = try Self.makeJPEG(gray: 0.5)
    }

    static func makeJPEG(gray: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @discardableResult
    func publish(_ session: UUID) throws -> UUID {
        try store.publish(jpegData: jpeg, width: 8, height: 4, orientation: .right, sessionID: session)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
