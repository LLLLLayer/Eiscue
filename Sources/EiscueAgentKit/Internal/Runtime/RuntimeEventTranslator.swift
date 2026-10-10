import Foundation
import PiDurableKit

actor RuntimeEventTranslator {
    private let conversationID: UUID
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let secret: String
    private var entries: Set<EntryID>
    private var calls: [String: AgentToolCall] = [:]
    private var completedCalls = Set<String>()
    private var blocks: [Int: String] = [:]

    init(conversationID: UUID, snapshot: PiDurableKit.AgentEvent.Snapshot,
         continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation, secret: String) {
        self.conversationID = conversationID
        self.continuation = continuation
        self.secret = secret
        entries = Set(snapshot.entries.map(\.id))
        for entry in snapshot.entries {
            for block in entry.assistantMessage?.content ?? [] {
                if case .toolCall(let call) = block {
                    calls[call.id] = AgentToolCall(id: call.id, name: call.name,
                        arguments: (try? AgentJSONValue.from(call.arguments)) ?? .object([:]))
                }
            }
        }
    }

    func receive(_ event: PiDurableKit.AgentEvent) {
        switch event {
        case .snapshot(let snapshot):
            for entry in snapshot.entries { receiveEntry(entry) }
            if let message = snapshot.message { replace(message) }
        case .messageStart(.assistant(let message)):
            blocks = [:]
            replace(message)
        case .messageUpdate(let changes, _):
            for change in changes {
                switch change {
                case .textDelta(let index, let delta): blocks[index, default: ""] += delta
                case .blockStart(let index, .text(let text)), .block(let index, .text(let text)): blocks[index] = text
                case .message(let message): setBlocks(message)
                default: break
                }
            }
            publishText()
        case .messageEnd(let entry), .entryAppended(let entry): receiveEntry(entry)
        case .toolExecutionStart(let id, let name, let arguments):
            let call = AgentToolCall(id: id, name: name, arguments: (try? AgentJSONValue.from(arguments)) ?? .object([:]))
            calls[id] = call
            continuation.yield(.toolStarted(call))
        case .toolExecutionEnd(let id, let name, let entry):
            if let entry { receiveEntry(entry) }
            else if completedCalls.insert(id).inserted {
                let call = calls[id] ?? AgentToolCall(id: id, name: name, arguments: .object([:]))
                continuation.yield(.toolFinished(.init(call: call, result: .error(String(localized: "agent.tool.interrupted", defaultValue: "Tool execution was interrupted.", bundle: .module)))))
            }
        default: break
        }
    }

    func reconcile(_ view: ConversationView) {
        for entry in view.entries { receiveEntry(entry) }
        if let partial = view.streamingMessage { replace(partial) }
    }

    private func receiveEntry(_ entry: Entry) {
        rememberCalls(entry)
        guard entries.insert(entry.id).inserted else { return }
        if let message = RuntimeMapping.message(entry, conversationID: conversationID), message.role == .assistant {
            continuation.yield(.assistantText(message.text))
            continuation.yield(.message(message))
        }
        if let result = entry.toolResult, completedCalls.insert(result.toolCallId).inserted {
            let call = calls[result.toolCallId] ?? AgentToolCall(id: result.toolCallId, name: result.toolName, arguments: .object([:]))
            var output = RuntimeMapping.result(result)
            if output.isError { output = .error(RuntimeMapping.redact(output.text, secret: secret)) }
            continuation.yield(.toolFinished(.init(call: call, result: output)))
        }
    }

    private func rememberCalls(_ entry: Entry) {
        for block in entry.assistantMessage?.content ?? [] {
            if case .toolCall(let call) = block {
                calls[call.id] = AgentToolCall(id: call.id, name: call.name,
                    arguments: (try? AgentJSONValue.from(call.arguments)) ?? .object([:]))
            }
        }
    }
    private func replace(_ message: AssistantMessage) { setBlocks(message); publishText() }
    private func setBlocks(_ message: AssistantMessage) {
        blocks = [:]
        for (index, block) in message.content.enumerated() {
            if case .text(let text) = block { blocks[index] = text }
        }
    }
    private func publishText() {
        continuation.yield(.assistantText(blocks.keys.sorted().compactMap { blocks[$0] }.joined()))
    }
}

extension AgentJSONValue {
    static func from<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}
