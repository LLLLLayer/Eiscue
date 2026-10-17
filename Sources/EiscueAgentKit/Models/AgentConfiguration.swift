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
    /// Explicit local fixture exception; remote HTTP is always rejected.
    public var allowsLoopbackHTTP: Bool

    public init(
        api: AgentAPI, baseURL: URL, model: String, apiKey: String,
        supportsImages: Bool = true, contextWindow: Int = 128_000, maxOutputTokens: Int = 4_096,
        allowsLoopbackHTTP: Bool = false
    ) {
        self.api = api
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.supportsImages = supportsImages
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.allowsLoopbackHTTP = allowsLoopbackHTTP
    }

    public func validate() throws {
        let scheme = baseURL.scheme?.lowercased()
        let host = baseURL.host?.lowercased() ?? ""
        let loopback = ["127.0.0.1", "[::1]", "::1", "localhost"].contains(host)
        guard (scheme == "https" || (scheme == "http" && allowsLoopbackHTTP && loopback)),
              !host.isEmpty, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-url", defaultValue: "Enter a valid HTTPS model service URL without credentials, query, or fragment.", bundle: .module))
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.invalidConfiguration(String(localized: "agent.configuration.missing-model", defaultValue: "Enter a model ID.", bundle: .module))
        }
        guard contextWindow > 0, maxOutputTokens > 0, maxOutputTokens <= contextWindow else {
            throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-context", defaultValue: "The model context and output length settings are invalid.", bundle: .module))
        }
    }
}
