import Foundation

public enum AgentAPI: String, Codable, Sendable, CaseIterable {
    case openAICompletions
    case openAIResponses
    case anthropicMessages
}

/// Credentials are deliberately not Codable. The host owns secure credential storage.
public struct AgentConfiguration: Sendable, Equatable {
    public var api: AgentAPI
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    public var supportsImages: Bool
    public var contextWindow: Int
    public var maxOutputTokens: Int

    public init(
        api: AgentAPI, baseURL: URL, model: String, apiKey: String,
        supportsImages: Bool = true, contextWindow: Int = 128_000, maxOutputTokens: Int = 4_096
    ) {
        self.api = api
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.supportsImages = supportsImages
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
    }

    public func validate() throws {
        guard ["https", "http"].contains(baseURL.scheme?.lowercased() ?? ""),
              let host = baseURL.host, !host.isEmpty, baseURL.user == nil, baseURL.password == nil else {
            throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-url", defaultValue: "Enter a valid HTTP or HTTPS model service URL.", bundle: .module))
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.invalidConfiguration(String(localized: "agent.configuration.missing-model", defaultValue: "Enter a model ID.", bundle: .module))
        }
        guard contextWindow > 0, maxOutputTokens > 0, maxOutputTokens <= contextWindow else {
            throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-context", defaultValue: "The model context and output length settings are invalid.", bundle: .module))
        }
    }
}
