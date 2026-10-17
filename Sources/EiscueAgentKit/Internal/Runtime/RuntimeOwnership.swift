import Foundation

/// A close failure intentionally quarantines its path for the process lifetime: another
/// scheduler must not reopen or delete storage whose previous owner may still be alive.
actor RuntimeOwnership {
    static let shared = RuntimeOwnership()
    private var owners: [String: UUID] = [:]

    func acquire(_ url: URL) throws -> UUID {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard owners[path] == nil else { throw AgentError.busy }
        let token = UUID(); owners[path] = token
        return token
    }

    func release(_ url: URL, token: UUID) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if owners[path] == token { owners[path] = nil }
    }
}

actor RuntimeCompletion {
    private(set) var cleanupError: AgentError?
    func failCleanup(_ error: AgentError) { if cleanupError == nil { cleanupError = error } }
}

enum RuntimeStopSignal: Error { case outcomeUnknown }
