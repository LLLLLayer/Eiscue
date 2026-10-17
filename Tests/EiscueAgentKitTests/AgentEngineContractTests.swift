import Foundation
import Testing
import PiDurableKit
@testable import EiscueAgentKit

/// These cases exercise the public boundary for both the Pi adapter and an independent
/// deterministic engine. New engines should be added to ContractEngine.allCases.
@Suite("Agent engine contracts")
struct AgentEngineContractTests {
    @Test(arguments: ContractEngine.allCases)
    func unknownToolOutcomeStopsWithoutAFinalModelAnswer(_ implementation: ContractEngine) async throws {
        let fixture = try await ContractFixture(implementation, unknown: true)
        defer { fixture.remove() }
        let request = AgentRequest(conversationID: UUID(), prompt: "Act")
        let events = try await contractCollect(fixture.client.run(request: request))
        #expect(events.last == .finished(.stopped(.outcomeUnknown(toolName: "contract_action"))))
        #expect(!events.contains { if case .message = $0 { true } else { false } })
        #expect(await fixture.evidence.count == 1)
        let result = try await fixture.reopen().toolResult(conversationID: request.conversationID, requestID: request.requestID, toolCallID: "contract-call")
        #expect(result?.result.outcome == .unknown)
    }

    @Test(arguments: ContractEngine.allCases)
    func cancellationPropagatesCloseFailuresSeparatelyFromItsOutcome(_ implementation: ContractEngine) async throws {
        let fixture = try await ContractFixture(implementation, slow: true, failClose: true)
        defer { fixture.remove() }
        let request = AgentRequest(conversationID: UUID(), prompt: "Wait")
        let reader = Task { try await contractCollect(fixture.client.run(request: request)) }
        try await contractEventually { await fixture.evidence.count == 1 }
        await #expect(throws: AgentError.cleanupFailed("Contract close failed")) { try await fixture.client.cancel() }
        #expect(await fixture.evidence.closed)
        let events = try await reader.value
        #expect(events.contains(.cleanupFailed("Contract close failed")))
        #expect(events.last == .finished(.cancelled))
        await #expect(throws: AgentError.cleanupFailed("Contract close failed")) { try await fixture.client.cancel() }
        await #expect(throws: AgentError.cleanupFailed("Contract close failed")) { try await fixture.client.cancel(conversationID: request.conversationID) }
    }

    @Test(arguments: ContractEngine.allCases)
    func admissionPersistsAcrossReopeningAndRequestIDsAreIdempotent(_ implementation: ContractEngine) async throws {
        let fixture = try await ContractFixture(implementation)
        defer { fixture.remove() }
        let request = AgentRequest(conversationID: UUID(), prompt: "One durable input")
        let first = try await contractCollect(fixture.client.run(request: request))
        #expect(first.first == .requestAccepted(request.requestID))
        #expect(first.last == .finished(.completed))
        let recovered = try await fixture.reopen().recover(conversationID: request.conversationID)
        #expect(recovered.messages.first?.id == request.requestID)
        #expect(recovered.acceptedRequestIDs.contains(request.requestID))
        let retry = try await contractCollect(fixture.reopen().run(request: request))
        #expect(retry.first == .requestAccepted(request.requestID))
        let after = try await fixture.reopen().recover(conversationID: request.conversationID)
        #expect(after.messages == recovered.messages)
        #expect(await fixture.evidence.count == 1)
        let tool = try await fixture.reopen().toolResult(conversationID: request.conversationID,
                                                        requestID: request.requestID, toolCallID: "contract-call")
        #expect(tool?.result.content == [.image(data: Data([1, 2, 3]), mimeType: "image/png")])
        #expect(tool?.result.outcome == .succeeded)
    }

