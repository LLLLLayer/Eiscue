import CEiscueAutomation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PhoneAgentNCM

@Suite struct XCTestSessionGuardsTests {
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
