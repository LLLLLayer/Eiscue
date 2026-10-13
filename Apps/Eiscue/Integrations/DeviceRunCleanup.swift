import EiscueDeviceKit

@MainActor
enum DeviceRunCleanup {
    static func finish(run: RunRecord, method: DeviceConnectionMethod,
                       modelRequestFailed: Bool, deviceTools: DeviceToolSession?, stopRequested: Bool,
                       finishBluetooth: () async throws -> Void, disconnect: () async -> Void) async throws {
        guard run.scope != .chat else { return }
        // Runtime cleanup must have confirmed a model-only failure, and the
        // host gate must still be unused. Event delivery alone can lag execution.
        let unusedModelFailure = modelRequestFailed && run.state == .failed && run.submission == .accepted
            && deviceTools?.hasStartedExecution == false && (run.activities ?? []).isEmpty
        guard method == .bluetoothBoard, !stopRequested, run.state == .completed || unusedModelFailure else {
            await disconnect()
            return
        }
        do {
            // Release held input and invalidate the frame while preserving the
            // user's screen sharing. An unconfirmed release still disconnects.
            try await finishBluetooth()
        } catch {
            await disconnect()
            throw error
        }
    }
}
