import Foundation

/// Usable from the public initializer's default argument without exposing the
/// SwiftPM resource bundle or changing the initializer's signature.
@usableFromInline
enum AgentLocalization {
    @usableFromInline
    static var newConversationTitle: String {
        String(localized: "agent.conversation.new-title", defaultValue: "New conversation", bundle: .module)
    }
}
