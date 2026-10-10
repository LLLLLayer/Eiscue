import Foundation

/// A timeout always revokes the owned transport. It never waits for a task group
/// to join an unresponsive stop operation and never retries the remote request.
@MainActor final class BoundedMediaRelease {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var stopTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private let close: @MainActor @Sendable () -> Void

    private init(close: @escaping @MainActor @Sendable () -> Void) { self.close = close }

    static func run(timeout: Duration = .seconds(5),
                    stop: @escaping @MainActor @Sendable () async throws -> Void,
                    close: @escaping @MainActor @Sendable () -> Void) async -> Bool {
        let release = BoundedMediaRelease(close: close)
        return await withCheckedContinuation { continuation in
            release.continuation = continuation
            release.stopTask = Task { @MainActor in
                do { try await stop(); release.finish(confirmed: true) }
                catch { release.finish(confirmed: false) }
            }
            release.deadlineTask = Task { @MainActor in
                do { try await Task.sleep(for: timeout) }
                catch { return }
                release.finish(confirmed: false)
            }
        }
    }

    private func finish(confirmed: Bool) {
        guard let pending = continuation else { return }
        continuation = nil
        close()
        stopTask?.cancel(); stopTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        pending.resume(returning: confirmed)
    }
}
