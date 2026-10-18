import Foundation
import Testing
@testable import EiscueDeviceCore

@Suite struct BluetoothRelativeDragTests {
    @Test func wireDDAIsSignedExactRadiallyBoundedAndUsesCumulativeTiming() {
        let stroke = BluetoothRelativeStroke(totalDX: -73, totalDY: 35, steps: 13, durationMS: 109)
        #expect(stroke.isValid)
        #expect(stroke.deltas.map(\.x).reduce(0, +) == -73)
        #expect(stroke.deltas.map(\.y).reduce(0, +) == 35)
        #expect(stroke.deltas.first?.x == -5)
        #expect(stroke.deltas[1].x == -6)
        #expect(stroke.intervals.reduce(0, +) == 109)
        #expect(Set(stroke.intervals) == [8, 9])
        #expect(BluetoothBoardProtocol.payloadIsValid(opcode: 10, payload: stroke.payload))
        let mirror = BluetoothRelativeStroke(totalDX: 73, totalDY: -35, steps: 13, durationMS: 109)
        #expect(zip(stroke.deltas, mirror.deltas).allSatisfy { $0.x == -$1.x && $0.y == -$1.y })
        // Axis bounds alone would accept (6,6), whose radial length exceeds 8.
        #expect(!BluetoothRelativeStroke(totalDX: 72, totalDY: 72, steps: 12, durationMS: 192).isValid)
    }

