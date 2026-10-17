import EiscueAgentKit
import Foundation
import XCTest

/// Both the common base and the adapter actually injected by RunCoordinatorTests
/// must obey the same public engine boundary. Scripted invalid-event fixtures
/// remain separate so fault injection does not redefine that boundary.
final class AppEngineContractTests: XCTestCase {
    func testReplacementCannotOwnTheConversationUntilCancellationClosesIt() async throws {
        for implementation in AppContractImplementation.allCases {
            let fixture = AppContractFixture(implementation, slow: true)
            let request = AgentRequest(conversationID: UUID(), prompt: "Wait")
            let reader = Task { try await appContractEvents(fixture.client.run(request: request)) }
            try await appContractEventually { await fixture.evidence.count == 1 }
            do {
                _ = try await appContractEvents(fixture.reopen().run(request: .init(conversationID: request.conversationID, prompt: "Competing input")))
                XCTFail("A replacement engine must not acquire the live conversation.")
            } catch { XCTAssertEqual(error as? AgentError, .busy) }
            try await fixture.client.cancel()
            _ = try await reader.value
            let closed = await fixture.evidence.closed
            XCTAssertTrue(closed)
            try await fixture.reopen().removeConversation(id: request.conversationID)
        }
    }

    func testAdmissionIsIdempotentAcrossReplacementAndIncludesCommittedResults() async throws {
        for implementation in AppContractImplementation.allCases {
            let fixture = AppContractFixture(implementation)
            let request = AgentRequest(conversationID: UUID(), prompt: "One input")
            let events = try await appContractEvents(fixture.client.run(request: request))
            XCTAssertEqual(events.first, .requestAccepted(request.requestID))
            XCTAssertEqual(events.last, .finished(.completed))
            let recovery = try await fixture.reopen().recover(conversationID: request.conversationID)
            XCTAssertEqual(recovery.messages.first?.id, request.requestID)
            XCTAssertTrue(recovery.acceptedRequestIDs.contains(request.requestID))
            let retry = try await appContractEvents(fixture.reopen().run(request: request))
            XCTAssertEqual(retry.first, .requestAccepted(request.requestID))
            let after = try await fixture.reopen().recover(conversationID: request.conversationID)
            XCTAssertEqual(after.messages, recovery.messages)
            let executions = await fixture.evidence.count
            XCTAssertEqual(executions, 1)
            let result = try await fixture.reopen().toolResult(conversationID: request.conversationID,
                                                              requestID: request.requestID, toolCallID: "contract-call")
            XCTAssertEqual(result?.result.content, [.image(data: Data([1, 2, 3]), mimeType: "image/png")])
            XCTAssertEqual(result?.result.outcome, .succeeded)
        }
    }

    func testRecoveryDoesNoWorkAndOnlyExplicitResumeContinuesPendingInput() async throws {
        for implementation in AppContractImplementation.allCases {
            let fixture = AppContractFixture(implementation)
            let request = AgentRequest(conversationID: UUID(), prompt: "Pending")
            try await fixture.store.seed(request, unsafeWasStarted: false)
            let recovery = try await fixture.client.recover(conversationID: request.conversationID)
            XCTAssertTrue(recovery.hasInterruptedRun)
            XCTAssertTrue(recovery.acceptedRequestIDs.contains(request.requestID))
            _ = try await fixture.reopen().recover(conversationID: request.conversationID)
            do {
                _ = try await appContractEvents(fixture.client.run(request: .init(conversationID: request.conversationID, prompt: "New input")))
                XCTFail("New input must not implicitly continue unfinished work.")
            } catch { XCTAssertEqual(error as? AgentError, .interruptedRun) }
            let before = await fixture.evidence.count
            XCTAssertEqual(before, 0)
            let resumed = try await appContractEvents(fixture.client.run(request: .init(conversationID: request.conversationID, prompt: "", mode: .resume)))
            XCTAssertEqual(resumed.last, .finished(.completed))
            let count = await fixture.evidence.count
            XCTAssertEqual(count, 1)
        }
    }

    func testInterruptedUnsafeToolIsReportedWithoutReplay() async throws {
        for implementation in AppContractImplementation.allCases {
            let fixture = AppContractFixture(implementation)
            let request = AgentRequest(conversationID: UUID(), prompt: "Unsafe")
            try await fixture.store.seed(request, unsafeWasStarted: true)
            await fixture.evidence.perform()
            _ = try await fixture.client.recover(conversationID: request.conversationID)
            let events = try await appContractEvents(fixture.client.run(request: .init(conversationID: request.conversationID, prompt: "", mode: .resume)))
            XCTAssertTrue(events.contains { if case .toolFinished(let result) = $0 { result.result.outcome == .interrupted } else { false } })
            XCTAssertEqual(events.last, .finished(.completed))
            let count = await fixture.evidence.count
            XCTAssertEqual(count, 1)
        }
    }

