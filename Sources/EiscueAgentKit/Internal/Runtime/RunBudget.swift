import Foundation

actor RunBudget {
    private let limit: Int
    private let reservesVerification: Bool
    private var count = 0
    private var verificationDue = false
    private var stopped = false
    private(set) var failure: AgentError?
    init(limit: Int, reservesVerification: Bool = false) {
        self.limit = limit
        self.reservesVerification = reservesVerification
    }

    func enter(mayHaveSideEffects: Bool, isVerification: Bool) throws {
        try check()
        // Never dispatch the last action without room to inspect its result.
        let needsReservedCall = reservesVerification && limit - count == 1
            && (mayHaveSideEffects || (verificationDue && !isVerification))
        guard count < limit, !needsReservedCall else {
            failure = .toolLimitReached
            throw AgentError.toolLimitReached
        }
        count += 1
        // A throwing side-effect tool may have sent input before failing; only
        // a successful verification can discharge its observation reservation.
        if mayHaveSideEffects { verificationDue = true }
    }
    func complete(isVerification: Bool, isError: Bool) {
        if isVerification, !isError { verificationDue = false }
    }
    func pause(_ reason: String) { if failure == nil { failure = .toolExecutionPaused(reason) } }

    func verificationReminder() -> String? {
        let remaining = limit - count
        guard reservesVerification, remaining <= 3 else { return nil }
        return "Remaining tool calls: \(remaining). Use the verification tool now to inspect the last action. The final call is reserved for observation; do not perform another action without room to verify it."
    }

    func check() throws {
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
        if let failure { throw failure }
    }
    func stop() { stopped = true }
}
