import Foundation

public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var messages: [AgentMessage]
    public let createdAt: Date
    public var updatedAt: Date
    /// Saved atomically with a user message until runtime admission is confirmed.
    /// Hosts can recover an interrupted send even before its run journal exists.
    public var pendingRequestID: UUID?

    public init(
        id: UUID = UUID(),
        title: String = AgentLocalization.newConversationTitle,
        messages: [AgentMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        pendingRequestID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.pendingRequestID = pendingRequestID
    }
}
