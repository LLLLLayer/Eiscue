import EiscueDeviceCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DeviceObservationImage {
    static let maximumDimension = 1600

    /// Bound the model's image ourselves, so coordinates refer to the exact
    /// bytes and dimensions we send rather than a provider's larger-image view.
    static func prepare(_ frame: DeviceScreenshot) throws -> DeviceScreenshot {
        guard frame.width > 0, frame.height > 0, !frame.data.isEmpty else { throw DeviceTaskError.arguments }
        guard max(frame.width, frame.height) > maximumDimension else { return frame }
        guard let source = CGImageSourceCreateWithData(frame.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == frame.width,
              properties[kCGImagePropertyPixelHeight] as? Int == frame.height,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width > 0, image.height > 0 else { throw DeviceTaskError.arguments }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw DeviceTaskError.arguments
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DeviceTaskError.arguments }
        // Resizing must never renew an observation or extend its input lifetime.
        return DeviceScreenshot(frameID: frame.frameID, capturedAt: frame.capturedAt,
                                width: image.width, height: image.height, mimeType: "image/png", data: data as Data)
    }
}

struct DeviceObservationCoordinates {
    let id: UUID
    let width: Int
    let height: Int
    let nativeWidth: Int
    let nativeHeight: Int

    func nativePoint(_ point: DevicePoint) -> DevicePoint {
        DevicePoint(x: point.x * Double(nativeWidth) / Double(width),
                    y: point.y * Double(nativeHeight) / Double(height))
    }
}
