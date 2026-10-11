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
    public let attachments: [AgentAttachment]

    public init(
        id: UUID = UUID(),
        role: AgentRole,
        text: String,
        createdAt: Date = Date(),
        attachments: [AgentAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, createdAt, attachments }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(AgentRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attachments = try container.decodeIfPresent([AgentAttachment].self, forKey: .attachments) ?? []
    }
}
