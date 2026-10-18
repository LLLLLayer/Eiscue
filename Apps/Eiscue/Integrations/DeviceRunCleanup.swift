import EiscueDeviceCore
import Foundation

@MainActor
enum DeviceRunCleanup {
    struct Failures: LocalizedError {
        let inputRelease: any Error
        let disconnect: DeviceSession.Failure
        var errorDescription: String? { inputRelease.localizedDescription + "\n" + disconnect.localizedDescription }
    }

    /// HID has no owned remote media session to confirm. Network routes still
    /// require the disconnect receipt; this does not change its raw value.
    static func acceptsRelease(confirmed: Bool, method: DeviceConnectionMethod) -> Bool {
        method == .bluetoothBoard || confirmed
    }

    static func finish(run: RunRecord, method: DeviceConnectionMethod, disconnectAfterTask: Bool,
                       modelRequestFailed: Bool, deviceTools: DeviceToolSession?, stopRequested: Bool,
                       finishConnection: () async throws -> Void, disconnect: () async -> Bool) async throws {
        guard run.scope != .chat else { return }
        // Runtime cleanup must have confirmed a model-only failure, and the
        // host gate must still be unused. Event delivery alone can lag execution.
        let unusedModelFailure = modelRequestFailed && run.state == .failed && run.submission == .accepted
            && deviceTools?.hasStartedExecution == false && (run.activities ?? []).isEmpty
        // The host marks a pause only after the runtime has closed cleanly.
        // A legacy or incomplete record cannot opt into connection retention.
        let safePause = run.state == .paused && run.submission == .accepted
            && run.pauseReason != nil && run.pauseReason != .connection
        guard run.cleanupFailure == nil, deviceTools?.hasUnknownOutcome != true, !disconnectAfterTask, !stopRequested, run.state == .completed || safePause || unusedModelFailure else {
            guard acceptsRelease(confirmed: await disconnect(), method: method) else { throw DeviceSession.Failure.releaseUnconfirmed }
            return
        }
        do {
            // End task-scoped input and invalidate observations while keeping
            // the selected connection. An unconfirmed release still disconnects.
            try await finishConnection()
        } catch {
            guard acceptsRelease(confirmed: await disconnect(), method: method) else {
                throw Failures(inputRelease: error, disconnect: .releaseUnconfirmed)
            }
            throw error
        }
    }
}
