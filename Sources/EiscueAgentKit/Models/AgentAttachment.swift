import Foundation

/// Portable user-provided content, independent of the selected agent runtime.
/// Images contain the actual encoded bytes; documents contain extracted text.
public struct AgentAttachment: Identifiable, Codable, Sendable, Equatable {
    public enum Content: Codable, Sendable, Equatable {
        case image(Data)
        case text(String)
    }
    public let id: UUID
    public let name: String
    public let mimeType: String
    public let content: Content

    public init(id: UUID = UUID(), name: String, mimeType: String, content: Content) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.content = content
    }

    public var isImage: Bool { if case .image = content { true } else { false } }
    public var imageData: Data? { if case .image(let data) = content { data } else { nil } }
    public var byteCount: Int {
        switch content { case .image(let data): data.count; case .text(let text): text.utf8.count }
    }

    /// Resource bounds also protect clients that bypass the app's import UI.
    public static func validate(_ attachments: [Self], supportsImages: Bool) throws {
        guard attachments.count <= 4, Set(attachments.map(\.id)).count == attachments.count,
              attachments.reduce(0, { $0 + $1.byteCount }) <= 8 * 1_024 * 1_024 else {
            throw AgentError.invalidConfiguration(String(localized: "agent.attachment.limit", defaultValue: "A message can include up to 4 attachments (8 MB total).", bundle: .module))
        }
        for attachment in attachments {
            guard !attachment.name.isEmpty, attachment.name.utf8.count <= 512 else {
                throw AgentError.invalidConfiguration(String(localized: "agent.attachment.invalid", defaultValue: "The attachment is empty, unsupported, or exceeds the allowed size.", bundle: .module))
            }
            switch attachment.content {
            case .image(let bytes):
                guard supportsImages else {
                    throw AgentError.invalidConfiguration(String(localized: "agent.attachment.images-unavailable", defaultValue: "Select a model that supports images to send this attachment.", bundle: .module))
                }
                guard ["image/jpeg", "image/png", "image/webp"].contains(attachment.mimeType),
                      !bytes.isEmpty, bytes.count <= 2 * 1_024 * 1_024 else {
                    throw AgentError.invalidConfiguration(String(localized: "agent.attachment.invalid", defaultValue: "The attachment is empty, unsupported, or exceeds the allowed size.", bundle: .module))
                }
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 60_000 else {
                    throw AgentError.invalidConfiguration(String(localized: "agent.attachment.invalid", defaultValue: "The attachment is empty, unsupported, or exceeds the allowed size.", bundle: .module))
                }
            }
        }
    }
}
