import EiscueAgentKit
import EiscueDeviceKit
import ImageIO
import UIKit
import XCTest
@testable import Eiscue

@MainActor
final class DeviceObservationImageTests: XCTestCase {
    func testLargePortraitAndLandscapeImagesEncodeDeclaredDimensionsWithoutRenewingFrame() throws {
        for (width, height) in [(1179, 2556), (2556, 1179)] {
            let original = try screenshot(width: width, height: height)
            let image = try DeviceObservationImage.prepare(original)
            let encoded = try dimensions(image.data)
            XCTAssertEqual(max(encoded.width, encoded.height), 1600)
            XCTAssertEqual(encoded.width, image.width)
            XCTAssertEqual(encoded.height, image.height)
            XCTAssertEqual(image.mimeType, "image/png")
            XCTAssertEqual(image.frameID, original.frameID)
            XCTAssertEqual(image.capturedAt, original.capturedAt)
            let scale = 1600.0 / Double(max(width, height))
            XCTAssertEqual(Double(image.width), Double(width) * scale, accuracy: 1)
            XCTAssertEqual(Double(image.height), Double(height) * scale, accuracy: 1)
        }
    }

    func testSmallAndBoundaryImagesKeepOriginalBytesAndMetadata() throws {
        for (width, height) in [(390, 844), (1600, 800)] {
            let original = try screenshot(width: width, height: height)
            XCTAssertEqual(try DeviceObservationImage.prepare(original), original)
        }
    }

    func testMismatchedLargeImageMetadataCannotAuthorizeCoordinates() throws {
        let original = try screenshot(width: 800, height: 1600)
        let misleading = DeviceScreenshot(width: 1600, height: 3200, mimeType: original.mimeType, data: original.data)
        XCTAssertThrowsError(try DeviceObservationImage.prepare(misleading)) {
            guard case .arguments = $0 as? DeviceTaskError else { return XCTFail("Expected a geometry mismatch rejection.") }
        }
    }

    func testToolsMapModelPixelsToNativePixelsUsingTheMatchingFrameGeometry() async throws {
        let portrait = try screenshot(width: 1600, height: 3200)
        let landscape = try screenshot(width: 3200, height: 1600)
        let last = try screenshot(width: 390, height: 844)
        let controller = ObservationImageController(frames: [portrait, landscape, last])
        let session = DeviceToolSession(client: DeviceClient(controller: controller), scope: .control,
                                        timeoutSeconds: 30, log: { _, _ in }, onUnknown: {})
        let observe = try XCTUnwrap(session.tools.first { $0.name == "device_screenshot" })
        let tap = try XCTUnwrap(session.tools.first { $0.name == "device_tap" })
        let swipe = try XCTUnwrap(session.tools.first { $0.name == "device_swipe" })
        let first = try await observe.execute([:])
        try assertImageResult(first, width: 800, height: 1600, frameID: portrait.frameID)
        let second = try await tap.execute([
            "frameId": .string(portrait.frameID.uuidString), "x": 200, "y": 400
        ])
        try assertImageResult(second, width: 1600, height: 800, frameID: landscape.frameID)
        let third = try await swipe.execute([
            "frameId": .string(landscape.frameID.uuidString), "fromX": 100, "fromY": 200,
            "toX": 1400, "toY": 700, "duration": 0.5
        ])
        try assertImageResult(third, width: 390, height: 844, frameID: last.frameID)

        let recorded = await controller.snapshot()
        XCTAssertEqual(recorded.captures, 3, "Each input includes exactly one fresh verification.")
        XCTAssertEqual(recorded.taps.count, 1)
        let recordedTap = try XCTUnwrap(recorded.taps.first)
        XCTAssertEqual(recordedTap.point, DevicePoint(x: 400, y: 800))
        XCTAssertEqual(recordedTap.frameID, portrait.frameID)
        XCTAssertEqual(recorded.swipes.count, 1)
        let recordedSwipe = try XCTUnwrap(recorded.swipes.first)
        XCTAssertEqual(recordedSwipe.from, DevicePoint(x: 200, y: 400))
        XCTAssertEqual(recordedSwipe.to, DevicePoint(x: 2800, y: 1400))
        XCTAssertEqual(recordedSwipe.duration, .milliseconds(500))
        XCTAssertEqual(recordedSwipe.frameID, landscape.frameID)
    }

