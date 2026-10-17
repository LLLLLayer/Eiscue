import EiscueAgentKit
import EiscueDeviceKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor final class MessageSubmissionTests: XCTestCase {
    func testDeviceControlDefaultsOnAndExplicitOffSurvivesRelaunch() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model(Conversation(title: "Preference"))
        XCTAssertTrue(model.allowsDeviceControl)
        XCTAssertEqual(model.newRunScope, .chat, "Unavailable devices must not block ordinary chat.")
        model.deviceStatus = .ready(capabilities: [.screenshot, .tap])
        XCTAssertEqual(model.newRunScope, .control)
        model.allowsDeviceControl = false
        let reopened = fixture.model(Conversation(title: "Relaunched"))
        reopened.deviceStatus = .ready(capabilities: [.screenshot, .tap])
        XCTAssertFalse(reopened.allowsDeviceControl)
        XCTAssertEqual(reopened.newRunScope, .chat)
    }

    func testConnectingDuringMessageSaveCannotWidenCapturedChatScope() async throws {
        let store = SuspendedConversationStore()
        let model = makeModel(store)
        defer { try? FileManager.default.removeItem(at: model.storageDirectory) }
        model.draft = "Hello"
        let sending = Task { await model.sendMessage() }
        await store.waitForSave()
        model.deviceStatus = .ready(capabilities: [.screenshot, .tap])
        model.currentScenePhase = .background // Inspect preparation without contacting a provider.
        await store.acceptSave()
        await sending.value
        XCTAssertEqual(model.runs.first?.scope, .chat)
        XCTAssertEqual(model.runs.first?.state, .interrupted)
    }

    func testDisconnectingDuringMessageSaveDoesNotDowngradeCapturedControlScope() async throws {
        let store = SuspendedConversationStore()
        let model = makeModel(store)
        defer { try? FileManager.default.removeItem(at: model.storageDirectory) }
        model.deviceStatus = .ready(capabilities: [.screenshot, .tap])
        model.modelSettings.supportsImages = true
        model.draft = "Open settings"
        let sending = Task { await model.sendMessage() }
        await store.waitForSave()
        model.deviceStatus = .unavailable(reason: "Disconnected")
        await store.acceptSave()
        await sending.value
        XCTAssertEqual(model.runs.first?.scope, .control)
        XCTAssertEqual(model.runs.first?.state, .interrupted, "A lost connection must stop preparation, never fall back mid-request.")
    }

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
        XCTAssertEqual(model.selectedConversation?.pendingRequestID, model.selectedConversation?.messages.last?.id)
        let saving = await store.savingConversation()
        let saved = try XCTUnwrap(saving)
        XCTAssertEqual(saved.pendingRequestID, saved.messages.last?.id, "The pending ID and message must share the same atomic save.")
        await store.rejectSave()
        await sending.value
        XCTAssertEqual(model.draft, "  Hello  ", "An unsaved message should return the exact draft.")
        XCTAssertEqual(model.draftAttachments, [attachment])
        XCTAssertNil(model.selectedConversationID)
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertFalse(model.isSubmittingMessage)
        XCTAssertTrue(model.unsubmittedMessageIDs.isEmpty)
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

    func testSavedMessageWithoutJournalRequiresExplicitRetryWithSameID() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = AgentMessage(role: .user, text: "Saved just before the process exited")
        let conversation = Conversation(title: "Pending", messages: [message], pendingRequestID: message.id)
        try await fixture.store.save(conversation)
        let model = fixture.model(conversation)
        await model.recoverSelectedConversation()
        XCTAssertTrue(model.needsRecovery)
        XCTAssertTrue(model.unsubmittedMessageIDs.contains(message.id))
        XCTAssertTrue(model.runs.isEmpty)
        model.draft = "A different request"
        await model.sendMessage()
        XCTAssertEqual(model.selectedConversation?.messages, [message], "New messages must not silently seed a pending request as history.")
        model.currentScenePhase = .background // Stop at preparation; this test never calls a provider.
        await model.continueInterruptedRun()
        XCTAssertEqual(model.runs.first?.requestID, message.id)
        XCTAssertEqual(model.runs.first?.submission, .pending)
        XCTAssertEqual(model.runs.first?.state, .interrupted)
        XCTAssertEqual(model.selectedConversation?.messages, [message])
    }

    func testLegacyOrphanIsRecoveredAndAbandonmentSurvivesReload() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = AgentMessage(role: .user, text: "Old version saved no pending marker")
        let conversation = Conversation(title: "Legacy", messages: [message])
        try await fixture.store.save(conversation)
        let model = fixture.model(conversation)
        await model.recoverSelectedConversation()
        XCTAssertEqual(model.selectedConversation?.pendingRequestID, message.id)
        XCTAssertTrue(model.needsRecovery)
        await model.abandonInterruptedRun()
        XCTAssertFalse(model.needsRecovery)
        XCTAssertNil(model.selectedConversation?.pendingRequestID)
        XCTAssertTrue(model.unsubmittedMessageIDs.contains(message.id))
        let conversations = try await fixture.store.load()
        let stored = try XCTUnwrap(conversations.first)
        let reopened = fixture.model(stored)
        reopened.runs = try await reopened.journal.load().records
        await reopened.recoverSelectedConversation()
        XCTAssertFalse(reopened.needsRecovery)
        XCTAssertTrue(reopened.unsubmittedMessageIDs.contains(message.id))
        XCTAssertEqual(reopened.runs.first?.submission, .abandoned)
    }

    func testRecoveryPersistsAdmissionBeforeRetriedRecoveryCanDuplicateMessage() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = AgentMessage(role: .user, text: "Accepted before its event reached the host")
        let reply = AgentMessage(role: .assistant, text: "Done")
        let conversation = Conversation(title: "Stale journal", messages: [message, message], pendingRequestID: message.id)
        try await fixture.store.save(conversation)
        let model = fixture.model(conversation, runtime: [message, reply])
        var record = RunRecord(id: UUID(), conversationID: conversation.id, requestID: message.id, startedAt: Date(),
                               scope: .chat, model: "fixture", skill: nil, state: .interrupted, detail: "", events: [])
        record.submission = .pending
        try await model.journal.save(record); model.runs = [record]
        for _ in 0..<3 { await model.recoverSelectedConversation() }
        XCTAssertEqual(model.selectedConversation?.messages, [message, reply])
        XCTAssertNil(model.selectedConversation?.pendingRequestID)
        XCTAssertFalse(model.unsubmittedMessageIDs.contains(message.id))
        let records = try await model.journal.load().records
        XCTAssertEqual(records.first?.submission, .accepted)
        let stored = try await fixture.store.load()
        XCTAssertNil(stored.first?.pendingRequestID)
        XCTAssertEqual(stored.first?.messages, [message, reply])
    }

    func testContinuingPausedRunRequiresPermissionAndPreservesOriginalScope() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = AgentMessage(role: .user, text: "Open display settings")
        let conversation = Conversation(title: "Paused", messages: [message])
        try await fixture.store.save(conversation)
        let model = fixture.model(conversation, runtime: [message])
        var paused = RunRecord(id: UUID(), conversationID: conversation.id, requestID: message.id, startedAt: Date(),
                               scope: .control, model: "fixture", skill: nil, state: .paused, detail: "Paused", events: [])
        paused.submission = .accepted; paused.pauseReason = .toolLimit
        try await model.journal.save(paused); model.runs = [paused]
        await model.recoverSelectedConversation()
        XCTAssertEqual(model.pausedRun?.id, paused.id)
        XCTAssertFalse(model.needsRecovery, "A safely settled pause has no pending runtime work to replay.")
        XCTAssertEqual(model.selectedConversation?.messages, [message], "Recovery must not continue automatically.")
        model.scope = .chat
        model.deviceStatus = .ready(capabilities: [.screenshot, .tap])
        model.modelSettings.supportsImages = true
        model.currentScenePhase = .background // Stop before credentials/provider access.
        await model.continueInterruptedRun()
        XCTAssertEqual(model.runs.map(\.id), [paused.id])
        XCTAssertEqual(model.selectedConversation?.messages, [message])
        XCTAssertEqual(model.errorMessage, String(localized: "run.enable_control_first", table: "Runtime"))
        model.allowsDeviceControl = true; model.errorMessage = nil
        await model.continueInterruptedRun()
        let next = try XCTUnwrap(model.runs.first)
        XCTAssertNotEqual(next.requestID, message.id)
        XCTAssertEqual(next.scope, .control)
        XCTAssertEqual(next.submission, .pending)
        XCTAssertEqual(next.state, .interrupted)
        XCTAssertEqual(model.selectedConversation?.messages.count, 2)
        XCTAssertEqual(model.selectedConversation?.messages.last?.id, next.requestID)
        XCTAssertEqual(model.selectedConversation?.messages.last?.text, String(localized: "run.paused.resume_prompt", table: "Runtime"))
        XCTAssertNil(model.pausedRun)
    }

    func testRecoveryRebuildsStaleAcceptedCacheFromMissingSQLiteAdmission() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = AgentMessage(role: .user, text: "The host cache claimed acceptance")
        let conversation = Conversation(title: "Stale accepted cache", messages: [message], pendingRequestID: message.id)
        try await fixture.store.save(conversation)
        let model = fixture.model(conversation)
        var record = RunRecord(id: UUID(), conversationID: conversation.id, requestID: message.id, startedAt: Date(),
                               scope: .chat, model: "fixture", skill: nil, state: .interrupted, detail: "", events: [])
        record.submission = .accepted
        try await model.journal.save(record); model.runs = [record]

        for _ in 0..<2 { await model.recoverSelectedConversation() }

        XCTAssertEqual(model.runs.first?.submission, .pending)
        XCTAssertEqual(model.selectedConversation?.pendingRequestID, message.id)
        XCTAssertTrue(model.unsubmittedMessageIDs.contains(message.id))
        XCTAssertTrue(model.needsRecovery)
        let saved = try await model.journal.load().records
        XCTAssertEqual(saved.first?.submission, .pending)
    }

    func testSQLiteAdmissionRepairsPendingCacheWithoutInferringItFromVisibleMessages() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = AgentMessage(role: .user, text: "Durably admitted, compacted from the visible runtime view")
        let conversation = Conversation(title: "Durable admission", messages: [message], pendingRequestID: message.id)
        try await fixture.store.save(conversation)
        let model = fixture.model(conversation, acceptedRequestIDs: [message.id])
        var record = RunRecord(id: UUID(), conversationID: conversation.id, requestID: message.id, startedAt: Date(),
                               scope: .chat, model: "fixture", skill: nil, state: .completed, detail: "", events: [])
        record.submission = .pending
        try await model.journal.save(record); model.runs = [record]

        await model.recoverSelectedConversation()

        XCTAssertEqual(model.runs.first?.submission, .accepted)
        XCTAssertNil(model.selectedConversation?.pendingRequestID)
        XCTAssertFalse(model.unsubmittedMessageIDs.contains(message.id))
        XCTAssertFalse(model.needsRecovery)
        XCTAssertEqual(model.selectedConversation?.messages, [message])
    }

    func testVisibleRuntimeMessageDoesNotOverrideMissingDurableAdmission() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = AgentMessage(role: .user, text: "Visible content is not an admission receipt")
        let conversation = Conversation(title: "No receipt", messages: [message], pendingRequestID: message.id)
        try await fixture.store.save(conversation)
        let model = fixture.model(conversation, runtime: [message], acceptedRequestIDs: [])

        await model.recoverSelectedConversation()

        XCTAssertEqual(model.selectedConversation?.pendingRequestID, message.id)
        XCTAssertTrue(model.unsubmittedMessageIDs.contains(message.id))
        XCTAssertTrue(model.needsRecovery)
    }

    func testOrphanedChatRetryDoesNotInheritEarlierControlTaskScope() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let old = AgentMessage(role: .user, text: "Earlier device task")
        let pending = AgentMessage(role: .user, text: "A plain chat message")
        let conversation = Conversation(title: "Pending", messages: [old, pending], pendingRequestID: pending.id)
        try await fixture.store.save(conversation)
        let model = fixture.model(conversation, runtime: [old])
        var priorRun = RunRecord(id: UUID(), conversationID: conversation.id, requestID: old.id, startedAt: Date(),
                                scope: .control, model: "fixture", skill: nil, state: .completed, detail: "", events: [])
        priorRun.submission = .accepted
        try await model.journal.save(priorRun); model.runs = [priorRun]
        model.deviceStatus = .ready(capabilities: [.screenshot, .tap])
        XCTAssertEqual(model.newRunScope, .control, "Fresh requests allow control, but a recovered orphan has no permission record.")
        model.currentScenePhase = .background // No provider or credentials involved.
        await model.continueInterruptedRun()
        XCTAssertEqual(model.runs.first?.requestID, pending.id)
        XCTAssertEqual(model.runs.first?.scope, .chat)
        XCTAssertEqual(model.runs.first?.submission, .pending)
        XCTAssertEqual(model.selectedConversation?.messages, [old, pending])
    }

    func testEndingPausedTaskClearsContinuationAndPersistsHistory() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.cleanUp() }
        let message = AgentMessage(role: .user, text: "A device task")
        let conversation = Conversation(title: "Paused", messages: [message])
        try await fixture.store.save(conversation)
        let model = fixture.model(conversation, runtime: [message])
        var paused = RunRecord(id: UUID(), conversationID: conversation.id, requestID: message.id, startedAt: Date(),
                               scope: .control, model: "fixture", skill: nil, state: .paused, detail: "Paused", events: [])
        paused.submission = .accepted; paused.pauseReason = .noProgress
        try await model.journal.save(paused); model.runs = [paused]
        await model.abandonInterruptedRun()
        XCTAssertNil(model.pausedRun)
        XCTAssertFalse(model.needsRecovery)
        XCTAssertEqual(model.selectedConversation?.messages, [message])
        let stored = try await model.journal.load().records
        XCTAssertEqual(stored.first?.state, .failed)
        XCTAssertNil(stored.first?.pauseReason)
        XCTAssertEqual(stored.first?.submission, .accepted)
    }

    func testConversationWithoutPendingFieldStillDecodes() throws {
        let conversation = Conversation(title: "Earlier schema")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation)) as? [String: Any])
        object.removeValue(forKey: "pendingRequestID")
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, conversation)
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
    private var acceptsFutureSaves = false
    private var admission: CheckedContinuation<Void, Never>?
    private var pendingSave: CheckedContinuation<Void, Error>?
    private var conversation: Conversation?
    func load() async throws -> [Conversation] { [] }
    func delete(id: UUID) async throws {}
    func save(_ conversation: Conversation) async throws {
        self.conversation = conversation
        if acceptsFutureSaves { return }
        try await withCheckedThrowingContinuation { continuation in
            pendingSave = continuation
            saveEntered = true
            admission?.resume(); admission = nil
        }
    }
    func savingConversation() -> Conversation? { conversation }
    func waitForSave() async {
        if saveEntered { return }
        await withCheckedContinuation { admission = $0 }
    }
    func rejectSave() {
        pendingSave?.resume(throwing: CocoaError(.fileWriteNoPermission)); pendingSave = nil
    }
    func acceptSave() {
        acceptsFutureSaves = true
        pendingSave?.resume(); pendingSave = nil
    }
}