    @Test(arguments: ContractEngine.allCases)
    func recoveryIsReadOnlyAndContinuationRequiresExplicitResume(_ implementation: ContractEngine) async throws {
        let fixture = try await ContractFixture(implementation)
        defer { fixture.remove() }
        let request = AgentRequest(conversationID: UUID(), prompt: "Queued work")
        try await fixture.seed(request, unsafeWasStarted: false)
        let before = try await fixture.client.recover(conversationID: request.conversationID)
        #expect(before.hasInterruptedRun)
        #expect(before.acceptedRequestIDs.contains(request.requestID))
        _ = try await fixture.reopen().recover(conversationID: request.conversationID)
        #expect(await fixture.evidence.count == 0)
        await #expect(throws: AgentError.interruptedRun) {
            try await contractCollect(fixture.client.run(request: .init(conversationID: request.conversationID, prompt: "Unrelated")))
        }
        #expect(await fixture.evidence.count == 0)
        let resumed = try await contractCollect(fixture.client.run(request: .init(conversationID: request.conversationID, prompt: "", mode: .resume)))
        #expect(resumed.last == .finished(.completed))
        #expect(await fixture.evidence.count == 1)
        #expect(try await !fixture.client.recover(conversationID: request.conversationID).hasInterruptedRun)
    }

    @Test(arguments: ContractEngine.allCases)
    func interruptedUnsafeToolsNeverReplay(_ implementation: ContractEngine) async throws {
        let fixture = try await ContractFixture(implementation)
        defer { fixture.remove() }
        let request = AgentRequest(conversationID: UUID(), prompt: "Unsafe action")
        try await fixture.seed(request, unsafeWasStarted: true)
        #expect(await fixture.evidence.count == 1)
        #expect(try await fixture.client.recover(conversationID: request.conversationID).hasInterruptedRun)
        #expect(await fixture.evidence.count == 1)
        let events = try await contractCollect(fixture.client.run(request: .init(conversationID: request.conversationID, prompt: "", mode: .resume)))
        #expect(events.last == .finished(.completed))
        #expect(events.contains { if case .toolFinished(let completion) = $0 { completion.result.outcome == .interrupted } else { false } })
        #expect(await fixture.evidence.count == 1)
    }

    @Test(arguments: ContractEngine.allCases)
    func cancellationWaitsForExecutionAndStorageClose(_ implementation: ContractEngine) async throws {
        let fixture = try await ContractFixture(implementation, slow: true)
        defer { fixture.remove() }
        let request = AgentRequest(conversationID: UUID(), prompt: "Wait")
        let reader = Task { try await contractCollect(fixture.client.run(request: request)) }
        try await contractEventually { await fixture.evidence.count == 1 }
        try await fixture.client.cancel()
        #expect(await fixture.evidence.closed)
        #expect(try await reader.value.last == .finished(.cancelled))
        #expect(try await !fixture.reopen().recover(conversationID: request.conversationID).hasInterruptedRun)
        try await fixture.reopen().removeConversation(id: request.conversationID)
        #expect(try await fixture.reopen().recover(conversationID: request.conversationID).messages.isEmpty)
    }
}

enum ContractEngine: String, CaseIterable, Sendable { case defaultEngine, fakeEngine }

private struct ContractFixture: Sendable {
    let implementation: ContractEngine
    let directory: URL
    let client: AgentClient
    let evidence: ContractEvidence
    let models: Models
    let faux: FauxProvider
    let store: ContractFakeStore
    let reopen: @Sendable () -> AgentClient

    init(_ implementation: ContractEngine, slow: Bool = false, unknown: Bool = false, failClose: Bool = false) async throws {
        self.implementation = implementation
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-contract-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let evidence = ContractEvidence(); self.evidence = evidence
        let store = ContractFakeStore(); self.store = store
        let models = Models(builtinProviders: false); let faux = FauxProvider()
        try await models.register(faux); self.models = models; self.faux = faux
        let tool = AgentTool(name: "contract_action", description: "Unsafe action", parameters: ["type": "object"]) { _ in
            await evidence.perform()
            if slow { try await Task.sleep(for: .seconds(30)) }
            if unknown { throw AgentToolError.outcomeUnknown }
            return .image(Data([1, 2, 3]), mimeType: "image/png")
        }
        let close: @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(50))
            await evidence.close()
            if failClose { throw AgentError.cleanupFailed("Contract close failed") }
        }
        switch implementation {
        case .defaultEngine:
            try await faux.respond { _, count in
                count == 1 ? FauxResponse(.toolCall("contract_action", [:], id: "contract-call")) : .text("Done")
            }
            let directory = directory
            let configuration = AgentConfiguration(api: .openAICompletions, baseURL: URL(string: "https://contract.invalid/v1")!, model: "contract", apiKey: "")
            reopen = {
                AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory, tools: [tool],
                    modelFactory: { (models, faux.model) }, closeOperation: { harness in
                        try await harness.close(); try await close()
                    }))
            }
        case .fakeEngine:
            reopen = { AgentClient(engine: ContractFakeEngine(store: store, tool: tool, close: close)) }
        }
        client = reopen()
    }

    func seed(_ request: AgentRequest, unsafeWasStarted: Bool) async throws {
        if implementation == .fakeEngine {
            try await store.seed(request, unsafeWasStarted: unsafeWasStarted)
            if unsafeWasStarted { await evidence.perform() }
            return
        }
        let evidence = evidence
        let action = PiDurableKit.Tool("contract_action", description: "Unsafe action", replay: .unsafe) { _ in
            await evidence.perform(); try await Task.sleep(for: .seconds(30)); return "Done"
        }
        let harness = try await Harness.open(.sqlite(at: directory.appendingPathComponent(request.conversationID.uuidString.lowercased() + ".sqlite")), models: models,
                                            extensions: [Extension("eiscue", tools: [action])], resume: false)
        let root = try await harness.root(agent: AgentChange(model: faux.model))
        try await root.submit(request.prompt, requestId: request.requestID.uuidString)
        if unsafeWasStarted {
            try await harness.resume()
            try await contractEventually { await evidence.count == 1 }
        }
        try await harness.close()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@discardableResult private func contractCollect(_ stream: AsyncThrowingStream<EiscueAgentKit.AgentEvent, Error>) async throws -> [EiscueAgentKit.AgentEvent] {
    var events: [EiscueAgentKit.AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
private func contractEventually(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentError.runtime("Contract fixture timed out")
}
