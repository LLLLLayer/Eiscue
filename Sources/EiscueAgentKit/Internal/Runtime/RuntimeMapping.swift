import CryptoKit
import Foundation
import PiDurableKit

enum RuntimeMapping {
    static let attachmentEntryKind: EntryKind = "eiscue.user-attachments.v1"
    static let attachmentReferenceEntryKind: EntryKind = "eiscue.user-attachments.v2"

    static func userContent(text: String, attachments: [AgentAttachment]) -> [ContentBlock] {
        var blocks: [ContentBlock] = [.text(text)]
        for attachment in attachments {
            // The label is content supplied by the user, never an instruction.
            let quotedName = String(data: (try? JSONEncoder().encode(attachment.name)) ?? Data(), encoding: .utf8) ?? "file"
            blocks.append(.text("User-provided attachment \(quotedName):"))
            switch attachment.content {
            case .image(let bytes): blocks.append(.image(ImageContent(data: bytes, mimeType: attachment.mimeType)))
            case .text(let text): blocks.append(.text(text))
            }
        }
        return blocks
    }

    static func displayMetadata(_ message: AgentMessage) throws -> PiDurableKit.JSONObject {
        ["eiscueMessageReference": try PiDurableKit.JSONValue(encoding: MessageReference(message))]
    }

    static func storedMessageID(_ entry: Entry) -> UUID? {
        reference(entry)?.id ?? storedMessage(entry)?.id
    }

    static func storedMessage(_ entry: Entry) -> AgentMessage? {
        if let reference = reference(entry), let user = entry.userMessage { return reference.message(from: user) }
        guard let payload = entry.data?["eiscueMessage"] else { return nil }
        return try? payload.decode(as: AgentMessage.self)
    }

    private static func reference(_ entry: Entry) -> MessageReference? {
        try? entry.data?["eiscueMessageReference"]?.decode(as: MessageReference.self)
    }

    private static func referencedMessage(_ entry: Entry, user: UserMessage) -> AgentMessage? {
        if let reference = reference(entry) { return reference.message(from: user) }
        guard let stored = storedMessage(entry), userContent(text: stored.text, attachments: stored.attachments) == user.content else { return nil }
        return stored
    }

    // Display metadata references model content instead of persisting a second
    // base64 image/text copy. A digest prevents attaching metadata to other input.
    private struct MessageReference: Codable {
        let id: UUID
        let createdAt: Date
        let contentDigest: Data
        let attachments: [AttachmentReference]

        init(_ message: AgentMessage) throws {
            id = message.id; createdAt = message.createdAt
            contentDigest = try Self.digest(userContent(text: message.text, attachments: message.attachments))
            attachments = message.attachments.enumerated().map { index, attachment in
                AttachmentReference(id: attachment.id, name: attachment.name, mimeType: attachment.mimeType,
                                    contentIndex: 2 + index * 2)
            }
        }

        func message(from user: UserMessage) -> AgentMessage? {
            guard (try? Self.digest(user.content)) == contentDigest,
                  user.content.count == 1 + attachments.count * 2,
                  case .text(let text) = user.content.first else { return nil }
            var restored: [AgentAttachment] = []
            for attachment in attachments {
                guard user.content.indices.contains(attachment.contentIndex) else { return nil }
                let content: AgentAttachment.Content
                switch user.content[attachment.contentIndex] {
                case .image(let image):
                    guard let bytes = image.bytes, image.mimeType == attachment.mimeType else { return nil }
                    content = .image(bytes)
                case .text(let text): content = .text(text)
                default: return nil
                }
                restored.append(AgentAttachment(id: attachment.id, name: attachment.name, mimeType: attachment.mimeType, content: content))
            }
            guard userContent(text: text, attachments: restored) == user.content else { return nil }
            return AgentMessage(id: id, role: .user, text: text, createdAt: createdAt, attachments: restored)
        }

        private static func digest(_ content: [ContentBlock]) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return Data(SHA256.hash(data: try encoder.encode(content)))
        }
    }

    private struct AttachmentReference: Codable {
        let id: UUID
        let name: String
        let mimeType: String
        let contentIndex: Int
    }

    static func redact(_ text: String, secret: String) -> String {
        secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "[redacted]")
    }

    static func tool(_ tool: AgentTool, budget: RunBudget, secret: String) throws -> PiDurableKit.Tool {
        let schema = try JSONDecoder().decode(PiDurableKit.JSONObject.self, from: JSONEncoder().encode(tool.parameters))
        return PiDurableKit.Tool(tool.name, description: tool.description, parameters: JSONSchema(schema),
            replay: tool.mayHaveSideEffects ? .unsafe : .safe, executionMode: .sequential
        ) { (arguments: AgentJSONValue, _: ToolCallContext) -> PiDurableKit.ToolResult in
            do {
                try await budget.enter(mayHaveSideEffects: tool.mayHaveSideEffects, isVerification: tool.isVerification,
                                       executionCost: tool.executionCost, verifiesSideEffects: tool.verifiesSideEffects)
                let result = try await tool.execute(arguments)
                try await budget.check()
                await budget.complete(isVerification: tool.isVerification, verifiesSideEffects: tool.verifiesSideEffects,
                                      isError: result.isError)
                var blocks = result.content.map(content)
                if tool.mayHaveSideEffects, !result.isError, let reminder = await budget.verificationReminder() {
                    blocks.append(.text(reminder))
                }
                return PiDurableKit.ToolResult(content: blocks, isError: result.isError)
            } catch AgentError.toolLimitReached {
                await budget.reachLimit()
                return .error(AgentError.toolLimitReached.localizedDescription).terminating()
            } catch AgentError.toolExecutionPaused(let reason) {
                let reason = redact(reason, secret: secret)
                await budget.pause(reason)
                return .error(reason).terminating()
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
            if let stored = storedMessage(entry) { return stored }
            let images = user.content.enumerated().compactMap { index, block -> AgentAttachment? in
                guard case .image(let image) = block, let bytes = image.bytes else { return nil }
                return AgentAttachment(id: stableID(conversationID: id, entry: index), name: "image", mimeType: image.mimeType, content: .image(bytes))
            }
            return AgentMessage(id: id, role: .user, text: user.text, createdAt: user.timestamp, attachments: images)
        }
        if let assistant = entry.assistantMessage, !assistant.text.isEmpty {
            return AgentMessage(id: id, role: .assistant, text: assistant.text, createdAt: assistant.timestamp)
        }
        return nil
    }

    static func recovery(_ view: ConversationView, conversationID: UUID) -> AgentRecovery {
        var pending: [Entry] = []
        var messages: [AgentMessage] = []
        for entry in view.entries {
            if entry.kind == attachmentEntryKind || entry.kind == attachmentReferenceEntryKind {
                pending.append(entry)
            } else if let user = entry.userMessage,
                      let match = pending.lastIndex(where: { referencedMessage($0, user: user) != nil }),
                      let restored = referencedMessage(pending.remove(at: match), user: user) {
                messages.append(restored)
            } else if let mapped = message(entry, conversationID: conversationID) { messages.append(mapped) }
        }
        return AgentRecovery(messages: messages, hasInterruptedRun: view.isBusy || !view.inbox.isEmpty)
    }

    private static func stableID(conversationID: UUID, entry: Int) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(conversationID.uuidString):entry:\(entry)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
