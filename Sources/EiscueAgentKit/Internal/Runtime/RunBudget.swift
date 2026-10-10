import Foundation

actor RunBudget {
    private let limit: Int
    private var count = 0
    private var stopped = false
    private(set) var failure: AgentError?
    init(limit: Int) { self.limit = limit }

    func enter() throws {
        try check()
        guard count < limit else {
            failure = .toolLimitReached
            throw AgentError.toolLimitReached
        }
        count += 1
    }

    func check() throws {
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
        if let failure { throw failure }
    }
    func stop() { stopped = true }
}
