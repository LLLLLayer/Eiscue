import Foundation
import Testing
import EiscueAgentKit

@Test func persistenceRoundTripSurvivesRepositoryRecreation() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let instant = Date(timeIntervalSinceReferenceDate: 800_000_000.125)
    let conversation = Conversation(
        title: "设备任务",
        messages: [
            AgentMessage(role: .user, text: "打开设置\n查看设备信息", createdAt: instant),
            AgentMessage(role: .assistant, text: "A stored historical reply", createdAt: instant),
        ],
        createdAt: instant,
        updatedAt: instant.addingTimeInterval(1)
    )
    try await JSONConversationRepository(fileURL: directory.fileURL).save(conversation)
    let restored = try await JSONConversationRepository(fileURL: directory.fileURL).load()
    #expect(restored == [conversation])
}

@Test func updateOrderingAndDeletionArePersisted() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    var older = Conversation(title: "Earlier", createdAt: Date(timeIntervalSince1970: 100))
    let newer = Conversation(title: "Later", createdAt: Date(timeIntervalSince1970: 200))
    try await repository.save(newer)
    try await repository.save(older)
    #expect(try await repository.load().map(\.id) == [newer.id, older.id])

    older.title = "Updated"
    older.updatedAt = Date(timeIntervalSince1970: 300)
    try await repository.save(older)
    #expect(try await repository.load() == [older, newer])
    try await repository.delete(id: newer.id)
    #expect(try await JSONConversationRepository(fileURL: directory.fileURL).load() == [older])
    try await repository.delete(id: older.id)
    #expect(try await repository.load().isEmpty)
}

@Test func missingFileIsEmptyAndReadDoesNotCreateIt() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    #expect(try await repository.load().isEmpty)
    try await repository.delete(id: UUID())
    #expect(!FileManager.default.fileExists(atPath: directory.fileURL.path))
}

@Test func malformedStoreRejectsReadsAndMutationsWithoutOverwriting() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let original = Data("{ truncated user data".utf8)
    try original.write(to: directory.fileURL)
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    await #expect(throws: DecodingError.self) { try await repository.load() }
    await #expect(throws: DecodingError.self) {
        try await repository.save(Conversation(title: "Must not overwrite"))
    }
    await #expect(throws: DecodingError.self) { try await repository.delete(id: UUID()) }
    #expect(try Data(contentsOf: directory.fileURL) == original)
}

@Test func unsupportedStoreVersionIsPreserved() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let original = Data(#"{"version":999,"conversations":[]}"#.utf8)
    try original.write(to: directory.fileURL)
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    await #expect(throws: ConversationStoreError.unsupportedVersion(999)) {
        try await repository.save(Conversation())
    }
    #expect(try Data(contentsOf: directory.fileURL) == original)
}

@Test func writeFailurePropagatesToCaller() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    // A regular file cannot serve as the parent directory of a store.
    try Data("existing file".utf8).write(to: directory.fileURL)
    let impossibleURL = directory.fileURL.appendingPathComponent("conversations.json")
    let repository = JSONConversationRepository(fileURL: impossibleURL)
    await #expect(throws: (any Error).self) {
        try await repository.save(Conversation())
    }
    #expect(try String(contentsOf: directory.fileURL, encoding: .utf8) == "existing file")
}

@Test func concurrentSavesOnOneRepositoryPreserveEveryConversation() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    let conversations = (0..<12).map { Conversation(title: "Task \($0)") }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for conversation in conversations {
            group.addTask { try await repository.save(conversation) }
        }
        try await group.waitForAll()
    }
    #expect(try await Set(repository.load().map(\.id)) == Set(conversations.map(\.id)))
}

