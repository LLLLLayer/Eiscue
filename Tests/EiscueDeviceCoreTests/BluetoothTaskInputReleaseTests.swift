import Testing
@testable import EiscueDeviceCore

@Suite @MainActor struct BluetoothTaskInputReleaseTests {
    @Test func taskCompletionWithChangedGeometryClearsCalibrationAndSucceeds() async throws {
        var released = false, calibrationPresent = true
        try await BluetoothTaskInputRelease.run(release: { released = true },
            calibrationMatches: { false }, invalidateCalibration: { calibrationPresent = false })
        #expect(released && !calibrationPresent)
    }
    @Test(arguments: [true, nil])
    func matchingOrAbsentCalibrationDoesNotChangeTaskCompletion(matches: Bool?) async throws {
        var released = false, invalidated = false
        try await BluetoothTaskInputRelease.run(release: { released = true },
            calibrationMatches: { matches }, invalidateCalibration: { invalidated = true })
        #expect(released && !invalidated)
    }
    @Test func aRealInputReleaseFailureRemainsAnError() async throws {
        await #expect(throws: DeviceControlError.connectionLost) {
            try await BluetoothTaskInputRelease.run(release: { throw DeviceControlError.connectionLost },
                calibrationMatches: { false }, invalidateCalibration: {})
        }
    }
}
