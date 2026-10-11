import Foundation
import Testing
@testable import EiscueAgentKit

@Suite struct AgentAttachmentTests {
    @Test func oldMessagesDecodeWithoutAttachmentsAndNewMessagesRoundTrip() throws {
        let original = AgentMessage(role: .user, text: "legacy")
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "attachments")
        let legacy = try JSONDecoder().decode(AgentMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy == original)
        let attachment = AgentAttachment(name: "notes.txt", mimeType: "text/plain", content: .text("actual file contents"))
        let message = AgentMessage(role: .user, text: "", attachments: [attachment])
        #expect(try JSONDecoder().decode(AgentMessage.self, from: JSONEncoder().encode(message)) == message)
    }

    @Test func limitsAndImageCapabilitiesAreEnforcedBeforeRuntimeAdmission() throws {
        let image = AgentAttachment(name: "photo.jpg", mimeType: "image/jpeg", content: .image(Data([1])))
        #expect(throws: AgentError.self) { try AgentAttachment.validate([image], supportsImages: false) }
        #expect(throws: AgentError.self) { try AgentAttachment.validate([image, image], supportsImages: true) }
        #expect(throws: AgentError.self) { try AgentAttachment.validate([.init(name: "large.txt", mimeType: "text/plain", content: .text(String(repeating: "x", count: 60_001)))], supportsImages: true) }
        #expect(throws: AgentError.self) { try AgentAttachment.validate([.init(name: "empty", mimeType: "text/plain", content: .text("  \n"))], supportsImages: true) }
        try AgentAttachment.validate([.init(name: "file.txt", mimeType: "text/plain", content: .text("readable"))], supportsImages: false)
    }
}
