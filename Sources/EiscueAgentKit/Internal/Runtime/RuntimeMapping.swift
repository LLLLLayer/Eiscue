import CryptoKit
import Foundation
import PiDurableKit

enum RuntimeMapping {
    static func redact(_ text: String, secret: String) -> String {
        secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "[redacted]")
    }

    static func tool(_ tool: AgentTool, budget: RunBudget, secret: String) throws -> PiDurableKit.Tool {
        let schema = try JSONDecoder().decode(PiDurableKit.JSONObject.self, from: JSONEncoder().encode(tool.parameters))
        return PiDurableKit.Tool(tool.name, description: tool.description, parameters: JSONSchema(schema),
            replay: tool.mayHaveSideEffects ? .unsafe : .safe, executionMode: .sequential
        ) { (arguments: AgentJSONValue, _: ToolCallContext) -> PiDurableKit.ToolResult in
            do {
                try await budget.enter()
                let result = try await tool.execute(arguments)
                try await budget.check()
                return PiDurableKit.ToolResult(content: result.content.map(content), isError: result.isError)
            } catch AgentError.toolLimitReached {
                return .error(AgentError.toolLimitReached.localizedDescription).terminating()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .error(redact(error.localizedDescription, secret: secret))
            }
        }
    }

    static func content(_ block: AgentToolContent) -> PiDurableKit.ContentBlock {
        switch block {
        case .text(let text): .text(text)
        case .image(let data, let mimeType): .image(ImageContent(data: data, mimeType: mimeType))
        }
    }

    static func result(_ message: ToolResultMessage) -> AgentToolResult {
        let content: [AgentToolContent] = message.content.compactMap { block in
            switch block {
            case .text(let text): return .text(text)
            case .image(let image): return image.bytes.map { .image(data: $0, mimeType: image.mimeType) }
            default: return nil
            }
        }
        return AgentToolResult(content: content, isError: message.isError)
    }

    static func message(_ entry: Entry, conversationID: UUID) -> AgentMessage? {
        let id = entry.data?["eiscueID"]?.stringValue.flatMap(UUID.init(uuidString:))
            ?? stableID(conversationID: conversationID, entry: entry.id.rawValue)
        if let user = entry.userMessage {
            return AgentMessage(id: id, role: .user, text: user.text, createdAt: user.timestamp)
        }
        if let assistant = entry.assistantMessage, !assistant.text.isEmpty {
            return AgentMessage(id: id, role: .assistant, text: assistant.text, createdAt: assistant.timestamp)
        }
        return nil
    }

    static func recovery(_ view: ConversationView, conversationID: UUID) -> AgentRecovery {
        AgentRecovery(messages: view.entries.compactMap { message($0, conversationID: conversationID) },
                      hasInterruptedRun: view.isBusy || !view.inbox.isEmpty)
    }

    private static func stableID(conversationID: UUID, entry: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(conversationID.uuidString):entry:\(entry)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
