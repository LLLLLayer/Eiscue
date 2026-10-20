import Foundation

actor RunBudget {
    private let limit: Int
    private let verificationCost: Int?
    private var count = 0
    private var verificationDue = false
    private var stopped = false
    private(set) var failure: AgentError?
    private(set) var terminalCause: StopCause?
    // Successful use of the last units still permits a final model answer.
    // Only a recorded pause or unknown outcome terminates the generation.
    var requiresTermination: Bool { terminalCause != nil || failure != nil }

    init(limit: Int, verificationCost: Int? = nil) {
        self.limit = limit
        self.verificationCost = verificationCost
    }

    func enter(mayHaveSideEffects: Bool, isVerification: Bool, executionCost: Int, verifiesSideEffects: Bool) throws {
        try check()
        let remaining = limit - count
        guard executionCost > 0, executionCost <= remaining else {
            reachLimit()
            throw AgentError.toolLimitReached
        }
        // Never dispatch the last action without room to inspect its result.
        // A compound action reserves its observation in its own execution cost.
        let needsReservedCall = verificationCost.map { remaining - executionCost < $0 } == true
            && !verifiesSideEffects
            && (mayHaveSideEffects || (verificationDue && !isVerification))
        guard !needsReservedCall else {
            reachLimit()
            throw AgentError.toolLimitReached
        }
        count += executionCost
        // A throwing side-effect tool may have sent input before failing; only
        // a successful verification can discharge its observation reservation.
        if mayHaveSideEffects { verificationDue = true }
    }
    func complete(isVerification: Bool, verifiesSideEffects: Bool, isError: Bool) {
        if isVerification || verifiesSideEffects, !isError { verificationDue = false }
    }
    func pause(_ reason: AgentPauseReason) { if failure == nil { failure = .toolExecutionPaused(reason) } }
    func outcomeUnknown(toolName: String) { if terminalCause == nil { terminalCause = .outcomeUnknown(toolName: toolName) } }
    func reachLimit() { if failure == nil { failure = .toolLimitReached } }

    func verificationReminder() -> String? {
        let remaining = limit - count
        guard let verificationCost, verificationDue, remaining <= max(3, verificationCost) else { return nil }
        return "Remaining execution units: \(remaining). Use the verification tool now to inspect the last action. At least \(verificationCost) units are reserved for observation; do not perform another action without room to verify it."
    }

    func check() throws {
        try Task.checkCancellation()
        if terminalCause != nil { throw RuntimeStopSignal.outcomeUnknown }
        if stopped { throw CancellationError() }
        if let failure { throw failure }
    }
    func stop() { stopped = true }
}
