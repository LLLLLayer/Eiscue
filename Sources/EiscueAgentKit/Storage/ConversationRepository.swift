import Foundation

public protocol ConversationRepository: Sendable {
    /// Returns conversations ordered by most recently updated first.
    func load() async throws -> [Conversation]
    /// Damaged records remain on disk and are reported independently of readable history.
    func loadResult() async throws -> ConversationLoadResult
    func save(_ conversation: Conversation) async throws
    func delete(id: UUID) async throws
}

public struct ConversationLoadResult: Sendable, Equatable {
    public let conversations: [Conversation]
    public let corruptIDs: [UUID]
    /// Pending reclamation is deferred whenever its complete input cannot be verified.
    public let maintenanceFailure: String?

    public init(conversations: [Conversation], corruptIDs: [UUID] = [], maintenanceFailure: String? = nil) {
        self.conversations = conversations; self.corruptIDs = corruptIDs; self.maintenanceFailure = maintenanceFailure
    }
}

public extension ConversationRepository {
    func loadResult() async throws -> ConversationLoadResult { .init(conversations: try await load()) }
}

public enum ConversationStoreError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(Int)
    case duplicateConversationID(UUID)
    case corruptConversations([UUID])
    case deletionPending

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            String(localized: "agent.storage.unsupported-version", defaultValue: "Conversation file version \(String(describing: version)) is unsupported. The original file is preserved.", bundle: .module)
        case .deletionPending:
            String(localized: "agent.storage.deletion-pending", defaultValue: "This conversation is being deleted. Reopen the conversation list to finish cleanup.", bundle: .module)
        case .duplicateConversationID:
            String(localized: "agent.storage.duplicate-conversation", defaultValue: "The conversation file has duplicate records. The original file is preserved.", bundle: .module)
        case .corruptConversations(let ids):
            String(localized: "agent.storage.corrupt-conversations", defaultValue: "Some conversations could not be read. Their original files are preserved: \(ids.map(\.uuidString).joined(separator: ", "))", bundle: .module)
        }
    }
}
