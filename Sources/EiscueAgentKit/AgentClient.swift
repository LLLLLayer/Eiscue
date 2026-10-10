import Foundation

/// A stable entry point for the App and other users of EiscueAgentKit.
public struct AgentClient: Sendable {
    private let engine: any AgentEngine

    /// Creates an unconfigured client; execution requires a configuration or custom engine.
    public init() {
        engine = DefaultEngine()
    }

    public init(engine: any AgentEngine) {
        self.engine = engine
    }

    /// Opens local history for inspection, cancellation, or deletion without model credentials.
    public init(storageDirectory: URL) {
        engine = DefaultEngine(storageDirectory: storageDirectory)
    }

    public init(configuration: AgentConfiguration, storageDirectory: URL, tools: [AgentTool] = []) {
        engine = DefaultEngine(configuration: configuration, storageDirectory: storageDirectory, tools: tools)
    }

    public var availability: AgentAvailability {
        get async { await engine.availability }
    }

    public func run(request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        try await engine.run(request: request)
    }

    public func recover(conversationID: UUID) async throws -> AgentRecovery {
        try await engine.recover(conversationID: conversationID)
    }

    public func cancel() async throws {
        try await engine.cancel()
    }

    public func cancel(conversationID: UUID) async throws {
        try await engine.cancel(conversationID: conversationID)
    }

    public func removeConversation(id: UUID) async throws {
        try await engine.removeConversation(id: id)
    }
}