@Test func legacyMigrationPreservesBytesAndPendingAttachments() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let attachment = AgentAttachment(name: "photo.png", mimeType: "image/png", content: .image(Data(repeating: 5, count: 4096)))
    let originalConversation = Conversation(title: "Legacy", messages: [.init(role: .user, text: "Photo", attachments: [attachment])], pendingRequestID: UUID())
    let original = try legacyData([originalConversation])
    try original.write(to: directory.fileURL)
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    #expect(try await repository.load() == [originalConversation])
    #expect(try Data(contentsOf: directory.fileURL) == original)
    var changed = originalConversation; changed.title = "Changed"
    try await repository.save(changed)
    #expect(try Data(contentsOf: directory.fileURL.appendingPathExtension("legacy-v1")) == original)
    #expect(try await JSONConversationRepository(fileURL: directory.fileURL).load() == [changed])
    let metrics = try await repository.storageMetrics()
    #expect(metrics.conversationCount == 1)
    #expect(metrics.attachmentBytes == 4096)
    #expect(metrics.legacyBytes == original.count)
    #expect(metrics.conversationBytes < 4096)
}

@Test func updatesTouchOnlyOneConversationAndAttachmentsDeduplicate() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let attachment = AgentAttachment(name: "photo.png", mimeType: "image/png", content: .image(Data(repeating: 7, count: 65_536)))
    var first = Conversation(title: "First", messages: [.init(role: .user, text: "One", attachments: [attachment])])
    let second = Conversation(title: "Second", messages: [.init(role: .user, text: "Two", attachments: [attachment])])
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    try await repository.save(first)
    try await repository.save(second)
    let record = directory.fileURL.appendingPathExtension("store").appendingPathComponent(second.id.uuidString.lowercased() + ".json")
    let untouchedBytes = try Data(contentsOf: record)
    let untouchedDate = try record.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let manifest = try Data(contentsOf: directory.fileURL)
    first.title = "Edited"
    try await repository.save(first)
    #expect(try Data(contentsOf: record) == untouchedBytes)
    #expect(try record.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == untouchedDate)
    #expect(try Data(contentsOf: directory.fileURL) == manifest)
    let metrics = try await repository.storageMetrics()
    #expect(metrics.attachmentBytes == 65_536)
    #expect(metrics.conversationBytes < 4096)
    #expect(try await repository.load().count == 2)
}

@Test func interruptedMigrationUsesOriginalAndRetriesWithoutLosingRecords() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let first = Conversation(title: "First")
    let second = Conversation(title: "Second")
    let original = try legacyData([first, second])
    try original.write(to: directory.fileURL)
    let staging = directory.fileURL.appendingPathExtension("store")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    // Simulate a partial write from a process that died before committing the manifest.
    try Data("partial".utf8).write(to: staging.appendingPathComponent(first.id.uuidString.lowercased() + ".json"))
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    #expect(try await Set(repository.load().map(\.id)) == Set([first.id, second.id]))
    try await repository.save(second)
    #expect(try await Set(repository.load().map(\.id)) == Set([first.id, second.id]))
    #expect(try Data(contentsOf: directory.fileURL.appendingPathExtension("legacy-v1")) == original)
}

@Test func missingBlobRejectsLoadAndSaveWithoutReplacingHistory() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    let attachment = AgentAttachment(name: "notes.txt", mimeType: "text/plain", content: .text("original bytes"))
    let conversation = Conversation(messages: [.init(role: .user, text: "", attachments: [attachment])])
    try await repository.save(conversation)
    let store = directory.fileURL.appendingPathExtension("store")
    let blobs = try FileManager.default.contentsOfDirectory(at: store.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
    try FileManager.default.removeItem(at: #require(blobs.first))
    let record = store.appendingPathComponent(conversation.id.uuidString.lowercased() + ".json")
    let original = try Data(contentsOf: record)
    await #expect(throws: (any Error).self) { try await repository.load() }
    await #expect(throws: (any Error).self) { try await repository.save(conversation) }
    #expect(try Data(contentsOf: record) == original)
}

@Test func duplicateLegacyIDsRejectMigrationBeforeWritingAnything() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let conversation = Conversation(title: "Original")
    let original = try legacyData([conversation, conversation])
    try original.write(to: directory.fileURL)
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    await #expect(throws: ConversationStoreError.duplicateConversationID(conversation.id)) {
        try await repository.save(Conversation())
    }
    #expect(try Data(contentsOf: directory.fileURL) == original)
    #expect(!FileManager.default.fileExists(atPath: directory.fileURL.appendingPathExtension("store").path))
}

