import Foundation

/// Internal monitoring may finish before an action takes ownership. Two user
/// actions still conflict; monitoring can never jump ahead of a waiting action.
@MainActor
final class BluetoothOperationGate {
    private enum Owner { case status, action }
    private var owner: Owner?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, any Error>)?
    var isBusy: Bool { owner != nil }
    var hasWaitingAction: Bool { waiter != nil }

    func beginStatus() -> Bool {
        guard owner == nil else { return false }
        owner = .status
        return true
    }

    func endStatus() {
        guard owner == .status else { return }
        if let waiter {
            self.waiter = nil
            owner = .action
            waiter.continuation.resume()
        } else { owner = nil }
    }

    func beginExclusive() throws {
        try Task.checkCancellation()
        guard owner == nil else { throw DeviceControlError.busy }
        owner = .action
    }

    func beginAction() async throws {
        try Task.checkCancellation()
        guard owner == .status else { try beginExclusive(); return }
        guard waiter == nil else { throw DeviceControlError.busy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiter = (id, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.waiter?.id == id else { return }
                let pending = self.waiter
                self.waiter = nil
                pending?.continuation.resume(throwing: CancellationError())
            }
        }
        // Cancellation can race with the handoff; release only the ownership
        // handed to this call, before returning an error to its caller.
        do { try Task.checkCancellation() }
        catch { endAction(); throw error }
    }

    func endAction() {
        guard owner == .action else { return }
        owner = nil
    }
}
