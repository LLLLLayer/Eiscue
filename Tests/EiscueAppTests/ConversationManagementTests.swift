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
        await fixture.model.deleteConversations(selection)
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.conversations, [chats[1]])
        XCTAssertNil(fixture.model.selectedConversationID)
        XCTAssertNil(fixture.preferences.string(forKey: "selectedConversationID"))
        XCTAssertTrue(fixture.model.draft.isEmpty)
        let saved = try await fixture.model.repository.load()
        XCTAssertEqual(saved, [chats[1]])
    }

    func testBatchDeleteStopsAtFailureAndKeepsUndeletedSelection() async throws {
        let chats = (1...3).map { Conversation(title: "\($0)") }
        let repository = FailingDeletionRepository(chats: chats, failureID: chats[1].id)
        let fixture = try Fixture(repository: repository)
        defer { fixture.cleanUp() }
        fixture.model.conversations = chats
        await fixture.model.deleteConversations(Set(chats.map(\.id)))
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertFalse(fixture.model.isSaving)
        XCTAssertEqual(fixture.model.conversations.map(\.id), [chats[1].id, chats[2].id])
        let remaining = try await repository.load()
        XCTAssertEqual(remaining.map(\.id), [chats[1].id, chats[2].id])
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
