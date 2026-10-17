import Foundation

/// Task completion has no authority to close the connection or screen sharing.
/// Missing/mismatched calibration only changes admission for the next task.
enum BluetoothTaskInputRelease {
    @MainActor static func run(release: @MainActor () async throws -> Void,
                               calibrationMatches: @MainActor () async -> Bool?,
                               invalidateCalibration: @MainActor () -> Void) async throws {
        try await release()
        if await calibrationMatches() == false { invalidateCalibration() }
    }
}
