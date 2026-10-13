import Foundation

public enum AgentAvailability: Sendable, Equatable {
    case unconfigured
    case ready
}

public enum AgentError: Error, LocalizedError, Sendable, Equatable {
    case unconfigured
    case invalidConfiguration(String)
    case busy
    case interruptedRun
    case nothingToResume
    case toolLimitReached
    /// The host ended tool execution at a known boundary. This is surfaced only
    /// after durable cleanup succeeds; continuation requires a new request.
    case toolExecutionPaused(String)
    case timedOut
    /// A new model response failed after this run's input. Runtime and durable
    /// cleanup succeeded; this classification says nothing about prior tools.
    case modelRequestFailed(String)
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case .unconfigured:
            String(localized: "agent.error.unconfigured", defaultValue: "The agent engine has not been configured.", bundle: .module)
        case .invalidConfiguration(let reason): reason
        case .busy: String(localized: "agent.error.busy", defaultValue: "A task is already running. Stop it or wait for it to finish.", bundle: .module)
        case .interruptedRun: String(localized: "agent.error.interrupted-run", defaultValue: "This conversation has an unfinished task. Choose whether to resume or stop it.", bundle: .module)
        case .nothingToResume: String(localized: "agent.error.nothing-to-resume", defaultValue: "This conversation has no task to resume.", bundle: .module)
        case .toolLimitReached: String(localized: "agent.error.tool-limit", defaultValue: "This task has reached its tool call limit.", bundle: .module)
        case .timedOut: String(localized: "agent.error.timeout", defaultValue: "The task reached its time limit and stopped.", bundle: .module)
        case .toolExecutionPaused(let message), .modelRequestFailed(let message), .runtime(let message): message
        }
    }
}

/// The host can supply an engine without exposing its implementation to the UI.
public protocol AgentEngine: Sendable {
    var availability: AgentAvailability { get async }
    func run(request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func recover(conversationID: UUID) async throws -> AgentRecovery
    func cancel() async throws
    func cancel(conversationID: UUID) async throws
    func removeConversation(id: UUID) async throws
}
