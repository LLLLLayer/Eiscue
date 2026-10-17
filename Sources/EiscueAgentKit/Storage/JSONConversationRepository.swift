import CryptoKit
import Foundation

/// Use one repository instance per file. Operations on that instance are serialized.
/// Version 1 is read in place and migrated on the first mutation. Its exact bytes
/// remain in a sibling `.legacy-v1` file until an explicit deletion retires the backup.
/// Unreferenced attachment blobs are reclaimed only for explicit deletions;
/// pending cleanup resumes on load and before another mutation.
public actor JSONConversationRepository: ConversationRepository {
    private let fileURL: URL
    private var directory: URL { fileURL.appendingPathExtension("store") }
    private var legacyURL: URL { fileURL.appendingPathExtension("legacy-v1") }

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() async throws -> [Conversation] {
        try await loadResult().conversations
    }

    public func loadResult() async throws -> ConversationLoadResult {
        switch try readDocument() {
        case .legacy(let conversations, _): return .init(conversations: conversations.sorted(by: Self.recentFirst))
        case .manifest(var manifest):
            var failure: String?
            do { try resumePendingDeletions(&manifest) } catch { failure = error.localizedDescription }
            var conversations: [Conversation] = [], corruptIDs: [UUID] = []
            for id in manifest.conversationIDs {
                do { conversations.append(try readConversation(id)) } catch { corruptIDs.append(id) }
            }
            return .init(conversations: conversations.sorted(by: Self.recentFirst), corruptIDs: corruptIDs,
                         maintenanceFailure: failure)
        }
    }

    public func save(_ conversation: Conversation) throws {
        var manifest = try migrateIfNeeded()
        // A failed deletion must not resurrect an ID into both manifest lists.
        guard manifest.pendingDeletionIDs?.contains(conversation.id) != true else {
            throw ConversationStoreError.deletionPending
        }
        // Reclamation has a wider validation boundary than an individual save.
        // Its durable pending list survives while healthy conversations keep working.
        try? resumePendingDeletions(&manifest)
        let exists = manifest.conversationIDs.contains(conversation.id)
        // Do not silently replace a damaged record or one whose blobs are missing.
        if exists || FileManager.default.fileExists(atPath: conversationURL(conversation.id).path) {
            _ = try readRecord(conversation.id, verifyBlobs: false)
        }
        try writeConversation(conversation)
        if !exists {
            manifest.conversationIDs.append(conversation.id)
            try writeManifest(manifest)
        }
    }

    public func delete(id: UUID) throws {
        var manifest: Manifest
        switch try readDocument() {
        case .legacy(let conversations, _):
            guard conversations.contains(where: { $0.id == id }) else { return }
            manifest = try migrateIfNeeded()
        case .manifest(var current):
            // Keep deletion ordering explicit: a second deletion waits until the
            // first can safely reclaim its complete input.
            try resumePendingDeletions(&current)
            guard current.conversationIDs.contains(id) else { return }
            manifest = current
        }
        _ = try readConversation(id)
        manifest.conversationIDs.removeAll { $0 == id }
        manifest.pendingDeletionIDs = [id]
        // The durable pending list makes interrupted cleanup retryable after reopening.
        try writeManifest(manifest)
        try finishDeletion(&manifest)
    }

    private func resumePendingDeletions(_ manifest: inout Manifest) throws {
        guard !(manifest.pendingDeletionIDs ?? []).isEmpty else { return }
        try finishDeletion(&manifest)
    }

    private func finishDeletion(_ manifest: inout Manifest) throws {
        var referenced = Set<String>()
        for id in manifest.conversationIDs {
            // Validate every remaining record and blob before reclaiming any data.
            let record = try readRecord(id, verifyBlobs: true)
            referenced.formUnion(record.messages.flatMap(\.attachments).map(\.digest))
        }
        let records = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        let unreferencedRecords = records.filter {
            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent).map {
                !manifest.conversationIDs.contains($0)
            } == true
        }
        // Interrupted writes can leave a record outside the manifest. Validate
        // these too before removing anything; damaged data is never garbage.
        for url in unreferencedRecords {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), url.lastPathComponent == conversationURL(id).lastPathComponent else {
                throw CocoaError(.fileReadCorruptFile)
            }
            _ = try readRecord(id, verifyBlobs: true)
        }
        let blobs = directory.appendingPathComponent("blobs")
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.isRegularFileKey]) }
        catch CocoaError.fileReadNoSuchFile { files = [] }
        let unreferencedBlobs = files.filter { !referenced.contains($0.lastPathComponent) && Self.isDigest($0.lastPathComponent) }
        for file in unreferencedBlobs {
            try requireRegularFile(file)
            guard Self.digest(try Data(contentsOf: file)) == file.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
        }
        // All validation finishes before the first destructive operation.
        for file in unreferencedRecords { try removeIfPresent(file) }
        try removeIfPresent(legacyURL)
        for file in unreferencedBlobs { try removeIfPresent(file) }
        manifest.pendingDeletionIDs = nil
        try writeManifest(manifest)
    }

    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { return }
    }

    /// Actual encoded bytes on disk, not a token estimate or a provider price.
    /// Blob bytes include retained, currently unreferenced content.
    public func storageMetrics() throws -> ConversationStorageMetrics {
        let document = try readDocument()
        let ids: [UUID]
        switch document {
        case .legacy(let conversations, _): ids = conversations.map(\.id)
        case .manifest(let manifest): ids = manifest.conversationIDs
        }
        let manifestBytes = try sizeIfPresent(fileURL)
        let recordBytes = try ids.reduce(0) { try $0 + sizeIfPresent(conversationURL($1)) }
        let blobs = directory.appendingPathComponent("blobs")
        let blobFiles: [URL]
        do { blobFiles = try FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey]) }
        catch CocoaError.fileReadNoSuchFile { blobFiles = [] }
        let attachmentBytes = try blobFiles.reduce(0) { try $0 + sizeIfPresent($1) }
        return ConversationStorageMetrics(conversationCount: ids.count, manifestBytes: manifestBytes,
            conversationBytes: recordBytes, attachmentBytes: attachmentBytes, legacyBytes: try sizeIfPresent(legacyURL))
    }

    private func readDocument() throws -> StoreDocument {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch CocoaError.fileReadNoSuchFile { return .legacy([], nil) }
        let decoder = JSONDecoder()
        switch try decoder.decode(Header.self, from: data).version {
        case 1:
            let document = try decoder.decode(LegacyDocument.self, from: data)
            try validateIDs(document.conversations.map(\.id))
            return .legacy(document.conversations, data)
        case 2:
            let manifest = try decoder.decode(Manifest.self, from: data)
            try validateIDs(manifest.conversationIDs)
            let pending = manifest.pendingDeletionIDs ?? []
            try validateIDs(pending)
            guard Set(pending).isDisjoint(with: manifest.conversationIDs) else { throw CocoaError(.fileReadCorruptFile) }
            return .manifest(manifest)
        case let version: throw ConversationStoreError.unsupportedVersion(version)
        }
    }

    private func migrateIfNeeded() throws -> Manifest {
        switch try readDocument() {
        case .manifest(let manifest): return manifest
        case .legacy(let conversations, let original):
            // Until the manifest commits, reads use the complete original file.
            // Retrying an interrupted migration safely overwrites only staged records.
            for conversation in conversations { try writeConversation(conversation) }
            if let original {
                if FileManager.default.fileExists(atPath: legacyURL.path) {
                    guard try Data(contentsOf: legacyURL) == original else { throw CocoaError(.fileWriteFileExists) }
                } else {
                    try original.write(to: legacyURL, options: .atomic)
                }
            }
            let manifest = Manifest(version: 2, conversationIDs: conversations.map(\.id))
            try writeManifest(manifest)
            return manifest
        }
    }

    private func validateIDs(_ ids: [UUID]) throws {
        var seen = Set<UUID>()
        for id in ids where !seen.insert(id).inserted { throw ConversationStoreError.duplicateConversationID(id) }
    }

    private func conversationURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private func writeConversation(_ conversation: Conversation) throws {
        let messages = try conversation.messages.map { message in
            let attachments = try message.attachments.map { attachment in
                let data: Data
                let kind: String
                switch attachment.content {
                case .image(let bytes): data = bytes; kind = "image"
                case .text(let text): data = Data(text.utf8); kind = "text"
                }
                let digest = Self.digest(data)
                let url = blobURL(digest)
                if FileManager.default.fileExists(atPath: url.path) {
                    try validateBlob(digest, byteCount: data.count, verifyContents: false)
                } else {
                    try write(data, to: url)
                }
                return StoredAttachment(id: attachment.id, name: attachment.name, mimeType: attachment.mimeType,
                                        kind: kind, digest: digest, byteCount: data.count)
            }
            return StoredMessage(id: message.id, role: message.role, text: message.text,
                                 createdAt: message.createdAt, attachments: attachments)
        }
        let record = StoredConversation(version: 1, id: conversation.id, title: conversation.title, messages: messages,
            createdAt: conversation.createdAt, updatedAt: conversation.updatedAt, pendingRequestID: conversation.pendingRequestID)
        try write(try JSONEncoder().encode(record), to: conversationURL(conversation.id))
    }

    private func readConversation(_ id: UUID) throws -> Conversation {
        let record = try readRecord(id, verifyBlobs: false)
        let messages = try record.messages.map { message in
            let attachments = try message.attachments.map { attachment in
                // A persisted digest is a filename, so validate it before resolving any path.
                let data = try Data(contentsOf: blobURL(attachment.digest))
                guard data.count == attachment.byteCount, Self.digest(data) == attachment.digest else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let content: AgentAttachment.Content
                switch attachment.kind {
                case "image": content = .image(data)
                case "text":
                    guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                    content = .text(text)
                default: throw CocoaError(.fileReadCorruptFile)
                }
                return AgentAttachment(id: attachment.id, name: attachment.name, mimeType: attachment.mimeType, content: content)
            }
            return AgentMessage(id: message.id, role: message.role, text: message.text,
                                createdAt: message.createdAt, attachments: attachments)
        }
        return Conversation(id: record.id, title: record.title, messages: messages, createdAt: record.createdAt,
                            updatedAt: record.updatedAt, pendingRequestID: record.pendingRequestID)
    }

    private func readRecord(_ id: UUID, verifyBlobs: Bool) throws -> StoredConversation {
        let url = conversationURL(id)
        try requireRegularFile(url)
        let record = try JSONDecoder().decode(StoredConversation.self, from: Data(contentsOf: url))
        guard record.version == 1 else { throw ConversationStoreError.unsupportedVersion(record.version) }
        guard record.id == id else { throw CocoaError(.fileReadCorruptFile) }
        for attachment in record.messages.flatMap(\.attachments) {
            guard attachment.kind == "image" || attachment.kind == "text" else { throw CocoaError(.fileReadCorruptFile) }
            let data = try validateBlob(attachment.digest, byteCount: attachment.byteCount, verifyContents: verifyBlobs)
            if verifyBlobs, attachment.kind == "text", let data, String(data: data, encoding: .utf8) == nil {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return record
    }

    @discardableResult
    private func validateBlob(_ digest: String, byteCount: Int, verifyContents: Bool) throws -> Data? {
        guard Self.isDigest(digest), byteCount >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let url = blobURL(digest)
        try requireRegularFile(url)
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == byteCount else { throw CocoaError(.fileReadCorruptFile) }
        if verifyContents {
            let data = try Data(contentsOf: url)
            guard data.count == byteCount, Self.digest(data) == digest else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
        return nil
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func blobURL(_ digest: String) -> URL {
        directory.appendingPathComponent("blobs").appendingPathComponent(digest)
    }

    private func writeManifest(_ manifest: Manifest) throws {
        let sorted = Manifest(version: manifest.version, conversationIDs: manifest.conversationIDs.sorted { $0.uuidString < $1.uuidString }, pendingDeletionIDs: manifest.pendingDeletionIDs)
        try write(try JSONEncoder().encode(sorted), to: fileURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func sizeIfPresent(_ url: URL) throws -> Int {
        do { return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        catch CocoaError.fileReadNoSuchFile { return 0 }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func recentFirst(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.updatedAt > rhs.updatedAt
    }

    private enum StoreDocument { case legacy([Conversation], Data?), manifest(Manifest) }
    private struct Header: Decodable { let version: Int }
    private struct LegacyDocument: Codable { let version: Int; let conversations: [Conversation] }
    private struct Manifest: Codable { let version: Int; var conversationIDs: [UUID]; var pendingDeletionIDs: [UUID]? = nil }
    private struct StoredConversation: Codable {
        let version: Int
        let id: UUID
        let title: String
        let messages: [StoredMessage]
        let createdAt: Date
        let updatedAt: Date
        let pendingRequestID: UUID?
    }
    private struct StoredMessage: Codable {
        let id: UUID
        let role: AgentRole
        let text: String
        let createdAt: Date
        let attachments: [StoredAttachment]
    }
    private struct StoredAttachment: Codable {
        let id: UUID
        let name: String
        let mimeType: String
        let kind: String
        let digest: String
        let byteCount: Int
    }
}

public struct ConversationStorageMetrics: Sendable, Equatable {
    public let conversationCount: Int
    public let manifestBytes: Int
    public let conversationBytes: Int
    public let attachmentBytes: Int
    public let legacyBytes: Int
}
