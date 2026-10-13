import Foundation

public struct AgentTool: Sendable {
    public let name: String
    public let description: String
    public let parameters: AgentJSONValue
    public let mayHaveSideEffects: Bool
    /// A read-only observation that can verify a preceding action. Its final
    /// budget slot is reserved when this tool is registered for the run.
    public let isVerification: Bool
    /// Budget units reserved before execution, including any host-owned work
    /// performed inside this tool, such as its post-action observation.
    public let executionCost: Int
    /// A side-effect tool that also observes its result before returning success.
    /// It remains unsafe to replay and reserves at least two budget units.
    public let verifiesSideEffects: Bool
    public let execute: @Sendable (AgentJSONValue) async throws -> AgentToolResult

    public init(
        name: String, description: String, parameters: AgentJSONValue,
        mayHaveSideEffects: Bool = true,
        isVerification: Bool = false,
        executionCost: Int = 1,
        verifiesSideEffects: Bool = false,
        execute: @escaping @Sendable (AgentJSONValue) async throws -> AgentToolResult
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.mayHaveSideEffects = mayHaveSideEffects
        self.isVerification = isVerification
        self.executionCost = executionCost
        self.verifiesSideEffects = verifiesSideEffects
        self.execute = execute
    }
}

public enum AgentToolContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
}

public struct AgentToolResult: Sendable, Equatable {
    public let content: [AgentToolContent]
    public let isError: Bool

    public init(content: [AgentToolContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public var text: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    public static func text(_ text: String) -> Self { .init(content: [.text(text)]) }
    public static func error(_ text: String) -> Self { .init(content: [.text(text)], isError: true) }
    public static func image(_ data: Data, mimeType: String, caption: String? = nil) -> Self {
        var content: [AgentToolContent] = []
        if let caption { content.append(.text(caption)) }
        content.append(.image(data: data, mimeType: mimeType))
        return .init(content: content)
    }
}

public struct AgentToolCall: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: AgentJSONValue

    public init(id: String, name: String, arguments: AgentJSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AgentToolCompletion: Sendable, Equatable {
    public let call: AgentToolCall
    public let result: AgentToolResult

    public init(call: AgentToolCall, result: AgentToolResult) {
        self.call = call
        self.result = result
    }
}
