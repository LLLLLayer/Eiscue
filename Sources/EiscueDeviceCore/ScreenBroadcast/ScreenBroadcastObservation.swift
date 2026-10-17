import Foundation

public struct ScreenBroadcastObservation: Sendable, Equatable {
    public let screenshot: DeviceScreenshot
    public let sessionID: UUID
    public let orientation: ScreenBroadcastOrientation
}

public extension ScreenBroadcastStore {
    func observation(maximumAge: TimeInterval = maximumFrameAge) throws -> ScreenBroadcastObservation {
        let frame = try readFrame(maximumAge: maximumAge)
        return ScreenBroadcastObservation(screenshot: DeviceScreenshot(frameID: frame.frameID,
            capturedAt: frame.capturedAt, width: frame.width, height: frame.height,
            mimeType: "image/jpeg", data: frame.jpegData),
            sessionID: frame.sessionID, orientation: frame.orientation)
    }

    func snapshot() throws -> DeviceScreenshot { try observation().screenshot }
}