@MainActor private struct RecoveryFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "eiscue.recovery-tests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let store: JSONConversationRepository

    init() throws {
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = JSONConversationRepository(fileURL: directory.appendingPathComponent("conversations.json"))
    }
    func model(_ conversation: Conversation, runtime: [AgentMessage] = [], acceptedRequestIDs: Set<UUID>? = nil) -> AppModel {
        let model = AppModel(storageDirectory: directory, preferences: preferences, repository: store)
        model.isLoading = false; model.agentAvailability = .ready; model.hapticsEnabled = false
        model.conversations = [conversation]; model.selectedConversationID = conversation.id
        model.configuredAgent = AgentClient(engine: RecoveryEngine(messages: runtime,
            acceptedRequestIDs: acceptedRequestIDs ?? Set(runtime.filter { $0.role == .user }.map(\.id))))
        return model
    }
    func cleanUp() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Read-only runtime snapshot injection. This fixture never admits requests.
private struct RecoveryEngine: AgentEngine {
    let messages: [AgentMessage]
    let acceptedRequestIDs: Set<UUID>
    var availability: AgentAvailability { get async { .unconfigured } }
    func recover(conversationID: UUID) async throws -> AgentRecovery {
        AgentRecovery(messages: messages, hasInterruptedRun: false, acceptedRequestIDs: acceptedRequestIDs)
    }
    func toolResult(conversationID: UUID, requestID: UUID, toolCallID: String) async throws -> AgentToolCompletion? { nil }
    func run(request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> { throw AgentError.unconfigured }
    func cancel() async throws {}
    func cancel(conversationID: UUID) async throws {}
    func removeConversation(id: UUID) async throws {}
}