    @Test func wireRejectsInvalidLimitsAndReservedBytes() {
        let valid = BluetoothRelativeStroke(totalDX: 72, totalDY: 0, steps: 12, durationMS: 100)
        #expect(valid.isValid)
        #expect(BluetoothBoardProtocol.payloadIsValid(opcode: 10, payload: valid.payload))
        for value in [
            BluetoothRelativeStroke(totalDX: 1, totalDY: 0, steps: 0, durationMS: 100),
            BluetoothRelativeStroke(totalDX: 1, totalDY: 0, steps: 251, durationMS: 2000),
            BluetoothRelativeStroke(totalDX: 72, totalDY: 0, steps: 12, durationMS: 99),
            BluetoothRelativeStroke(totalDX: 1, totalDY: 0, steps: 1, durationMS: 100),
            BluetoothRelativeStroke(totalDX: 72, totalDY: 0, steps: 13, durationMS: 100),
            BluetoothRelativeStroke(totalDX: 32768, totalDY: 0, steps: 250, durationMS: 2000),
        ] { #expect(!value.isValid) }
        #expect(!BluetoothBoardProtocol.payloadIsValid(opcode: 10, payload: valid.payload + [1]))
        let frame = BluetoothBoardProtocol.frame(opcode: 10, requestID: 0x1234, payload: valid.payload)
        #expect(Array(frame.prefix(4)) == [1, 10, 0x34, 0x12])
        #expect(Array(frame.suffix(5)) == [0, 0, 0, 0, 0])
    }

    @Test func calibrationLearnsSpatialAccelerationAndRotatedUnequalAxes() throws {
        let calibration = try profile()
        // Test fixture's physical model: rotated basis, x gain 1.4, y gain 0.8,
        // spatial gain 0.4 + 0.1 * report norm; no screen-pixel/count shortcut.
        #expect(abs(calibration.gainIntercept - 0.4) < 1e-9)
        #expect(abs(calibration.gainSlope - 0.1) < 1e-9)
        #expect(abs(calibration.xBasis.x) < 1e-9)
        #expect(abs(calibration.xBasis.y - 1.4) < 1e-9)
        #expect(abs(calibration.yBasis.x + 0.8) < 1e-9)
        let wanted = DevicePoint(x: -32.0 / 400, y: 75.0 / 800)
        let plan = try calibration.plan(displacement: wanted, duration: .milliseconds(192))
        let predicted = calibration.predicted(plan)
        #expect(plan.isValid)
        #expect(plan.intervals.allSatisfy { (8...32).contains($0) })
        #expect(plan.deltas.allSatisfy { (9...36).contains($0.x * $0.x + $0.y * $0.y) })
        #expect(hypot(predicted.x + 32, predicted.y - 75) <= BluetoothRelativeDragCalibration.endpointTolerance)
    }

    @Test func calibrationRequiresIndependentContactAndPaceEvidence() {
        for probe in BluetoothRelativeCalibrationProbe.allCases {
            var samples = observations()
            let index = samples.firstIndex { $0.probe == probe }!
            let old = samples[index]
            samples[index] = BluetoothRelativeCalibrationObservation(probe: probe, receiptToken: old.receiptToken,
                start: old.start, end: old.end, contactCount: 2, movedEventCount: 4, endedNormally: true,
                startedUptime: old.startedUptime, endedUptime: old.endedUptime)
            #expect(throws: DeviceControlError.invalidCoordinates) {
                try BluetoothRelativeDragCalibration(observed: samples, viewport: DevicePoint(x: 400, y: 800))
            }
        }
        for probe in [BluetoothRelativeCalibrationProbe.independentDiagonal, .paceFast, .paceSlow] {
            var samples = observations()
            let index = samples.firstIndex { $0.probe == probe }!
            let old = samples[index]
            samples[index] = BluetoothRelativeCalibrationObservation(probe: probe, receiptToken: old.receiptToken,
                start: old.start, end: DevicePoint(x: old.end.x + 0.02, y: old.end.y),
                contactCount: 1, movedEventCount: 4, endedNormally: true,
                startedUptime: old.startedUptime, endedUptime: old.endedUptime)
            #expect(throws: DeviceControlError.invalidCoordinates) {
                try BluetoothRelativeDragCalibration(observed: samples, viewport: DevicePoint(x: 400, y: 800))
            }
        }
        #expect(throws: DeviceControlError.invalidCoordinates) {
            try BluetoothRelativeDragCalibration(observed: Array(observations().dropLast()), viewport: DevicePoint(x: 400, y: 800))
        }
        for (moved, ended, offset) in [(0, true, 0.0), (8, false, 0.0), (8, true, 0.01)] {
            var samples = observations()
            let old = samples[0]
            samples[0] = BluetoothRelativeCalibrationObservation(probe: old.probe, receiptToken: old.receiptToken,
                start: DevicePoint(x: old.start.x + offset, y: old.start.y),
                end: DevicePoint(x: old.end.x + offset, y: old.end.y),
                contactCount: 1, movedEventCount: moved, endedNormally: ended,
                startedUptime: old.startedUptime, endedUptime: old.endedUptime)
            #expect(throws: DeviceControlError.invalidCoordinates) {
                try BluetoothRelativeDragCalibration(observed: samples, viewport: DevicePoint(x: 400, y: 800))
            }
        }
    }

    @Test func impossibleTrajectoriesAreRejectedInsteadOfClippedOrExtrapolated() throws {
        let calibration = try profile()
        for displacement in [DevicePoint(x: 0, y: 0), DevicePoint(x: 5, y: 5), DevicePoint(x: 0.001, y: 0.001)] {
            #expect(throws: DeviceControlError.relativeDragUnrepresentable) {
                try calibration.plan(displacement: displacement, duration: .milliseconds(100))
            }
        }
        #expect(throws: DeviceControlError.invalidDuration) {
            try calibration.plan(displacement: DevicePoint(x: 0, y: 0.1), duration: .seconds(3))
        }
        // A slow request cannot silently use a faster, unverified report cadence.
        #expect(throws: DeviceControlError.relativeDragUnrepresentable) {
            try calibration.plan(displacement: DevicePoint(x: 0, y: 0.02), duration: .seconds(2))
        }
        #expect(throws: DeviceControlError.relativeDragUnrepresentable) {
            try calibration.plan(displacement: DevicePoint(x: 0, y: 0.1), duration: .milliseconds(192),
                                 start: DevicePoint(x: 0.5, y: 0.95))
        }
    }

    @Test func receiptRejectsStaleEarlyEndedAndUnrelatedTouchTimestamps() {
        let token = UUID()
        let receipt = BluetoothRelativeCalibrationReceipt(token: token, dispatchUptime: 100, completedUptime: 100.24)
        func sample(start: TimeInterval, end: TimeInterval, id: UUID? = nil) -> BluetoothRelativeCalibrationObservation {
            BluetoothRelativeCalibrationObservation(probe: .horizontalLarge, receiptToken: id ?? token,
                start: DevicePoint(x: 0.35, y: 0.35), end: DevicePoint(x: 0.5, y: 0.35),
                contactCount: 1, movedEventCount: 8, endedNormally: true, startedUptime: start, endedUptime: end)
        }
        #expect(receipt.matches(sample(start: 100.01, end: 100.21)))
        #expect(!receipt.matches(sample(start: 99.9, end: 100.21)))
        #expect(!receipt.matches(sample(start: 100.01, end: 100.05)))
        #expect(!receipt.matches(sample(start: 100.3, end: 100.49)))
        #expect(!receipt.matches(sample(start: 100.01, end: 100.491)))
        #expect(!receipt.matches(sample(start: 100.01, end: 100.21, id: UUID())))
        #expect(!receipt.matches(sample(start: .nan, end: 100.21)))
    }

    private func profile() throws -> BluetoothRelativeDragCalibration {
        try BluetoothRelativeDragCalibration(observed: observations(), viewport: DevicePoint(x: 400, y: 800))
    }
    private func observations() -> [BluetoothRelativeCalibrationObservation] {
        BluetoothRelativeCalibrationProbe.allCases.map { probe in
            let delta = probe.stroke.deltas.reduce(DevicePoint(x: 0, y: 0)) { value, step in
                let gain = 0.4 + 0.1 * hypot(Double(step.x), Double(step.y))
                return DevicePoint(x: value.x - 0.8 * Double(step.y) * gain, y: value.y + 1.4 * Double(step.x) * gain)
            }
            let start = DevicePoint(x: 0.35, y: 0.35)
            return BluetoothRelativeCalibrationObservation(probe: probe, receiptToken: UUID(), start: start,
                end: DevicePoint(x: start.x + delta.x / 400, y: start.y + delta.y / 800),
                contactCount: 1, movedEventCount: 8, endedNormally: true,
                startedUptime: 100, endedUptime: 100 + Double(probe.stroke.durationMS + 8) / 1000)
        }
    }
}
