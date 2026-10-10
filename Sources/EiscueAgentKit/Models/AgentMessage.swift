import Foundation

public enum AgentRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

public struct AgentMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let role: AgentRole
    public let text: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        role: AgentRole,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}
