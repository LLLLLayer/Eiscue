import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor final class ConversationManagementTests: XCTestCase {
    func testRenamePersistsWithoutChangingMessagesOrActivityOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let message = AgentMessage(role: .user, text: "Keep this message")
        let original = Conversation(title: "Old title", messages: [message], createdAt: Date(timeIntervalSince1970: 42),
                                    pendingRequestID: message.id)
        fixture.model.conversations = [original]
        await fixture.model.renameConversation(original.id, title: "  My conversation \n")
        var expected = original; expected.title = "My conversation"
        XCTAssertEqual(fixture.model.conversations, [expected])
        let saved = try await fixture.model.repository.load()
        XCTAssertEqual(saved, [expected])
        await fixture.model.renameConversation(original.id, title: " \n ")
        XCTAssertEqual(fixture.model.conversations, [expected])
    }

    func testBatchPinKeepsRelativeOrderAndPersists() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let chats = (1...3).map { Conversation(title: "\($0)", createdAt: Date(timeIntervalSince1970: Double($0))) }
        fixture.model.conversations = chats
        let selection: Set<UUID> = [chats[0].id, chats[2].id]
        fixture.model.setConversationsPinned(selection, pinned: true)
        XCTAssertEqual(fixture.model.sortedConversations.map(\.id), [chats[2].id, chats[0].id, chats[1].id])
        let restored = ConversationOrdering(preferences: fixture.preferences)
        XCTAssertEqual(restored.pinnedIDs, selection)
        XCTAssertEqual(restored.sorted(chats).map(\.id), fixture.model.sortedConversations.map(\.id))
        fixture.model.setConversationsPinned(selection, pinned: false)
        XCTAssertEqual(fixture.model.sortedConversations.map(\.id), [chats[2].id, chats[0].id, chats[1].id])
        XCTAssertFalse(chats.contains { fixture.model.isConversationPinned($0.id) })
        fixture.model.isSaving = true
        fixture.model.setConversationsPinned(selection, pinned: true)
        XCTAssertFalse(chats.contains { fixture.model.isConversationPinned($0.id) })
    }

    func testBatchDeleteProtectsBusyStateAndRemovesOnlySelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let chats = (1...3).map { Conversation(title: "\($0)") }
        fixture.model.conversations = chats
        for chat in chats { try await fixture.model.repository.save(chat) }
        fixture.model.selectedConversationID = chats[0].id
        fixture.preferences.set(chats[0].id.uuidString, forKey: "selectedConversationID")
        fixture.model.draft = "Draft"
        let selection: Set<UUID> = [chats[0].id, chats[2].id]
        fixture.model.isSaving = true
        await fixture.model.deleteConversations(selection)
        await fixture.model.renameConversation(chats[0].id, title: "Ignored")
        XCTAssertEqual(fixture.model.conversations, chats)
        fixture.model.isSaving = false
        fixture.model.isLoading = true
        await fixture.model.deleteConversations(selection)
        XCTAssertEqual(fixture.model.conversations, chats)
        let savedWhileLoading = try await fixture.model.repository.load()
        XCTAssertEqual(Set(savedWhileLoading.map(\.id)), Set(chats.map(\.id)))
        fixture.model.isLoading = false
        await fixture.model.deleteConversations(selection)
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.conversations, [chats[1]])
        XCTAssertNil(fixture.model.selectedConversationID)
        XCTAssertNil(fixture.preferences.string(forKey: "selectedConversationID"))
        XCTAssertTrue(fixture.model.draft.isEmpty)
        let saved = try await fixture.model.repository.load()
        XCTAssertEqual(saved, [chats[1]])
    }

    func testBatchDeleteCascadesPersistedRunsAndRuntimeWithoutConfiguredAgent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let chats = (1...3).map { Conversation(title: "\($0)") }
        let records = [record(for: chats[0]), record(for: chats[0]), record(for: chats[1]), record(for: chats[2])]
        fixture.model.conversations = chats
        fixture.model.runs = [records[0], records[2], records[3]]
        fixture.model.interruptedConversationIDs = Set(chats.map(\.id))
        for chat in chats { try await fixture.model.repository.save(chat) }
        for record in records { try await fixture.model.journal.save(record) }
        let runtimeFiles = try chats.map { try fixture.seedRuntime(for: $0.id) }
        XCTAssertNil(fixture.model.configuredAgent)

        await fixture.model.deleteConversations([chats[0].id, chats[2].id])

        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertNil(fixture.model.configuredAgent, "Deletion must not configure or open an agent session.")
        XCTAssertEqual(fixture.model.conversations.map(\.id), [chats[1].id])
        XCTAssertEqual(fixture.model.runs.map(\.id), [records[2].id])
        XCTAssertEqual(fixture.model.interruptedConversationIDs, [chats[1].id])
        let saved = try await fixture.model.repository.load()
        XCTAssertEqual(saved.map(\.id), [chats[1].id])
        let journal = try await fixture.model.journal.load()
        XCTAssertEqual(journal.records.map(\.id), [records[2].id])
        XCTAssertTrue(journal.failures.isEmpty)
        for index in [0, 2] {
            for file in runtimeFiles[index] { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        }
        for file in runtimeFiles[1] { XCTAssertEqual(try Data(contentsOf: file), Data("runtime fixture".utf8)) }
    }

    func testDeleteRemovesOnlyDamagedRunsWithKnownOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let deleted = Conversation(title: "Delete"), kept = Conversation(title: "Keep")
        let remembered = record(for: deleted), persisted = record(for: deleted), unrelated = record(for: kept)
        fixture.model.conversations = [deleted, kept]
        fixture.model.runs = [remembered, unrelated]
        for chat in [deleted, kept] { try await fixture.model.repository.save(chat) }
        for record in [remembered, persisted, unrelated] { try await fixture.model.journal.save(record) }
        let damaged = Data("{damaged".utf8)
        try damaged.write(to: fixture.runFile(remembered.id))
        try damaged.write(to: fixture.runFile(unrelated.id))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(persisted)) as? [String: Any])
        payload["state"] = "unsupported-state"
        try JSONSerialization.data(withJSONObject: payload).write(to: fixture.runFile(persisted.id))
        let before = try await fixture.model.journal.load()
        XCTAssertTrue(before.records.isEmpty)
        XCTAssertEqual(before.failures.count, 3)

        await fixture.model.delete(deleted)

        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.conversations.map(\.id), [kept.id])
        XCTAssertEqual(fixture.model.runs.map(\.id), [unrelated.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runFile(remembered.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runFile(persisted.id).path))
        XCTAssertEqual(try Data(contentsOf: fixture.runFile(unrelated.id)), damaged)
        let after = try await fixture.model.journal.load()
        XCTAssertTrue(after.records.isEmpty)
        XCTAssertEqual(after.failures.count, 1, "Loading must still preserve and report unrelated damaged history.")
    }

    func testDeleteStopsBeforeCleanupWhenDamagedRunOwnershipIsUnknown() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let chat = Conversation(title: "Keep until cleanup is possible")
        let run = record(for: chat)
        fixture.model.conversations = [chat]
        fixture.model.runs = [run]
        try await fixture.model.repository.save(chat)
        try await fixture.model.journal.save(run)
        let runtimeFiles = try fixture.seedRuntime(for: chat.id)
        let unknownFile = fixture.runFile(UUID())
        let damaged = Data("{unknown owner".utf8)
        try damaged.write(to: unknownFile)

        await fixture.model.delete(chat)

        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertFalse(fixture.model.isSaving)
        XCTAssertEqual(fixture.model.conversations, [chat])
        XCTAssertEqual(fixture.model.runs.map(\.id), [run.id])
        let saved = try await fixture.model.repository.load()
        XCTAssertEqual(saved, [chat])
        let journal = try await fixture.model.journal.load()
        XCTAssertEqual(journal.records.map(\.id), [run.id])
        XCTAssertEqual(journal.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: unknownFile), damaged)
        for file in runtimeFiles { XCTAssertEqual(try Data(contentsOf: file), Data("runtime fixture".utf8)) }
    }

    func testBatchDeleteStopsAtFailureAndKeepsUndeletedSelection() async throws {
        let chats = (1...3).map { Conversation(title: "\($0)") }
        let repository = FailingDeletionRepository(chats: chats, failureID: chats[1].id)
        let fixture = try Fixture(repository: repository)
        defer { fixture.cleanUp() }
        fixture.model.conversations = chats
        let records = chats.map { record(for: $0) }
        fixture.model.runs = records
        for record in records { try await fixture.model.journal.save(record) }
        await fixture.model.deleteConversations(Set(chats.map(\.id)))
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertFalse(fixture.model.isSaving)
        XCTAssertEqual(fixture.model.conversations.map(\.id), [chats[1].id, chats[2].id])
        let remaining = try await repository.load()
        XCTAssertEqual(remaining.map(\.id), [chats[1].id, chats[2].id])
        XCTAssertEqual(fixture.model.runs.map(\.id), [records[1].id, records[2].id])
        let persistedRuns = try await fixture.model.journal.load().records
        XCTAssertEqual(persistedRuns.map(\.id), [records[2].id], "The failing conversation retains its row for retry after earlier cleanup steps.")
    }

    private func record(for conversation: Conversation) -> RunRecord {
        RunRecord(id: UUID(), conversationID: conversation.id, requestID: UUID(), startedAt: Date(),
                  scope: .chat, model: "fixture", skill: nil, state: .completed, detail: "", events: [])
    }

    @MainActor private struct Fixture {
        let directory: URL
        let suite: String
        let preferences: UserDefaults
        let model: AppModel
        init(repository: (any ConversationRepository)? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "ConversationManagementTests.\(UUID().uuidString)"
            preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            model = AppModel(storageDirectory: directory, preferences: preferences, repository: repository)
            model.isLoading = false
        }
        func runFile(_ id: UUID) -> URL { directory.appendingPathComponent("Runs/\(id.uuidString).json") }
        func seedRuntime(for conversationID: UUID) throws -> [URL] {
            let runtime = directory.appendingPathComponent("Runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
            return try ["", "-wal", "-shm"].map { suffix in
                let url = runtime.appendingPathComponent(conversationID.uuidString.lowercased() + ".sqlite" + suffix)
                try Data("runtime fixture".utf8).write(to: url)
                return url
            }
        }
        func cleanUp() {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private actor FailingDeletionRepository: ConversationRepository {
    var chats: [Conversation]
    let failureID: UUID
    init(chats: [Conversation], failureID: UUID) { self.chats = chats; self.failureID = failureID }
    func load() async throws -> [Conversation] { chats }
    func save(_ conversation: Conversation) async throws {}
    func delete(id: UUID) async throws {
        if id == failureID { throw CocoaError(.fileWriteUnknown) }
        chats.removeAll { $0.id == id }
    }
}
