import EiscueDeviceCore

@MainActor
enum DeviceRunCleanup {
    static func finish(run: RunRecord, disconnectAfterTask: Bool,
                       modelRequestFailed: Bool, deviceTools: DeviceToolSession?, stopRequested: Bool,
                       finishConnection: () async throws -> Void, disconnect: () async -> Void) async throws {
        guard run.scope != .chat else { return }
        // Runtime cleanup must have confirmed a model-only failure, and the
        // host gate must still be unused. Event delivery alone can lag execution.
        let unusedModelFailure = modelRequestFailed && run.state == .failed && run.submission == .accepted
            && deviceTools?.hasStartedExecution == false && (run.activities ?? []).isEmpty
        // The host marks a pause only after the runtime has closed cleanly.
        // A legacy or incomplete record cannot opt into connection retention.
        let safePause = run.state == .paused && run.submission == .accepted
            && run.pauseReason != nil && run.pauseReason != .connection
        guard !disconnectAfterTask, !stopRequested, run.state == .completed || safePause || unusedModelFailure else {
            await disconnect()
            return
        }
        do {
            // End task-scoped input and invalidate observations while keeping
            // the selected connection. An unconfirmed release still disconnects.
            try await finishConnection()
        } catch {
            await disconnect()
            throw error
        }
    }
}
