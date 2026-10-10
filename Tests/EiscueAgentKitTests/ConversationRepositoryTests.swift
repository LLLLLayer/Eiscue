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
    let original = Data(#"{"version":2,"conversations":[]}"#.utf8)
    try original.write(to: directory.fileURL)
    let repository = JSONConversationRepository(fileURL: directory.fileURL)
    await #expect(throws: ConversationStoreError.unsupportedVersion(2)) {
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
