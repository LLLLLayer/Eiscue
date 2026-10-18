import Foundation

/// Fixed movements available only on the app's visible, owned calibration page.
public enum BluetoothRelativeCalibrationProbe: String, CaseIterable, Sendable, Hashable {
    case horizontalSmall, horizontalLarge, vertical, independentDiagonal, paceFast, paceSlow

    public var anchor: DevicePoint { DevicePoint(x: 0.35, y: 0.35) }
    var stroke: BluetoothRelativeStroke {
        let vector: (Int, Int)
        switch self {
        case .horizontalSmall: vector = (3, 0)
        case .vertical: vector = (0, 6)
        case .independentDiagonal: vector = (4, -4)
        default: vector = (6, 0)
        }
        let duration = self == .paceFast ? 100 : self == .paceSlow ? 384 : 192
        return BluetoothRelativeStroke(totalDX: vector.0 * 12, totalDY: vector.1 * 12, steps: 12, durationMS: duration)
    }
}

/// Actual UIKit contact evidence, in normalized full-display coordinates.
/// A command ACK alone cannot establish that iOS performed a continuous drag.
public struct BluetoothRelativeCalibrationObservation: Sendable {
    public let probe: BluetoothRelativeCalibrationProbe
    public let receiptToken: UUID
    public let start: DevicePoint
    public let end: DevicePoint
    public let contactCount: Int
    public let movedEventCount: Int
    public let endedNormally: Bool
    /// UITouch.timestamp uses the same monotonic clock as systemUptime.
    public let startedUptime: TimeInterval
    public let endedUptime: TimeInterval

    public init(probe: BluetoothRelativeCalibrationProbe, receiptToken: UUID, start: DevicePoint, end: DevicePoint,
                contactCount: Int, movedEventCount: Int, endedNormally: Bool,
                startedUptime: TimeInterval, endedUptime: TimeInterval) {
        self.probe = probe; self.receiptToken = receiptToken; self.start = start; self.end = end
        self.contactCount = contactCount; self.movedEventCount = movedEventCount; self.endedNormally = endedNormally
        self.startedUptime = startedUptime; self.endedUptime = endedUptime
    }
}

/// Setup-only receipt binding; it does not issue or consume model frame grants.
struct BluetoothRelativeCalibrationReceipt: Sendable {
    let token: UUID
    let dispatchUptime: TimeInterval
    let completedUptime: TimeInterval
    func matches(_ observation: BluetoothRelativeCalibrationObservation) -> Bool {
        observation.receiptToken == token
            && observation.startedUptime >= dispatchUptime - 0.002
            && observation.startedUptime <= completedUptime
            && observation.endedUptime >= dispatchUptime + Double(observation.probe.stroke.durationMS) / 1000 - 0.020
            && observation.endedUptime <= completedUptime + 0.250
    }
}

/// Wire-v1 opcode 10. Signed cumulative division truncates toward zero, exactly
/// like the firmware's C int32_t division; duration intervals use positive floor.
/// Firmware releases eight milliseconds after the last movement, then ACKs.
struct BluetoothRelativeStroke: Sendable, Equatable {
    let totalDX: Int
    let totalDY: Int
    let steps: Int
    let durationMS: Int

    var deltas: [(x: Int, y: Int)] {
        guard (1...250).contains(steps), (-32768...32767).contains(totalDX), (-32768...32767).contains(totalDY) else { return [] }
        return (1...steps).map { i in
            (totalDX * i / steps - totalDX * (i - 1) / steps,
             totalDY * i / steps - totalDY * (i - 1) / steps)
        }
    }
    var intervals: [Int] {
        guard (1...250).contains(steps), (100...2000).contains(durationMS) else { return [] }
        return (1...steps).map { durationMS * $0 / steps - durationMS * ($0 - 1) / steps }
    }
    var isValid: Bool {
        let values = deltas, timing = intervals
        return values.count == steps && timing.count == steps && !values.isEmpty
            && values.allSatisfy { $0.x * $0.x + $0.y * $0.y <= 64 }
            && timing.allSatisfy { (8...50).contains($0) }
    }
    var payload: [UInt8] {
        [UInt8(truncatingIfNeeded: totalDX), UInt8(truncatingIfNeeded: totalDX >> 8),
         UInt8(truncatingIfNeeded: totalDY), UInt8(truncatingIfNeeded: totalDY >> 8), UInt8(steps),
         UInt8(truncatingIfNeeded: durationMS), UInt8(truncatingIfNeeded: durationMS >> 8)]
    }
}

