import Foundation

public protocol ConversationRepository: Sendable {
    /// Returns conversations ordered by most recently updated first.
    func load() async throws -> [Conversation]
    func save(_ conversation: Conversation) async throws
    func delete(id: UUID) async throws
}

public enum ConversationStoreError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(Int)
    case duplicateConversationID(UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            String(localized: "agent.storage.unsupported-version", defaultValue: "Conversation file version \(String(describing: version)) is unsupported. The original file is preserved.", bundle: .module)
        case .duplicateConversationID:
            String(localized: "agent.storage.duplicate-conversation", defaultValue: "The conversation file has duplicate records. The original file is preserved.", bundle: .module)
        }
    }
}
