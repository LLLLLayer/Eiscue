import Foundation

/// Use one repository instance per file. Operations on that instance are serialized.
/// A malformed or unsupported file is never replaced by an empty store.
public actor JSONConversationRepository: ConversationRepository {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [Conversation] {
        try read().sorted(by: Self.recentFirst)
    }

    public func save(_ conversation: Conversation) throws {
        var conversations = try read()
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
        try write(conversations)
    }

    public func delete(id: UUID) throws {
        var conversations = try read()
        let originalCount = conversations.count
        conversations.removeAll { $0.id == id }
        if conversations.count != originalCount {
            try write(conversations)
        }
    }

    private func read() throws -> [Conversation] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }

        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else {
            throw ConversationStoreError.unsupportedVersion(document.version)
        }
        var identifiers = Set<UUID>()
        for conversation in document.conversations {
            guard identifiers.insert(conversation.id).inserted else {
                throw ConversationStoreError.duplicateConversationID(conversation.id)
            }
        }
        return document.conversations
    }

    private func write(_ conversations: [Conversation]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            Document(version: 1, conversations: conversations.sorted(by: Self.recentFirst))
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func recentFirst(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private struct Document: Codable {
        let version: Int
        let conversations: [Conversation]
    }
}
