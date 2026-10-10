import Foundation

public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var messages: [AgentMessage]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = AgentLocalization.newConversationTitle,
        messages: [AgentMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}
