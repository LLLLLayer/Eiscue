import EiscueAgentKit
import EiscueDeviceKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor
final class DeviceToolSessionTests: XCTestCase {
    func testChatExposesNoDeviceAccessAndObservationCannotMutateDevice() async throws {
        let controller = RecordingDeviceController()
        let client = DeviceClient(controller: controller)
        let chat = DeviceToolSession(client: client, scope: .chat, timeoutSeconds: 30,
                                     log: { _, _ in }, onUnknown: {})
        let observation = DeviceToolSession(client: client, scope: .observe, timeoutSeconds: 30,
                                            log: { _, _ in }, onUnknown: {})

        XCTAssertTrue(chat.tools.isEmpty)
        XCTAssertTrue(observation.tools.allSatisfy { !$0.mayHaveSideEffects })
        XCTAssertNil(observation.tools.first { $0.name == "device_tap" })
        let screenshot = try tool("device_screenshot", in: observation)
        let result = try await screenshot.execute([:])

        XCTAssertTrue(result.content.contains { if case .image = $0 { true } else { false } })
        let counts = await controller.counts()
        XCTAssertEqual(counts.screenshots, 1)
        XCTAssertEqual(counts.taps, 0)
    }

    func testTouchRequiresLatestScreenshotAndConsumesItsFrame() async throws {
        let controller = RecordingDeviceController()
        let session = controlSession(controller)
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)

        _ = try await screenshot.execute([:])
        let firstFrame = try await frameID(from: controller)
        await assertRejected(tap, arguments: tapArguments(frameID: UUID()))
        _ = try await tap.execute(tapArguments(frameID: firstFrame))
        await assertRejected(tap, arguments: tapArguments(frameID: firstFrame))
        var counts = await controller.counts()
        XCTAssertEqual(counts.taps, 1, "A screenshot must authorize at most one touch.")

        _ = try await screenshot.execute([:])
        let secondFrame = try await frameID(from: controller)
        XCTAssertNotEqual(firstFrame, secondFrame)
        await assertRejected(tap, arguments: tapArguments(frameID: firstFrame))
        _ = try await tap.execute(tapArguments(frameID: secondFrame))
        counts = await controller.counts()
        XCTAssertEqual(counts.taps, 2)
    }

    func testAcknowledgmentPersistenceFailureStopsFurtherActionsAndNotifiesHost() async throws {
        let controller = RecordingDeviceController()
        let stopped = expectation(description: "Host stops after losing the action acknowledgment")
        var logKinds: [String] = []
        let session = DeviceToolSession(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                                        log: { kind, _ in
                                            logKinds.append(kind)
                                            if kind == "action.acknowledged" { throw TestLogError.unavailable }
                                        }, onUnknown: { stopped.fulfill() })
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)
        _ = try await screenshot.execute([:])
        let frameID = try await frameID(from: controller)

        do {
            _ = try await tap.execute(tapArguments(frameID: frameID))
            XCTFail("The caller must learn that the durable acknowledgment failed.")
        } catch {
            XCTAssertEqual(error as? TestLogError, .unavailable)
        }
        await fulfillment(of: [stopped], timeout: 1)
        await assertRejected(screenshot, arguments: [:])
        await assertRejected(tap, arguments: tapArguments(frameID: frameID))

        let counts = await controller.counts()
        XCTAssertEqual(counts.taps, 1, "The first action reached the device; retrying it could duplicate its effect.")
        XCTAssertEqual(counts.screenshots, 1, "A failed session cannot obtain a new frame to authorize more actions.")
        XCTAssertEqual(logKinds.filter { $0 == "action.acknowledged" }.count, 1)
    }

    func testUnknownDeliveryStillNotifiesHostWhenItsLogCannotBeSaved() async throws {
        let unknown = DeviceControlError.deliveryUnknown("No receipt from the mock transport")
        let controller = RecordingDeviceController(tapFailure: unknown)
        let stopped = expectation(description: "Host stops even if the unknown-delivery log is lost")
        var attemptedUnknownLog = false
        let session = DeviceToolSession(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                                        log: { kind, _ in
                                            if kind == "action.unknown" {
                                                attemptedUnknownLog = true
                                                throw TestLogError.unavailable
                                            }
                                        }, onUnknown: { stopped.fulfill() })
        let screenshot = try tool("device_screenshot", in: session)
        let tap = try tool("device_tap", in: session)
        _ = try await screenshot.execute([:])
        let frameID = try await frameID(from: controller)

        do {
            _ = try await tap.execute(tapArguments(frameID: frameID))
            XCTFail("Unknown delivery must remain visible to the caller.")
        } catch {
            XCTAssertEqual(error as? DeviceControlError, unknown)
        }
        await fulfillment(of: [stopped], timeout: 1)
        await assertRejected(tap, arguments: tapArguments(frameID: frameID))
        await assertRejected(screenshot, arguments: [:])

        XCTAssertTrue(attemptedUnknownLog)
        let counts = await controller.counts()
        XCTAssertEqual(counts.taps, 1)
        XCTAssertEqual(counts.screenshots, 1)
    }

    private func controlSession(_ controller: RecordingDeviceController) -> DeviceToolSession {
        DeviceToolSession(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                          log: { _, _ in }, onUnknown: {})
    }

    private func tool(_ name: String, in session: DeviceToolSession) throws -> AgentTool {
        try XCTUnwrap(session.tools.first { $0.name == name })
    }

    private func tapArguments(frameID: UUID) -> AgentJSONValue {
        ["frameId": .string(frameID.uuidString), "x": 40, "y": 60]
    }

    private func frameID(from controller: RecordingDeviceController) async throws -> UUID {
        let capturedFrameID = await controller.latestFrameID()
        return try XCTUnwrap(capturedFrameID)
    }

    private func assertRejected(_ tool: AgentTool, arguments: AgentJSONValue,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await tool.execute(arguments)
            XCTFail("An invalid or stopped tool invocation must not reach the device.", file: file, line: line)
        } catch { }
    }
}

private enum TestLogError: Error, Equatable { case unavailable }

/// The mock deliberately does not validate frame IDs: that responsibility is
/// exercised at the App's tool boundary, independently of a real transport.
private actor RecordingDeviceController: DeviceController {
    private let tapFailure: DeviceControlError?
    private var screenshotCount = 0
    private var tapCount = 0
    private var frameID: UUID?

    init(tapFailure: DeviceControlError? = nil) { self.tapFailure = tapFailure }

    func status() async -> DeviceStatus { .ready(capabilities: [.screenshot, .tap]) }

    func captureScreenshot() async throws -> DeviceScreenshot {
        screenshotCount += 1
        let frame = DeviceScreenshot(width: 390, height: 844, mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        frameID = frame.frameID
        return frame
    }

    func tap(at point: DevicePoint, frameID: UUID) async throws {
        tapCount += 1
        if let tapFailure { throw tapFailure }
    }

    func latestFrameID() -> UUID? { frameID }
    func counts() -> (screenshots: Int, taps: Int) { (screenshotCount, tapCount) }
}