/// A session-local fit in UIKit points, never screenshot pixels or an assumed
/// device gain. Gain at six counts is normalized to one; the fitted basis holds
/// orientation and axis scale. Only the measured 3...6-count spatial interval
/// and the independently checked 8...32 ms cadence are admitted.
struct BluetoothRelativeDragCalibration: Sendable {
    let viewport: DevicePoint
    let xBasis: DevicePoint
    let yBasis: DevicePoint
    let gainIntercept: Double
    let gainSlope: Double
    static let endpointTolerance = 2.5 // UIKit points, including integer quantization.

    init(observed: [BluetoothRelativeCalibrationObservation], viewport: DevicePoint) throws {
        guard viewport.x.isFinite, viewport.y.isFinite, viewport.x > 0, viewport.y > 0,
              observed.count == BluetoothRelativeCalibrationProbe.allCases.count,
              Set(observed.map(\.probe)).count == observed.count,
              observed.allSatisfy({ value in
                  value.contactCount == 1 && value.movedEventCount > 0 && value.endedNormally
                    && value.startedUptime.isFinite && value.startedUptime >= 0 && value.endedUptime.isFinite
                    && value.endedUptime - value.startedUptime >= Double(value.probe.stroke.durationMS) / 1000 - 0.020
                    && [value.start, value.end].allSatisfy(Self.normalized)
                    && hypot((value.start.x - value.probe.anchor.x) * viewport.x,
                             (value.start.y - value.probe.anchor.y) * viewport.y) <= Self.endpointTolerance
              }) else { throw DeviceControlError.invalidCoordinates }
        self.viewport = viewport
        func displacement(_ probe: BluetoothRelativeCalibrationProbe) -> DevicePoint {
            let sample = observed.first { $0.probe == probe }!
            return DevicePoint(x: (sample.end.x - sample.start.x) * viewport.x,
                               y: (sample.end.y - sample.start.y) * viewport.y)
        }
        let small = displacement(.horizontalSmall), large = displacement(.horizontalLarge)
        let vertical = displacement(.vertical)
        guard hypot(small.x, small.y) >= 8, hypot(large.x, large.y) >= 16,
              hypot(vertical.x, vertical.y) >= 16 else { throw DeviceControlError.invalidCoordinates }
        xBasis = Self.scale(large, 1 / 72.0); yBasis = Self.scale(vertical, 1 / 72.0)
        let determinant = xBasis.x * yBasis.y - xBasis.y * yBasis.x
        let axisProduct = hypot(xBasis.x, xBasis.y) * hypot(yBasis.x, yBasis.y)
        guard abs(determinant) > axisProduct * 0.5 else { throw DeviceControlError.invalidCoordinates }
        let ratio = 2 * (small.x * large.x + small.y * large.y) / (large.x * large.x + large.y * large.y)
        gainIntercept = 2 * ratio - 1; gainSlope = (1 - ratio) / 3
        // A positive, monotone displacement function is needed for inversion.
        guard ratio.isFinite, ratio > 0,
              gainIntercept + 6 * gainSlope > 0.05,
              gainIntercept + 2 * 3 * gainSlope > 0,
              gainIntercept + 2 * 6 * gainSlope > 0 else { throw DeviceControlError.invalidCoordinates }
        let predictedSmall = Self.scale(large, ratio / 2)
        guard Self.distance(small, predictedSmall) <= Self.endpointTolerance else { throw DeviceControlError.invalidCoordinates }
        let diagonal = predicted(BluetoothRelativeCalibrationProbe.independentDiagonal.stroke)
        guard Self.distance(diagonal, displacement(.independentDiagonal)) <= Self.endpointTolerance,
              Self.distance(large, displacement(.paceFast)) <= Self.endpointTolerance,
              Self.distance(large, displacement(.paceSlow)) <= Self.endpointTolerance else { throw DeviceControlError.invalidCoordinates }
    }