@Test func invalidPendingDeletionCannotRemoveAnActiveRecord() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    let conversation = Conversation(title: "Keep")
    try await repository.save(conversation)
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.fileURL)) as? [String: Any])
    manifest["pendingDeletionIDs"] = [conversation.id.uuidString]
    let invalid = try JSONSerialization.data(withJSONObject: manifest)
    try invalid.write(to: directory.fileURL)
    let record = directory.fileURL.appendingPathExtension("store").appendingPathComponent(conversation.id.uuidString.lowercased() + ".json")
    let originalRecord = try Data(contentsOf: record)
    await #expect(throws: (any Error).self) { try await repository.delete(id: conversation.id) }
    #expect(try Data(contentsOf: record) == originalRecord)
    #expect(try Data(contentsOf: directory.fileURL) == invalid)
}

@Test func failedMigrationLeavesLegacyAuthoritative() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let conversation = Conversation(title: "Preserve me")
    let original = try legacyData([conversation])
    try original.write(to: directory.fileURL)
    try Data("directory blocked".utf8).write(to: directory.fileURL.appendingPathExtension("store"))
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    await #expect(throws: (any Error).self) { try await repository.save(Conversation()) }
    #expect(try Data(contentsOf: directory.fileURL) == original)
    #expect(try await repository.load() == [conversation])
}

@Test func deletionRetiresLegacyBackupAndReclaimsOnlyUnreferencedBlobs() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let shared = AgentAttachment(name: "shared", mimeType: "text/plain", content: .text("shared bytes"))
    let removed = AgentAttachment(name: "removed", mimeType: "text/plain", content: .text("private removed bytes"))
    let first = Conversation(title: "Remove", messages: [.init(role: .user, text: "", attachments: [shared, removed])])
    let second = Conversation(title: "Keep", messages: [.init(role: .user, text: "", attachments: [shared])])
    try legacyData([first, second]).write(to: directory.fileURL)
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    try await repository.delete(id: first.id)
    #expect(try await repository.load() == [second])
    #expect(!FileManager.default.fileExists(atPath: directory.fileURL.appendingPathExtension("legacy-v1").path))
    #expect(try await repository.storageMetrics().attachmentBytes == shared.byteCount)
    try await repository.delete(id: second.id)
    #expect(try await repository.storageMetrics().attachmentBytes == 0)
    #expect(try await repository.load().isEmpty)
}

@Test func deletionCleanupValidatesRemainingRecordsAndRetriesAfterReopening() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let attachment = AgentAttachment(name: "private", mimeType: "text/plain", content: .text("private bytes"))
    let first = Conversation(title: "Delete", messages: [.init(role: .user, text: "", attachments: [attachment])])
    let second = Conversation(title: "Retain")
    let original = try legacyData([first, second])
    try original.write(to: directory.fileURL)
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    try await repository.save(second)
    let store = directory.fileURL.appendingPathExtension("store")
    let retainedURL = store.appendingPathComponent(second.id.uuidString.lowercased() + ".json")
    let retained = try Data(contentsOf: retainedURL)
    try Data("damaged".utf8).write(to: retainedURL)
    await #expect(throws: (any Error).self) { try await repository.delete(id: first.id) }
    #expect(try await repository.storageMetrics().attachmentBytes == attachment.byteCount)
    #expect(try Data(contentsOf: directory.fileURL.appendingPathExtension("legacy-v1")) == original)
    let pendingManifest = try Data(contentsOf: directory.fileURL)
    await #expect(throws: ConversationStoreError.deletionPending) { try await repository.save(first) }
    #expect(try Data(contentsOf: directory.fileURL) == pendingManifest)
    for _ in 0..<2 {
        let reopened = JSONConversationRepository(fileURL: directory.fileURL)
        await #expect(throws: (any Error).self) { try await reopened.load() }
        await #expect(throws: ConversationStoreError.deletionPending) { try await reopened.save(first) }
        await #expect(throws: (any Error).self) { try await reopened.save(Conversation(title: "Must wait for cleanup")) }
        #expect(try Data(contentsOf: directory.fileURL) == pendingManifest)
        #expect(try await reopened.storageMetrics().attachmentBytes == attachment.byteCount)
        #expect(try Data(contentsOf: directory.fileURL.appendingPathExtension("legacy-v1")) == original)
    }
    try retained.write(to: retainedURL)
    let reopened = JSONConversationRepository(fileURL: directory.fileURL)
    #expect(try await reopened.load() == [second])
    // Reopening finishes cleanup without needing the already-hidden conversation ID.
    #expect(try await reopened.storageMetrics().attachmentBytes == 0)
    #expect(try await reopened.load() == [second])
    #expect(!FileManager.default.fileExists(atPath: directory.fileURL.appendingPathExtension("legacy-v1").path))
}