    func testUnknownOutcomeStopsBeforeAnAnswerAndRemainsReadable() async throws {
        for implementation in AppContractImplementation.allCases {
            let fixture = AppContractFixture(implementation, unknown: true)
            let request = AgentRequest(conversationID: UUID(), prompt: "Uncertain")
            let events = try await appContractEvents(fixture.client.run(request: request))
            XCTAssertEqual(events.last, .finished(.stopped(.outcomeUnknown(toolName: "contract_action"))))
            XCTAssertFalse(events.contains { if case .message = $0 { true } else { false } })
            let result = try await fixture.reopen().toolResult(conversationID: request.conversationID,
                                                              requestID: request.requestID, toolCallID: "contract-call")
            XCTAssertEqual(result?.result.outcome, .unknown)
            let count = await fixture.evidence.count
            XCTAssertEqual(count, 1)
        }
    }

    func testReturnedUnknownOutcomeAlsoStopsBeforeAnAnswer() async throws {
        for implementation in AppContractImplementation.allCases {
            let fixture = AppContractFixture(implementation, returnedUnknown: true)
            let request = AgentRequest(conversationID: UUID(), prompt: "Uncertain result")
            let events = try await appContractEvents(fixture.client.run(request: request))
            XCTAssertEqual(events.last, .finished(.stopped(.outcomeUnknown(toolName: "contract_action"))))
            XCTAssertFalse(events.contains { if case .message = $0 { true } else { false } })
        }
    }

    func testCancellationWaitsForExecutionAndCloseBeforeRecoveryOrRemoval() async throws {
        for implementation in AppContractImplementation.allCases {
            let fixture = AppContractFixture(implementation, slow: true)
            let request = AgentRequest(conversationID: UUID(), prompt: "Wait")
            let reader = Task { try await appContractEvents(fixture.client.run(request: request)) }
            try await appContractEventually { await fixture.evidence.count == 1 }
            try await fixture.client.cancel()
            let closed = await fixture.evidence.closed
            XCTAssertTrue(closed)
            let events = try await reader.value
            XCTAssertEqual(events.last, .finished(.cancelled))
            let recovery = try await fixture.reopen().recover(conversationID: request.conversationID)
            XCTAssertFalse(recovery.hasInterruptedRun)
            try await fixture.reopen().removeConversation(id: request.conversationID)
            let removed = try await fixture.reopen().recover(conversationID: request.conversationID)
            XCTAssertTrue(removed.messages.isEmpty)
        }
    }

    func testCloseFailureIsPropagatedSeparatelyFromCancellation() async throws {
        for implementation in AppContractImplementation.allCases {
            let fixture = AppContractFixture(implementation, slow: true, failClose: true)
            let request = AgentRequest(conversationID: UUID(), prompt: "Wait")
            let reader = Task { try await appContractEvents(fixture.client.run(request: request)) }
            try await appContractEventually { await fixture.evidence.count == 1 }
            do { try await fixture.client.cancel(); XCTFail("Failed close must remain observable.") }
            catch { XCTAssertEqual(error as? AgentError, .cleanupFailed("Contract close failed")) }
            let events = try await reader.value
            XCTAssertTrue(events.contains(.cleanupFailed("Contract close failed")))
            XCTAssertEqual(events.last, .finished(.cancelled))
            do { try await fixture.client.cancel(); XCTFail("Late cancellation must retain the latest close failure.") }
            catch { XCTAssertEqual(error as? AgentError, .cleanupFailed("Contract close failed")) }
        }
    }
}

private enum AppContractImplementation: CaseIterable, Sendable { case base, coordinator }

private struct AppContractFixture: Sendable {
    let client: AgentClient
    let evidence: ContractEvidence
    let store: ContractFakeStore
    let reopen: @Sendable () -> AgentClient
    init(_ implementation: AppContractImplementation, slow: Bool = false, unknown: Bool = false, returnedUnknown: Bool = false, failClose: Bool = false) {
        let evidence = ContractEvidence(), store = ContractFakeStore()
        self.evidence = evidence; self.store = store
        let tool = AgentTool(name: "contract_action", description: "Unsafe fixture action", parameters: ["type": "object"]) { _ in
            await evidence.perform()
            if slow { try await Task.sleep(for: .seconds(30)) }
            if unknown { throw AgentToolError.outcomeUnknown }
            if returnedUnknown { return .init(content: [], outcome: .unknown) }
            return .image(Data([1, 2, 3]), mimeType: "image/png")
        }
        let close: @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(50)); await evidence.close()
            if failClose { throw AgentError.cleanupFailed("Contract close failed") }
        }
        reopen = {
            switch implementation {
            case .base: AgentClient(engine: ContractFakeEngine(store: store, tool: tool, close: close))
            case .coordinator: AgentClient(engine: CoordinatorEngine(store: store, tool: tool, close: close))
            }
        }
        client = reopen()
    }
}

private func appContractEvents(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
private func appContractEventually(_ condition: @Sendable () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < end {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentError.runtime("App contract fixture timed out")
}