    func testCoordinatesInsideNativeImageButOutsideModelImageNeverDispatch() async throws {
        let original = try screenshot(width: 1600, height: 3200)
        let actions: [DeviceAction] = [
            .tap(.init(x: 800, y: 10)), .tap(.init(x: 10, y: 1600)),
            .swipe(from: .init(x: 800, y: 10), to: .init(x: 20, y: 20), duration: 0.5),
            .swipe(from: .init(x: 10, y: 10), to: .init(x: 20, y: 1600), duration: 0.5)
        ]
        for action in actions {
            let controller = ObservationImageController(frames: [original])
            let runner = makeRunner(controller)
            let frame = try observation(await runner.step(.observe))
            do {
                _ = try await runner.step(.action(action, frameID: frame.frameID))
                XCTFail("Model coordinates must be checked before native scaling.")
            } catch {
                guard case .arguments = error as? DeviceTaskError else { return XCTFail("Expected model-image bounds rejection: \(error)") }
            }
            let recorded = await controller.snapshot()
            XCTAssertTrue(recorded.taps.isEmpty)
            XCTAssertTrue(recorded.swipes.isEmpty)
            XCTAssertEqual(recorded.captures, 1)
        }
    }

    func testNewObservationInvalidatesThePreviousScaledCoordinateSpace() async throws {
        let portrait = try screenshot(width: 1600, height: 3200)
        let landscape = try screenshot(width: 3200, height: 1600)
        let controller = ObservationImageController(frames: [portrait, landscape])
        let runner = makeRunner(controller)
        _ = try await runner.step(.observe)
        let current = try observation(await runner.step(.observe))
        XCTAssertEqual(current.frameID, landscape.frameID)
        do {
            _ = try await runner.step(.action(.tap(.init(x: 100, y: 100)), frameID: portrait.frameID))
            XCTFail("An old image must not use the newest image's coordinate mapping.")
        } catch {
            guard case .frame = error as? DeviceTaskError else { return XCTFail("Expected stale frame rejection.") }
        }
        let recorded = await controller.snapshot()
        XCTAssertTrue(recorded.taps.isEmpty)
        XCTAssertEqual(recorded.captures, 2)
    }

