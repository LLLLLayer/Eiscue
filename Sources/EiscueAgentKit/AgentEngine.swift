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
    case toolExecutionPaused(AgentPauseReason)
    case cleanupFailed(String)
    case timedOut
    /// A new model response failed after this run's input. Runtime and durable
    /// cleanup succeeded; this classification says nothing about prior tools.
    case modelRequestFailed(String)
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case .unconfigured:
            String(localized: "agent.error.unconfigured", defaultValue: "The AI engine is not configured.", bundle: .module)
        case .invalidConfiguration(let reason): reason
        case .busy: String(localized: "agent.error.busy", defaultValue: "A task is running. Stop it or wait for it to finish.", bundle: .module)
        case .interruptedRun: String(localized: "agent.error.interrupted-run", defaultValue: "This conversation has an unfinished task. Continue or end it first.", bundle: .module)
        case .nothingToResume: String(localized: "agent.error.nothing-to-resume", defaultValue: "No task to continue in this conversation.", bundle: .module)
        case .toolLimitReached: String(localized: "agent.error.tool-limit", defaultValue: "This task reached its step limit.", bundle: .module)
        case .timedOut: String(localized: "agent.error.timeout", defaultValue: "The task stopped at its time limit.", bundle: .module)
        case .toolExecutionPaused(let reason): reason.localizedDescription
        case .cleanupFailed(let message), .modelRequestFailed(let message), .runtime(let message): message
        }
    }
}

/// A replaceable engine must satisfy these durable execution contracts:
/// - Yield requestAccepted only after persisting admission. A repeated requestID admits the same input once.
/// - Recovery and toolResult are read-only: they never submit, resume, request a model response, or execute a tool.
/// - Interrupted work resumes only for an explicit request with mode .resume; new input rejects unfinished work.
/// - Side-effect tools are never automatically replayed after interruption or an unknown outcome.
/// - An unknown tool outcome terminates before the next model request or tool dispatch.
/// - cancel waits for execution and storage close to finish; abort/close failures throw and remain observable.
///   If the latest run already ended with cleanup failure, a later cancel still reports that failure.
/// - One process-wide owner may open a conversation database. Failed close retains ownership.
/// - Every committed tool result, including image content and typed outcome, is available through toolResult.
/// Engine implementations must pass AgentEngineContractTests before being used by the host.
public protocol AgentEngine: Sendable {
    var availability: AgentAvailability { get async }
    func run(request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func recover(conversationID: UUID) async throws -> AgentRecovery
    /// Reads one committed tool result without submitting, resuming, or executing a task.
    /// Results can contain sensitive screen data; callers must not put them in logs or reports.
    func toolResult(conversationID: UUID, requestID: UUID, toolCallID: String) async throws -> AgentToolCompletion?
    func cancel() async throws
    func cancel(conversationID: UUID) async throws
    func removeConversation(id: UUID) async throws
}

public extension AgentPauseReason {
    var localizedDescription: String {
        switch self {
        case .toolBudget: AgentError.toolLimitReached.localizedDescription
        case .noProgress: String(localized: "agent.pause.no-progress", defaultValue: "The task paused because it was not making progress.", bundle: .module)
        case .verificationUnavailable: String(localized: "agent.pause.verification-unavailable", defaultValue: "The last action could not be verified. Observe again before continuing.", bundle: .module)
        case .connectionLost: String(localized: "agent.pause.connection-lost", defaultValue: "The device connection was lost. Reconnect before continuing.", bundle: .module)
        case .hostRequested: String(localized: "agent.pause.host-requested", defaultValue: "The task paused. Review progress before continuing.", bundle: .module)
        }
    }
}
