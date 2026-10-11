import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import EiscueDeviceKit

@Suite struct ScreenBroadcastStoreTests {
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
    }
}

private struct BroadcastStoreFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: ScreenBroadcastStore
    let jpeg: Data

    init() throws {
        store = ScreenBroadcastStore(containerURL: directory)
        let context = try #require(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        jpeg = data as Data
    }

    func publish(_ session: UUID) throws {
        try store.publish(jpegData: jpeg, width: 8, height: 4, orientation: .right, sessionID: session)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
