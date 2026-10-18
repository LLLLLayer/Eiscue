import Foundation

public enum AgentRunMode: Sendable, Equatable {
    case message
    case resume
}

public struct AgentRequest: Sendable {
    public let conversationID: UUID
    public let requestID: UUID
    public let prompt: String
    public let systemPrompt: String
    /// Per-run execution budget: each invocation reserves its tool executionCost,
    /// including any observation performed inside a compound tool.
    public let maxToolCalls: Int
    public let timeoutSeconds: Double
    public let mode: AgentRunMode
    /// Used only when the runtime transcript is empty, to import existing local conversations.
    public let history: [AgentMessage]
    public let attachments: [AgentAttachment]

    public init(
        conversationID: UUID, requestID: UUID = UUID(), prompt: String, systemPrompt: String = "",
        maxToolCalls: Int = 30, timeoutSeconds: Double = 180, mode: AgentRunMode = .message,
        history: [AgentMessage] = [], attachments: [AgentAttachment] = []
    ) {
        self.conversationID = conversationID
        self.requestID = requestID
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.maxToolCalls = maxToolCalls
        self.timeoutSeconds = timeoutSeconds
        self.mode = mode
        self.history = history
        self.attachments = attachments
    }
}

public enum AgentPauseReason: String, Codable, Sendable, Equatable {
    case toolBudget, noProgress, verificationUnavailable, connectionLost, hostRequested
}

public enum StopCause: Codable, Sendable, Equatable {
    case cancelled, timedOut, userRequested, engineCancelled, hardwareStop, eventSaveFailed
    /// The host received the system's background expiration callback, which
    /// can also follow cancellation from the system activity UI.
    case backgroundExpired
    case outcomeUnknown(toolName: String)
    case paused(AgentPauseReason)
}

public enum AgentRunOutcome: Sendable, Equatable {
    case completed
    case cancelled
    case stopped(StopCause)
}

public enum AgentEvent: Sendable, Equatable {
    /// The request is durably admitted, or an existing interrupted run is accepted for explicit continuation.
    /// A repeated request ID acknowledges the same durable submission without submitting it twice.
    case requestAccepted(UUID)
    /// Current text of the assistant's in-flight message, replacing the preceding partial.
    case assistantText(String)
    /// A committed assistant message; its stable ID is also returned by recovery.
    case message(AgentMessage)
    case toolStarted(AgentToolCall)
    case toolFinished(AgentToolCompletion)
    /// Cleanup failed independently of the run outcome. The database cannot be reopened until ownership is released.
    case cleanupFailed(String)
    case finished(AgentRunOutcome)
}

public struct AgentRecovery: Sendable, Equatable {
    public let messages: [AgentMessage]
    public let hasInterruptedRun: Bool
    public let acceptedRequestIDs: Set<UUID>

    public init(messages: [AgentMessage], hasInterruptedRun: Bool, acceptedRequestIDs: Set<UUID> = []) {
        self.messages = messages
        self.hasInterruptedRun = hasInterruptedRun
        self.acceptedRequestIDs = acceptedRequestIDs
    }
}
