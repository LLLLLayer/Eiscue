import Foundation
import PiDurableKit

enum ModelRequestFailure {
    static func classify(entries: [Entry], input: EntryID?, existingEntries: Set<EntryID>) -> AgentError? {
        // Use transcript order and the runtime's settled input entry, not a
        // textual ID comparison or the previous turn's last error message.
        guard let input, let index = entries.firstIndex(where: { $0.id == input }),
              let entry = entries.dropFirst(index + 1).last(where: { $0.assistantMessage != nil }),
              !existingEntries.contains(entry.id), let assistant = entry.assistantMessage,
              assistant.stopReason == .error else { return nil }
        return .modelRequestFailed(assistant.errorMessage ?? String(localized: "agent.runtime.model-failed",
            defaultValue: "The model request failed.", bundle: .module))
    }

    static func isModelFailure(_ error: (any Error)?) -> Bool {
        guard let error = error as? AgentError else { return false }
        if case .modelRequestFailed = error { return true }
        return false
    }
}