    func plan(displacement: DevicePoint, duration: Duration, start: DevicePoint? = nil) throws -> BluetoothRelativeStroke {
        guard duration >= DeviceInputValidation.minimumSwipeDuration, duration <= DeviceInputValidation.maximumSwipeDuration else { throw DeviceControlError.invalidDuration }
        guard displacement.x.isFinite, displacement.y.isFinite else { throw DeviceControlError.invalidCoordinates }
        if let start, !Self.normalized(start) { throw DeviceControlError.invalidCoordinates }
        let ms = Int((Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15).rounded())
        let target = DevicePoint(x: displacement.x * viewport.x, y: displacement.y * viewport.y)
        let d = xBasis.x * yBasis.y - xBasis.y * yBasis.x
        let unscaled = DevicePoint(x: (target.x * yBasis.y - target.y * yBasis.x) / d,
                                   y: (target.y * xBasis.x - target.x * xBasis.y) / d)
        let length = hypot(unscaled.x, unscaled.y)
        guard length.isFinite, length > 0 else { throw DeviceControlError.relativeDragUnrepresentable }
        let first = max(1, (ms + 31) / 32), last = min(250, ms / 8)
        guard first <= last else { throw DeviceControlError.relativeDragUnrepresentable }
        var best: BluetoothRelativeStroke?, bestError = Self.endpointTolerance
        for steps in first...last {
            let perStep = length / Double(steps)
            let lowValue = 3 * gain(3), highValue = 6 * gain(6)
            guard perStep >= lowValue - 1, perStep <= highValue + 1 else { continue }
            var low = 3.0, high = 6.0
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if middle * gain(middle) < perStep { low = middle } else { high = middle }
            }
            let total = Double(steps) * (low + high) / 2
            let centerX = Int((unscaled.x / length * total).rounded())
            let centerY = Int((unscaled.y / length * total).rounded())
            for dx in (centerX - 2)...(centerX + 2) {
                for dy in (centerY - 2)...(centerY + 2) {
                    let stroke = BluetoothRelativeStroke(totalDX: dx, totalDY: dy, steps: steps, durationMS: ms)
                    guard stroke.isValid, stroke.intervals.allSatisfy({ (8...32).contains($0) }),
                          stroke.deltas.allSatisfy({ (9...36).contains($0.x * $0.x + $0.y * $0.y) }) else { continue }
                    let error = pathError(stroke, target: target, start: start)
                    if error <= bestError { best = stroke; bestError = error }
                }
            }
        }
        guard let best else { throw DeviceControlError.relativeDragUnrepresentable }
        return best
    }

    func predicted(_ stroke: BluetoothRelativeStroke) -> DevicePoint {
        stroke.deltas.reduce(DevicePoint(x: 0, y: 0)) { result, delta in
            let value = transformed(delta)
            return DevicePoint(x: result.x + value.x, y: result.y + value.y)
        }
    }
    private func pathError(_ stroke: BluetoothRelativeStroke, target: DevicePoint, start: DevicePoint?) -> Double {
        var current = DevicePoint(x: 0, y: 0), maximum = 0.0
        for (index, delta) in stroke.deltas.enumerated() {
            let value = transformed(delta)
            current = DevicePoint(x: current.x + value.x, y: current.y + value.y)
            if let start {
                let point = DevicePoint(x: start.x + current.x / viewport.x, y: start.y + current.y / viewport.y)
                if !Self.normalized(point) { return .infinity }
            }
            maximum = max(maximum, Self.distance(current, Self.scale(target, Double(index + 1) / Double(stroke.steps))))
        }
        return maximum
    }
    private func transformed(_ delta: (x: Int, y: Int)) -> DevicePoint {
        let factor = gain(hypot(Double(delta.x), Double(delta.y)))
        return DevicePoint(x: (xBasis.x * Double(delta.x) + yBasis.x * Double(delta.y)) * factor,
                           y: (xBasis.y * Double(delta.x) + yBasis.y * Double(delta.y)) * factor)
    }
    private func gain(_ length: Double) -> Double { gainIntercept + gainSlope * length }
    private static func normalized(_ p: DevicePoint) -> Bool { p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y) }
    private static func scale(_ p: DevicePoint, _ factor: Double) -> DevicePoint { DevicePoint(x: p.x * factor, y: p.y * factor) }
    private static func distance(_ a: DevicePoint, _ b: DevicePoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}
