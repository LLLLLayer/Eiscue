import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

@MainActor final class RunCoordinatorTests: XCTestCase {
    func testChatAdmissionPersistsBeforeCompletionAndUsesNoDeviceTools() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanUp() }
        let engine = CoordinatorEngine()
        var toolCount = -1
        fixture.model.runCoordinator = RunCoordinator(model: fixture.model) { _, _, tools in
            toolCount = tools.count
            return AgentClient(engine: engine)
        }
        fixture.model.draft = "Hello"
        await fixture.model.sendMessage()
        let captured = await engine.lastRequest()
        let request = try XCTUnwrap(captured)
        let run = try XCTUnwrap(fixture.model.runs.first)
        let saved = try await fixture.model.repository.load()
        XCTAssertEqual(toolCount, 0)
        XCTAssertEqual(request.mode, .message)
        XCTAssertEqual(request.requestID, saved.first?.messages.first?.id)
        XCTAssertEqual(request.systemPrompt, SystemPromptBuilder.build(scope: .chat, skill: nil))
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.submission, .accepted)
        XCTAssertEqual(run.promptVersion, SystemPromptBuilder.version)
        XCTAssertNil(saved.first?.pendingRequestID)
        XCTAssertEqual(saved.first?.messages.last?.text, "Hello back")
        XCTAssertNil(fixture.model.activeRun)
    }

    func testEventPersistenceFailureCancelsRuntimeBeforeReleasingBusyState() async throws {
        let repository = CoordinatorStore()
        let fixture = try CoordinatorFixture(repository: repository)
        defer { fixture.cleanUp() }
        let engine = CoordinatorEngine()
        fixture.model.runCoordinator = RunCoordinator(model: fixture.model) { _, _, _ in AgentClient(engine: engine) }
        fixture.model.draft = "Hello"
        await fixture.model.sendMessage()
        let cancelled = await engine.wasCancelled()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(fixture.model.runs.first?.state, .failed)
        XCTAssertEqual(fixture.model.runs.first?.stopCause, .eventSaveFailed)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertNil(fixture.model.activeRun)
        XCTAssertTrue(fixture.model.selectedConversation?.messages.allSatisfy { $0.role == .user } == true)
    }

    func testEventPersistenceFailureAlsoRetainsFailureFromRuntimeCancellationClose() async throws {
        let fixture = try CoordinatorFixture(repository: CoordinatorStore())
        defer { fixture.cleanUp() }
        let engine = CoordinatorEngine(close: { throw AgentError.cleanupFailed("Contract close failed") })
        fixture.model.runCoordinator = RunCoordinator(model: fixture.model) { _, _, _ in AgentClient(engine: engine) }
        fixture.model.draft = "Hello"
        await fixture.model.sendMessage()
        let run = try XCTUnwrap(fixture.model.runs.first)
        XCTAssertEqual(run.state, .failed)
        XCTAssertEqual(run.stopCause, .eventSaveFailed)
        let storageError = String(format: String(localized: "error.save_run", table: "Runtime"),
                                  fixture.model.safeError(CocoaError(.fileWriteNoPermission)))
        XCTAssertEqual(run.cleanupFailure, "Contract close failed\n" + storageError)
        XCTAssertEqual(fixture.model.errorMessage, storageError)
        XCTAssertFalse(fixture.model.isBusy)
    }

    func testStaleStopDoesNotCancelCurrentRun() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanUp() }
        let engine = CoordinatorEngine()
        fixture.model.configuredAgent = AgentClient(engine: engine)
        let run = RunRecord(id: UUID(), conversationID: UUID(), requestID: UUID(), startedAt: .now,
                            scope: .chat, model: "fixture", skill: nil, state: .running, detail: "Working", events: [])
        fixture.model.runCoordinator.publish(run)
        await fixture.model.stop(expectedRunID: UUID())
        let cancelled = await engine.wasCancelled()
        XCTAssertFalse(cancelled)
        XCTAssertFalse(fixture.model.stopRequested)
        XCTAssertEqual(fixture.model.activeRun?.detail, "Working")
    }
}

@MainActor private struct CoordinatorFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "eiscue.coordinator.\(UUID().uuidString)"
    let preferences: UserDefaults
    let credentials: CredentialStore
    let model: AppModel
    init(repository: (any ConversationRepository)? = nil) throws {
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        credentials = CredentialStore(service: suite)
        model = AppModel(storageDirectory: directory, preferences: preferences, repository: repository, credentialStore: credentials)
        model.isLoading = false; model.hapticsEnabled = false
        var settings = ModelSettings(); settings.model = "fixture"
        try model.saveModelSettings(settings, newKey: "isolated-fixture-key")
    }
    func cleanUp() {
        try? credentials.deleteAll()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// App integration fake uses the same durable lifecycle as the shared contract fixture.
actor CoordinatorEngine: AgentEngine {
    private let base: ContractFakeEngine
    private var request: AgentRequest?
    private var cancelled = false
    var availability: AgentAvailability { .ready }
    init(store: ContractFakeStore = ContractFakeStore(), tool: AgentTool? = nil,
         close: @escaping @Sendable () async throws -> Void = {}) {
        base = ContractFakeEngine(store: store, tool: tool, answerText: "Hello back", close: close)
    }
    func lastRequest() -> AgentRequest? { request }
    func wasCancelled() -> Bool { cancelled }
    func run(request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        self.request = request
        return try await base.run(request: request)
    }
    func recover(conversationID: UUID) async throws -> AgentRecovery { try await base.recover(conversationID: conversationID) }
    func toolResult(conversationID: UUID, requestID: UUID, toolCallID: String) async throws -> AgentToolCompletion? {
        try await base.toolResult(conversationID: conversationID, requestID: requestID, toolCallID: toolCallID)
    }
    func cancel() async throws { cancelled = true; try await base.cancel() }
    func cancel(conversationID: UUID) async throws { cancelled = true; try await base.cancel(conversationID: conversationID) }
    func removeConversation(id: UUID) async throws { try await base.removeConversation(id: id) }
}

private actor CoordinatorStore: ConversationRepository {
    private var saved: Conversation?
    func load() async throws -> [Conversation] { saved.map { [$0] } ?? [] }
    func save(_ conversation: Conversation) async throws {
        if conversation.messages.contains(where: { $0.role == .assistant }) { throw CocoaError(.fileWriteNoPermission) }
        saved = conversation
    }
    func delete(id: UUID) async throws { saved = nil }
}
