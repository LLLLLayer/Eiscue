import Foundation

/// One fresh observation grants at most one coordinate-based action.
struct FrameLedger {
    private var frame: DeviceScreenshot?
    private var geometryID: UUID?
    private var recordedAt: ContinuousClock.Instant?
    mutating func record(_ frame: DeviceScreenshot, geometryID: UUID? = nil, now: ContinuousClock.Instant = .now) {
        self.frame = frame; self.geometryID = geometryID; recordedAt = now
    }
    mutating func invalidate() { frame = nil; geometryID = nil; recordedAt = nil }
    mutating func consume(id: UUID, points: [DevicePoint], geometryID: UUID? = nil, now: ContinuousClock.Instant = .now) throws -> [(UInt16, UInt16)] {
        guard self.geometryID == geometryID else {
            // Once a transition is seen, returning to the original layout cannot
            // make this observation valid again.
            invalidate()
            throw DeviceControlError.staleFrame
        }
        guard let frame, frame.frameID == id, let recordedAt,
              recordedAt.duration(to: now) >= .zero,
              recordedAt.duration(to: now) <= .seconds(30) else { throw DeviceControlError.staleFrame }
        guard frame.width > 1, frame.height > 1,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 && $0.x < Double(frame.width) && $0.y < Double(frame.height) }) else {
            throw DeviceControlError.invalidCoordinates
        }
        let converted = points.map { point in
            (UInt16((point.x / Double(frame.width) * 65535).rounded()),
             UInt16((point.y / Double(frame.height) * 65535).rounded()))
        }
        invalidate()
        return converted
    }
}
