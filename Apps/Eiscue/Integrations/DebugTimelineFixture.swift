#if DEBUG
import EiscueAgentKit
import Foundation

extension AppModel {
    /// Available only to the opt-in local UI fixture. No file is actually read,
    /// edited or executed, and production chat keeps its normal empty tool set.
    static var timelineFixtureTools: [AgentTool] {
        [AgentTool(name: "fixture_read_file", description: "Read the integration fixture document.",
                   parameters: .object(["type": .string("object"),
                                        "properties": .object(["path": .object(["type": .string("string")])]),
                                        "required": .array([.string("path")]),
                                        "additionalProperties": .bool(false)]), mayHaveSideEffects: false) { arguments in
            guard case .object(let values) = arguments else {
                return .error("Unexpected fixture path")
            }
            if values["path"] == .string("pause.txt") {
                throw AgentError.toolExecutionPaused(String(localized: "toolError.noProgress"))
            }
            guard values["path"] == .string("fixture.txt") else { return .error("Unexpected fixture path") }
            return .text("Fixture document content")
        }]
    }
}
#endif