@Test func unrelatedSaveReconcilesPendingDeletionBeforeWriting() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let shared = AgentAttachment(name: "shared", mimeType: "text/plain", content: .text("Keep shared bytes"))
    let privateFile = AgentAttachment(name: "private", mimeType: "text/plain", content: .text("Delete private bytes"))
    let removed = Conversation(title: "Delete", messages: [.init(role: .user, text: "", attachments: [shared, privateFile])])
    var remaining = Conversation(title: "Keep", messages: [.init(role: .user, text: "", attachments: [shared])])
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    try legacyData([removed, remaining]).write(to: directory.fileURL)
    try await repository.save(remaining)
    let store = directory.fileURL.appendingPathExtension("store")
    let remainingURL = store.appendingPathComponent(remaining.id.uuidString.lowercased() + ".json")
    let intact = try Data(contentsOf: remainingURL)
    try Data("damaged".utf8).write(to: remainingURL)
    await #expect(throws: (any Error).self) { try await repository.delete(id: removed.id) }
    try intact.write(to: remainingURL)
    remaining.title = "Updated after cleanup"
    let reopened = JSONConversationRepository(fileURL: directory.fileURL)
    try await reopened.save(remaining)
    #expect(try await reopened.load() == [remaining])
    #expect(try await reopened.storageMetrics().attachmentBytes == shared.byteCount)
    #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent(removed.id.uuidString.lowercased() + ".json").path))
    #expect(!FileManager.default.fileExists(atPath: directory.fileURL.appendingPathExtension("legacy-v1").path))
}

@Test func repeatedCleanupFailureKeepsReadableRecordsAndBlocksNewMutations() async throws {
    let directory = try StoreDirectory()
    defer { directory.remove() }
    let removed = Conversation(title: "Delete")
    let remaining = Conversation(title: "Keep", messages: [.init(role: .user, text: "Readable history")])
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    try await repository.save(removed)
    try await repository.save(remaining)
    let store = directory.fileURL.appendingPathExtension("store")
    let remainingURL = store.appendingPathComponent(remaining.id.uuidString.lowercased() + ".json")
    let intact = try Data(contentsOf: remainingURL)
    // A non-file at a blob path forces cleanup to fail after record removal.
    let obstruction = store.appendingPathComponent("blobs").appendingPathComponent(String(repeating: "a", count: 64))
    try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await repository.delete(id: removed.id) }
    #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent(removed.id.uuidString.lowercased() + ".json").path))
    let pending = try Data(contentsOf: directory.fileURL)
    for _ in 0..<2 {
        let reopened = JSONConversationRepository(fileURL: directory.fileURL)
        await #expect(throws: (any Error).self) { try await reopened.load() }
        await #expect(throws: ConversationStoreError.deletionPending) { try await reopened.save(removed) }
        await #expect(throws: (any Error).self) { try await reopened.save(Conversation(title: "New")) }
        await #expect(throws: (any Error).self) { try await reopened.delete(id: remaining.id) }
        #expect(try Data(contentsOf: remainingURL) == intact)
        #expect(try Data(contentsOf: directory.fileURL) == pending)
    }
    try FileManager.default.removeItem(at: obstruction)
    let reopened = JSONConversationRepository(fileURL: directory.fileURL)
    #expect(try await reopened.load() == [remaining])
    #expect(try await reopened.load() == [remaining])
    let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.fileURL)) as? [String: Any])
    #expect(manifest["pendingDeletionIDs"] == nil)
}

private func legacyData(_ conversations: [Conversation]) throws -> Data {
    struct Legacy: Encodable { let version = 1; let conversations: [Conversation] }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
    return try encoder.encode(Legacy(conversations: conversations))
}

private struct StoreDirectory {
    let url: URL
    var fileURL: URL { url.appendingPathComponent("conversations.json") }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