    func testFailedImagePreparationAfterInputPausesAndReleasesWithoutRetry() async throws {
        let original = try screenshot(width: 1600, height: 3200)
        let corrupt = DeviceScreenshot(width: 1600, height: 3200, mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let controller = ObservationImageController(frames: [original, corrupt])
        var held = false
        var presentation: [String] = []
        let session = DeviceToolSession(client: DeviceClient(controller: controller), scope: .control,
                                        timeoutSeconds: 30, log: { _, _ in }, onUnknown: {},
                                        onObservationWillCapture: { held = true; presentation.append("hold") },
                                        onActionFinished: { held = false; presentation.append("release") })
        let observe = try XCTUnwrap(session.tools.first { $0.name == "device_screenshot" })
        let tap = try XCTUnwrap(session.tools.first { $0.name == "device_tap" })
        _ = try await observe.execute([:])
        XCTAssertTrue(held)
        let input: AgentJSONValue = ["frameId": .string(original.frameID.uuidString), "x": 200, "y": 400]
        do {
            _ = try await tap.execute(input)
            XCTFail("A submitted input without a usable verification image must pause.")
        } catch {
            guard case .toolExecutionPaused = error as? AgentError else { return XCTFail("Expected a terminating pause: \(error)") }
        }
        XCTAssertEqual(session.phase, .paused)
        XCTAssertEqual(session.pauseReason, .verificationUnavailable)
        XCTAssertFalse(session.hasUnknownOutcome, "The input was acknowledged; only its verification image failed.")
        XCTAssertFalse(held)
        XCTAssertEqual(presentation, ["hold", "release", "hold", "release"])
        do { _ = try await tap.execute(input); XCTFail("The submitted input must not be retried.") }
        catch { guard case .stopped = error as? DeviceTaskError else { return XCTFail("Expected closed execution gate.") } }
        do { _ = try await observe.execute([:]); XCTFail("Continuation requires a new run.") }
        catch { guard case .stopped = error as? DeviceTaskError else { return XCTFail("Expected closed observation gate.") } }
        let recorded = await controller.snapshot()
        XCTAssertEqual(recorded.taps.count, 1)
        XCTAssertTrue(recorded.swipes.isEmpty)
        XCTAssertEqual(recorded.captures, 2)
    }

    private func screenshot(width: Int, height: Int) throws -> DeviceScreenshot {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: width, height: height)
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        let encoded = try dimensions(data)
        XCTAssertEqual(encoded.width, width); XCTAssertEqual(encoded.height, height)
        return DeviceScreenshot(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), width: width, height: height,
                                mimeType: "image/png", data: data)
    }

    private func dimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    private func assertImageResult(_ result: AgentToolResult, width: Int, height: Int, frameID: UUID,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(result.content.compactMap { content -> Data? in
            if case .image(let data, let mimeType) = content {
                XCTAssertEqual(mimeType, "image/png", file: file, line: line)
                return data
            }
            return nil
        }.first, file: file, line: line)
        let encoded = try dimensions(data)
        XCTAssertEqual(encoded.width, width, file: file, line: line)
        XCTAssertEqual(encoded.height, height, file: file, line: line)
        XCTAssertTrue(result.text.contains("frameId=\(frameID.uuidString); width=\(width); height=\(height);"), file: file, line: line)
        XCTAssertFalse(result.isError, file: file, line: line)
    }

    private func makeRunner(_ controller: ObservationImageController) -> DeviceTaskRunner {
        DeviceTaskRunner(client: DeviceClient(controller: controller), scope: .control, timeoutSeconds: 30,
                         log: { _, _ in }, onUnknown: {})
    }

    private func observation(_ result: DeviceStepResult) throws -> DeviceScreenshot {
        switch result {
        case .observation(let value), .action(let value): return value.screenshot
        case .applications: throw ObservationImageFixtureError.unexpectedResult
        }
    }
}

private enum ObservationImageFixtureError: Error { case unexpectedResult }

private actor ObservationImageController: DeviceController {
    struct Tap: Sendable { let point: DevicePoint; let frameID: UUID }
    struct Swipe: Sendable { let from: DevicePoint; let to: DevicePoint; let duration: Duration; let frameID: UUID }
    private var frames: [DeviceScreenshot]
    private var captures = 0
    private var taps: [Tap] = []
    private var swipes: [Swipe] = []

    init(frames: [DeviceScreenshot]) { self.frames = frames }
    func status() async -> DeviceStatus { .ready(capabilities: [.screenshot, .tap, .swipe]) }
    func captureScreenshot() async throws -> DeviceScreenshot {
        captures += 1
        guard !frames.isEmpty else { throw DeviceControlError.notConnected }
        return frames.removeFirst()
    }
    func tap(at point: DevicePoint, frameID: UUID) async throws { taps.append(Tap(point: point, frameID: frameID)) }
    func swipe(from: DevicePoint, to: DevicePoint, duration: Duration, frameID: UUID) async throws {
        swipes.append(Swipe(from: from, to: to, duration: duration, frameID: frameID))
    }
    func snapshot() -> (captures: Int, taps: [Tap], swipes: [Swipe]) { (captures, taps, swipes) }
}
