import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor final class MessageSubmissionTests: XCTestCase {
    func testSendMovesTextAndAttachmentsBeforePersistenceReturns() async throws {
        let store = SuspendedConversationStore()
        let model = makeModel(store)
        let originalSession = model.composerSessionID
        let attachment = AgentAttachment(name: "note.txt", mimeType: "text/plain", content: .text("A note"))
        model.draft = "  Hello  "
        model.draftAttachments = [attachment]
        let sending = Task { await model.sendMessage() }
        await store.waitForSave()
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.draftAttachments.isEmpty)
        XCTAssertNotEqual(model.composerSessionID, originalSession)
        XCTAssertTrue(model.isSubmittingMessage)
        XCTAssertEqual(model.selectedConversation?.messages.last?.text, "Hello")
        XCTAssertEqual(model.selectedConversation?.messages.last?.attachments, [attachment])
        await store.rejectSave()
        await sending.value
        XCTAssertEqual(model.draft, "  Hello  ", "An unsaved message should return the exact draft.")
        XCTAssertEqual(model.draftAttachments, [attachment])
        XCTAssertNil(model.selectedConversationID)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertFalse(model.isSubmittingMessage)
    }

    func testLocalSaveFailureDoesNotOverwriteNewTypingOrOldConversation() async {
        let store = SuspendedConversationStore()
        let model = makeModel(store)
        let original = Conversation(title: "Existing", messages: [AgentMessage(role: .assistant, text: "Earlier reply")])
        model.conversations = [original]
        model.selectedConversationID = original.id
        model.draft = "First draft"
        let sending = Task { await model.sendMessage() }
        await store.waitForSave()
        model.draft = "New typing while saving"
        await store.rejectSave()
        await sending.value
        XCTAssertEqual(model.draft, "New typing while saving")
        XCTAssertEqual(model.selectedConversation?.messages, original.messages)
        XCTAssertEqual(model.selectedConversationID, original.id)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
    }

    private func makeModel(_ store: SuspendedConversationStore) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "eiscue.submission-tests.\(UUID().uuidString)")!
        let model = AppModel(storageDirectory: directory, preferences: defaults, repository: store)
        model.isLoading = false; model.agentAvailability = .ready; model.hapticsEnabled = false
        return model
    }
}

private actor SuspendedConversationStore: ConversationRepository {
    private var saveEntered = false
    private var admission: CheckedContinuation<Void, Never>?
    private var pendingSave: CheckedContinuation<Void, Error>?
    func load() async throws -> [Conversation] { [] }
    func delete(id: UUID) async throws {}
    func save(_ conversation: Conversation) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pendingSave = continuation
            saveEntered = true
            admission?.resume(); admission = nil
        }
    }
    func waitForSave() async {
        if saveEntered { return }
        await withCheckedContinuation { admission = $0 }
    }
    func rejectSave() {
        pendingSave?.resume(throwing: CocoaError(.fileWriteNoPermission)); pendingSave = nil
    }
}
