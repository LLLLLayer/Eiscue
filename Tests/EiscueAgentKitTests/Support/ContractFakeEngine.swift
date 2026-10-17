import Foundation
import EiscueAgentKit

actor ContractEvidence {
    private(set) var count = 0
    private(set) var closed = false
    func perform() { count += 1 }
    func close() { closed = true }
}

/// Independent host-test fake: its shared store represents persisted state across engine replacements.
actor ContractFakeStore {
    struct State: Sendable {
        var messages: [AgentMessage] = []
        var accepted = Set<UUID>()
        var pending: UUID?
        var unsafeWasStarted = false
        var results: [UUID: AgentToolCompletion] = [:]
    }
    private var values: [UUID: State] = [:]
    private var owners: [UUID: UUID] = [:]
    func acquire(_ id: UUID, owner: UUID) throws {
        guard owners[id] == nil else { throw AgentError.busy }
        owners[id] = owner
    }
    func release(_ id: UUID, owner: UUID) { if owners[id] == owner { owners[id] = nil } }
    func requireUnowned(_ id: UUID) throws { guard owners[id] == nil else { throw AgentError.busy } }

    func seed(_ request: AgentRequest, unsafeWasStarted: Bool) throws {
        var state = State()
        state.messages = [AgentMessage(id: request.requestID, role: .user, text: request.prompt)]
        state.accepted = [request.requestID]; state.pending = request.requestID; state.unsafeWasStarted = unsafeWasStarted
        values[request.conversationID] = state
    }
    func admit(_ request: AgentRequest) throws -> (UUID, Bool, Bool) {
        var state = values[request.conversationID] ?? State()
        if request.mode == .resume {
            guard let pending = state.pending else { throw AgentError.nothingToResume }
            return (pending, false, state.unsafeWasStarted)
        }
        guard state.pending == nil else { throw AgentError.interruptedRun }
        if state.accepted.contains(request.requestID) { return (request.requestID, true, false) }
        state.messages.append(AgentMessage(id: request.requestID, role: .user, text: request.prompt))
        state.accepted.insert(request.requestID); state.pending = request.requestID
        values[request.conversationID] = state
        return (request.requestID, false, false)
    }
    func record(_ completion: AgentToolCompletion, conversationID: UUID, requestID: UUID) {
        values[conversationID]?.results[requestID] = completion
    }
    func settle(_ id: UUID, answer: AgentMessage?) {
        values[id]?.pending = nil
        if let answer { values[id]?.messages.append(answer) }
    }
    func recover(_ id: UUID) -> AgentRecovery {
        let state = values[id] ?? State()
        return AgentRecovery(messages: state.messages, hasInterruptedRun: state.pending != nil, acceptedRequestIDs: state.accepted)
    }
    func result(_ id: UUID, requestID: UUID, toolCallID: String) -> AgentToolCompletion? {
        guard let result = values[id]?.results[requestID], result.call.id == toolCallID else { return nil }
        return result
    }
    func remove(_ id: UUID) throws { try requireUnowned(id); values[id] = nil }
}

actor ContractFakeEngine: AgentEngine {
    let store: ContractFakeStore
    let tool: AgentTool?
    let answerText: String
    let close: @Sendable () async throws -> Void
    private var admitting = false
    private var admissionWaiters: [CheckedContinuation<Void, Never>] = []
    var task: Task<Void, Never>?
    var cleanupError: AgentError?
    var conversationID: UUID?
    var availability: AgentAvailability { .ready }
    init(store: ContractFakeStore = ContractFakeStore(), tool: AgentTool? = nil, answerText: String = "Done", close: @escaping @Sendable () async throws -> Void = {}) {
        self.store = store; self.tool = tool; self.answerText = answerText; self.close = close
    }
    func run(request: AgentRequest) async throws -> AsyncThrowingStream<EiscueAgentKit.AgentEvent, Error> {
        guard task == nil, !admitting else { throw AgentError.busy }
        admitting = true; conversationID = request.conversationID
        defer { admitting = false; for waiter in admissionWaiters { waiter.resume() }; admissionWaiters = [] }
        let ownership = UUID()
        do {
            try await store.acquire(request.conversationID, owner: ownership)
            let (input, duplicate, interrupted) = try await store.admit(request)
            let (stream, continuation) = AsyncThrowingStream<EiscueAgentKit.AgentEvent, Error>.makeStream()
            continuation.yield(.requestAccepted(request.requestID))
            if duplicate {
                await store.release(request.conversationID, owner: ownership); conversationID = nil
                continuation.yield(.finished(.completed)); continuation.finish(); return stream
            }
            cleanupError = nil
            task = Task { await self.execute(request, input: input, interrupted: interrupted, ownership: ownership, continuation: continuation) }
            return stream
        } catch {
            await store.release(request.conversationID, owner: ownership); conversationID = nil
            throw error
        }
    }
    private func execute(_ request: AgentRequest, input: UUID, interrupted: Bool, ownership: UUID,
                         continuation: AsyncThrowingStream<EiscueAgentKit.AgentEvent, Error>.Continuation) async {
        let call = AgentToolCall(id: "contract-call", name: tool?.name ?? "", arguments: [:])
        var outcome = AgentRunOutcome.completed
        do {
            if let tool {
                let result: AgentToolResult
                if interrupted { result = .init(content: [], outcome: .interrupted) }
                else {
                    continuation.yield(.toolStarted(call))
                    result = try await tool.execute([:])
                }
                let completion = AgentToolCompletion(call: call, result: result)
                await store.record(completion, conversationID: request.conversationID, requestID: input)
                continuation.yield(.toolFinished(completion))
                if result.outcome == .unknown { outcome = .stopped(.outcomeUnknown(toolName: call.name)) }
            }
        } catch AgentToolError.outcomeUnknown {
            let completion = AgentToolCompletion(call: call, result: .init(content: [], outcome: .unknown))
            await store.record(completion, conversationID: request.conversationID, requestID: input)
            continuation.yield(.toolFinished(completion))
            outcome = .stopped(.outcomeUnknown(toolName: call.name))
        } catch { outcome = .cancelled }
        let answer = outcome == .completed ? AgentMessage(role: .assistant, text: answerText) : nil
        await store.settle(request.conversationID, answer: answer)
        if let answer { continuation.yield(.message(answer)) }
        do {
            try await Task { try await close() }.value
            await store.release(request.conversationID, owner: ownership)
        }
        catch {
            cleanupError = .cleanupFailed(error.localizedDescription)
            continuation.yield(.cleanupFailed(error.localizedDescription))
        }
        continuation.yield(.finished(outcome)); continuation.finish()
        task = nil; conversationID = nil
    }
    func recover(conversationID: UUID) async throws -> AgentRecovery { await store.recover(conversationID) }
    func toolResult(conversationID: UUID, requestID: UUID, toolCallID: String) async throws -> AgentToolCompletion? {
        await store.result(conversationID, requestID: requestID, toolCallID: toolCallID)
    }
    func cancel() async throws {
        if admitting { await withCheckedContinuation { admissionWaiters.append($0) } }
        task?.cancel(); await task?.value
        if let cleanupError { throw cleanupError }
    }
    func cancel(conversationID: UUID) async throws {
        if let current = self.conversationID, current != conversationID { throw AgentError.busy }
        try await cancel(); try await store.requireUnowned(conversationID); await store.settle(conversationID, answer: nil)
    }
    func removeConversation(id: UUID) async throws {
        guard task == nil, !admitting else { throw AgentError.busy }; try await store.remove(id)
    }
}
