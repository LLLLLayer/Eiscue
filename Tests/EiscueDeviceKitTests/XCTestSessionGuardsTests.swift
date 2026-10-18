import CEiscueAutomation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PhoneAgentNCM

@Suite struct XCTestSessionGuardsTests {
    @Test @MainActor func canceledOwnedDeliveryRetainsTheExactReceiptAndLongTextBudget() async throws {
        let delivery = NCMOwnedDelivery(), began = ContinuousClock.now
        try delivery.receipt.begin(token: 7, requestID: 19,
                                   timeout: NCMXCTestDelivery.textTimeout(byteCount: 8192), now: began)
        let polled = AsyncStream<Void>.makeStream()
        let operation = Task { @MainActor in
            try await delivery.wait(token: 7, request: 19, pause: {
                polled.continuation.yield()
                try await Task.sleep(for: .seconds(60))
            }, poll: { deliveryState(request: 19, phase: EISCUE_AUTOMATION_DELIVERING) })
        }
        var iterator = polled.stream.makeAsyncIterator()
        _ = await iterator.next(); operation.cancel()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        polled.continuation.finish()
        #expect(delivery.receipt.pending?.token == 7 && delivery.receipt.pending?.requestID == 19)
        #expect(delivery.receipt.stopDeadline(now: began.advanced(by: .seconds(5))) == began.advanced(by: .seconds(152)))
        #expect(delivery.receipt.releaseTimeout(now: began.advanced(by: .seconds(5))) == .seconds(152))
        #expect(throws: NativeBackendError.busy) {
            try delivery.receipt.begin(token: 7, requestID: 20, timeout: .seconds(15))
        }
    }

    @Test @MainActor func ownedReceiptCanArriveAfterThreeSecondsWithoutLosingItsLease() async throws {
        let delivery = NCMOwnedDelivery(), clock = ReceiptClock()
        try delivery.receipt.begin(token: 7, requestID: 19, timeout: .seconds(16), now: clock.now)
        var polls = 0
        _ = try await delivery.wait(token: 7, request: 19, now: { clock.now }, pause: {
            clock.now = clock.now.advanced(by: .seconds(1))
        }, poll: {
            polls += 1
            return deliveryState(request: 19, phase: polls < 5 ? EISCUE_AUTOMATION_DELIVERING : EISCUE_AUTOMATION_READY)
        })
        #expect(polls == 5 && delivery.receipt.pending == nil)
    }

    @Test @MainActor func failedOrExpiredOwnedDeliveryKeepsCleanupAuthorityWithoutGrantingSuccess() async throws {
        let delivery = NCMOwnedDelivery(), clock = ReceiptClock()
        try delivery.receipt.begin(token: 7, requestID: 19, timeout: .seconds(15), now: clock.now)
        await #expect(throws: NativeBackendError.automationDeliveryUnknown(cause: 9)) {
            _ = try await delivery.wait(token: 7, request: 19, poll: {
                deliveryState(request: 19, phase: EISCUE_AUTOMATION_FAILED, error: 9)
            })
        }
        #expect(delivery.receipt.pending?.requestID == 19)
        await #expect(throws: NativeBackendError.automationDeliveryUnknown(cause: 14)) {
            _ = try await delivery.wait(token: 7, request: 19, now: { clock.now }, pause: {
                clock.now = clock.now.advanced(by: .seconds(15))
            }, poll: { deliveryState(request: 19, phase: EISCUE_AUTOMATION_DELIVERING) })
        }
        #expect(delivery.receipt.pending?.requestID == 19)
        #expect(delivery.receipt.releaseTimeout(now: clock.now) == .seconds(5))
    }

    @Test @MainActor func nativeCleanupDrainsOnlyTheOriginalIDBeforeAcceptingStop() async throws {
        let receipt = NCMSubmittedRequest(), began = ContinuousClock.now
        try receipt.begin(token: 7, requestID: 19, timeout: .seconds(120), now: began)
        #expect(throws: NativeBackendError.busy) {
            try receipt.begin(token: 7, requestID: 20, timeout: .seconds(120))
        }
        var order: [UInt64] = []
        try await receipt.drain { pending in
            #expect(pending.token == 7 && pending.requestID == 19)
            #expect(pending.deadline == began.advanced(by: .seconds(120)))
            order.append(pending.requestID)
            // A complete failure receipt settles the old queue slot, without
            // changing the work's already-unknown outcome to success.
            try receipt.received(token: pending.token, requestID: pending.requestID, kind: 3)
        }
        try receipt.begin(token: 7, requestID: 20, timeout: .seconds(120))
        order.append(20)
        try receipt.received(token: 7, requestID: 20, kind: 2)
        #expect(order == [19, 20] && receipt.pending == nil)
    }

    @Test @MainActor func mismatchedOrUnconsumedReceiptsCannotAuthorizeStop() async throws {
        let receipt = NCMSubmittedRequest()
        try receipt.begin(token: 7, requestID: 19, timeout: .seconds(120))
        for (token, id, kind): (UInt64, UInt64, UInt32) in [(8, 19, 2), (7, 20, 2), (7, 19, 1)] {
            #expect(throws: NativeBackendError.malformedEvent) { try receipt.received(token: token, requestID: id, kind: kind) }
        }
        await #expect(throws: NativeBackendError.malformedEvent) { try await receipt.drain { _ in } }
        #expect(receipt.pending?.requestID == 19)
        await #expect(throws: NativeBackendError.closed) {
            try await receipt.drain { _ in throw NativeBackendError.closed }
        }
        #expect(receipt.pending?.requestID == 19)
    }

    @Test func textReceiptDeadlineIncludesBoundedTypingTime() throws {
        for (bytes, seconds) in [(1, 16), (59, 16), (60, 16), (61, 17), (120, 17), (121, 18), (8192, 152)] {
            #expect(try NCMXCTestDelivery.textTimeout(byteCount: bytes) == .seconds(seconds))
        }
        let unicode = "你好，Eiscue 🧊 e\u{0301} 👨‍👩‍👧‍👦"
        #expect(unicode.utf8.count > unicode.utf16.count)
        #expect(try NCMXCTestDelivery.textTimeout(byteCount: unicode.utf8.count) >=
                .seconds(15 + (unicode.utf16.count + 59) / 60))
    }

    @Test func textReceiptDeadlineRejectsInvalidLengthsBeforeArithmetic() {
        for bytes in [Int.min, -1, 0, 8193, Int.max] {
            #expect(throws: NativeBackendError.malformedEvent) {
                try NCMXCTestDelivery.textTimeout(byteCount: bytes)
            }
        }
    }

    @Test func authorizationMustAffirmTheExactOwnedProcessAndSession() throws {
        let uuid = UUID()
        func receipt(_ authorized: Any, processID: Int32 = 42, sessionID: UUID? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["authorized": authorized, "processID": processID,
                                                       "sessionIdentifier": (sessionID ?? uuid).uuidString])
        }
        try NCMXCTestAuthorization.validate(receipt(true), sessionID: uuid, processID: 42)
        for value: Any in [false, 1, "true", NSNull()] {
            #expect(throws: NativeBackendError.malformedEvent) {
                try NCMXCTestAuthorization.validate(receipt(value), sessionID: uuid, processID: 42)
            }
        }
        #expect(throws: NativeBackendError.malformedEvent) {
            try NCMXCTestAuthorization.validate(receipt(true, processID: 43), sessionID: uuid, processID: 42)
        }
        #expect(throws: NativeBackendError.malformedEvent) {
            try NCMXCTestAuthorization.validate(receipt(true, sessionID: UUID()), sessionID: uuid, processID: 42)
        }
        #expect(throws: NativeBackendError.malformedEvent) {
            try NCMXCTestAuthorization.validate(Data("{\"authorized\":true}".utf8), sessionID: uuid, processID: 42)
        }
    }

    @Test func pendingGeometryAndInvalidSystemValuesCannotGrantReadiness() throws {
        var state = validState()
        for phase in [EISCUE_AUTOMATION_PREPARING, EISCUE_AUTOMATION_QUERYING, EISCUE_AUTOMATION_DELIVERING,
                      EISCUE_AUTOMATION_FAILED, EISCUE_AUTOMATION_STOPPED] {
            state.phase = UInt32(phase)
            #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
        }
        state = validState(); state.scale = .nan
        #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
        state = validState(); state.bounds_width = .infinity
        #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
        state = validState(); state.orientation = 0
        #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
        state = validState(); state.revision = 0
        #expect(throws: NativeBackendError.self) { try NCMXCTestScreenState(state) }
    }

    @Test func pixelsMustMatchSystemScaleBoundsAndInterfaceOrientation() throws {
        let portrait = try NCMXCTestScreenState(validState())
        _ = try NCMXCTestLayout(width: 1179, height: 2556, screen: portrait)
        #expect(throws: NativeBackendError.coordinateSpaceChanged) {
            try NCMXCTestLayout(width: 1080, height: 1920, screen: portrait)
        }
        #expect(throws: NativeBackendError.coordinateSpaceChanged) {
            try NCMXCTestLayout(width: 2556, height: 1179, screen: portrait)
        }
        var state = validState(); state.orientation = 3; state.revision += 1
        let landscape = try NCMXCTestScreenState(state)
        _ = try NCMXCTestLayout(width: 2556, height: 1179, screen: landscape)
        #expect(throws: NativeBackendError.coordinateSpaceChanged) {
            try NCMXCTestLayout(width: 1179, height: 2556, screen: landscape)
        }
    }

    @Test func returningToTheSameSizeDoesNotReuseTheFormerGeometry() throws {
        var tracker = NCMXCTestGeometryTracker()
        let state = validState()
        let layout = try NCMXCTestLayout(width: 1179, height: 2556, screen: NCMXCTestScreenState(state))
        let original = tracker.update(lease: 1, layout: layout)
        #expect(tracker.update(lease: 1, layout: layout) == original)
        var rotated = state; rotated.orientation = 2; rotated.revision += 1
        let rotatedLayout = try NCMXCTestLayout(width: 1179, height: 2556, screen: NCMXCTestScreenState(rotated))
        #expect(tracker.update(lease: 1, layout: rotatedLayout).id != original.id)
        #expect(tracker.update(lease: 1, layout: layout).id != original.id)
        #expect(tracker.update(lease: 2, layout: layout).id != original.id)
        tracker.reset()
        #expect(tracker.current == nil)
        #expect(tracker.update(lease: 1, layout: layout).id != original.id)
    }

    @Test(arguments: [3, 6, 8]) func screenshotOrientationRotatesPixelsExactlyOnce(_ orientation: Int) throws {
        let encoded = try quadrantImage(orientation: orientation)
        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int == orientation)
        let upright = try NCMXCTestImage.uprightPNG(encoded)
        let pixels = try decodedQuadrants(upright)
        #expect(pixels.width == (orientation == 3 ? 12 : 20))
        #expect(pixels.height == (orientation == 3 ? 20 : 12))
        #expect(pixels.orientation == 1)
        let expected = switch orientation {
        case 3: [Self.yellow, Self.blue, Self.green, Self.red]
        case 6: [Self.blue, Self.red, Self.yellow, Self.green]
        default: [Self.green, Self.yellow, Self.red, Self.blue]
        }
        #expect(pixels.corners == expected)
        #expect(try NCMXCTestImage.uprightPNG(upright) == upright)
    }

    @Test func uprightScreenshotPreservesOriginalBytesAndPixels() throws {
        for orientation: Int? in [1, nil] {
            let encoded = try quadrantImage(orientation: orientation)
            #expect(try NCMXCTestImage.uprightPNG(encoded) == encoded)
            let pixels = try decodedQuadrants(encoded)
            #expect(pixels.width == 12 && pixels.height == 20 && pixels.orientation == 1)
            #expect(pixels.corners == [Self.red, Self.green, Self.blue, Self.yellow])
        }
    }

    @Test @MainActor func screenshotConversionLeavesMainActorAndPreservesRotatedPixels() async throws {
        let encoded = try quadrantImage(orientation: 6)
        let upright = try await NCMXCTestImage.uprightPNGOffMain(encoded) { data in
            #expect(!Thread.isMainThread)
            return try NCMXCTestImage.uprightPNG(data)
        }
        let pixels = try decodedQuadrants(upright)
        #expect(pixels.width == 20 && pixels.height == 12 && pixels.orientation == 1)
        #expect(pixels.corners == [Self.blue, Self.red, Self.yellow, Self.green])
    }

    @Test @MainActor func cancellationDuringPNGConversionCannotPublishItsLateResult() async throws {
        let encoded = try quadrantImage(orientation: 6)
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let operation = Task {
            try await NCMXCTestImage.uprightPNGOffMain(encoded) { data in
                started.continuation.yield()
                release.wait()
                return try NCMXCTestImage.uprightPNG(data)
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        operation.cancel(); release.signal()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        started.continuation.finish()
    }

    @Test(arguments: [2, 4, 5, 7]) func mirroredScreenshotIsRejected(_ orientation: Int) throws {
        let encoded = try quadrantImage(orientation: orientation)
        let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int == orientation)
        #expect(throws: NativeBackendError.malformedEvent) { try NCMXCTestImage.uprightPNG(encoded) }
    }

    @Test func invalidOrNonPNGScreenshotIsRejected() throws {
        let png = try quadrantImage(orientation: 6)
        let jpeg = try quadrantImage(orientation: 6, type: "public.jpeg")
        for bytes in [Data(), Data("not an image".utf8), Data(png.prefix(32)), jpeg] {
            #expect(throws: NativeBackendError.malformedEvent) { try NCMXCTestImage.uprightPNG(bytes) }
        }
    }

    @Test func unsupportedScreenshotDimensionsAreRejectedBeforeRotation() throws {
        for (width, height) in [(16_385, 2), (2, 16_385), (1, 20)] {
            let encoded = try quadrantImage(orientation: 6, width: width, height: height)
            #expect(throws: NativeBackendError.malformedEvent) { try NCMXCTestImage.uprightPNG(encoded) }
        }
    }

    private static let red: [UInt8] = [255, 0, 0, 255]
    private static let green: [UInt8] = [0, 255, 0, 255]
    private static let blue: [UInt8] = [0, 0, 255, 255]
    private static let yellow: [UInt8] = [255, 255, 0, 255]

    private func quadrantImage(orientation: Int?, type: String = "public.png", width: Int = 12, height: Int = 20) throws -> Data {
        let colors = [Self.red, Self.green, Self.blue, Self.yellow]
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width { bytes.append(contentsOf: colors[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]) }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: space,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func decodedQuadrants(_ data: Data) throws -> (width: Int, height: Int, orientation: Int, corners: [[UInt8]]) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let points = [(image.width / 4, image.height / 4), (image.width * 3 / 4, image.height / 4),
                      (image.width / 4, image.height * 3 / 4), (image.width * 3 / 4, image.height * 3 / 4)]
        let colors = points.map { x, y in Array(UnsafeBufferPointer(start: pixels + (y * image.width + x) * 4, count: 4)) }
        return (image.width, image.height, properties[kCGImagePropertyOrientation] as? Int ?? 1, colors)
    }

    private func validState() -> eiscue_automation_state {
        var state = eiscue_automation_state()
        state.phase = UInt32(EISCUE_AUTOMATION_READY); state.revision = 1; state.display_id = 1
        state.orientation = 1; state.scale = 3; state.bounds_width = 393; state.bounds_height = 852
        return state
    }
}

@MainActor private final class ReceiptClock {
    var now = ContinuousClock.now
}

private func deliveryState(request: UInt64, phase: Int, error: UInt32 = 0) -> eiscue_automation_state {
    var state = eiscue_automation_state()
    state.request_id = request; state.phase = UInt32(phase); state.error = error
    return state
}
