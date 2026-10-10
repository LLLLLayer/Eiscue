import EiscueAgentKit
import Foundation

/// Credentials are deliberately excluded from this preferences value.
struct ModelSettings: Codable, Equatable {
    var api = AgentAPI.openAICompletions
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    var supportsImages = true
    var maxOutputTokens = 4096
    var maxToolCalls = 30
    var timeoutSeconds = 300

    func configuration(apiKey: String) throws -> AgentConfiguration {
        var allowsTestLoopback = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let fixture = ProcessInfo.processInfo.environment["EISCUE_TEST_MODEL_URL"],
           fixture == baseURL, URL(string: fixture)?.host == "127.0.0.1" { allowsTestLoopback = true }
        #endif
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              (url.scheme == "https" || (allowsTestLoopback && url.scheme == "http")), url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw SettingsError.invalidURL
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsError.missingModel
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsError.missingKey
        }
        return AgentConfiguration(
            api: api, baseURL: url, model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            supportsImages: supportsImages, maxOutputTokens: maxOutputTokens
        )
    }
}

enum SettingsError: LocalizedError {
    case invalidURL, missingModel, missingKey
    var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "model.invalidURL")
        case .missingModel: String(localized: "model.missingModel")
        case .missingKey: String(localized: "model.missingKey")
        }
    }
}

extension AgentAPI {
    var title: String {
        switch self {
        case .openAICompletions: String(localized: "model.apiCompletions")
        case .openAIResponses: String(localized: "model.apiResponses")
        case .anthropicMessages: String(localized: "model.apiAnthropic")
        }
    }
}

enum TaskScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat, observe, control
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: String(localized: "scope.chat")
        case .observe: String(localized: "scope.observe")
        case .control: String(localized: "scope.control")
        }
    }
    var explanation: String {
        switch self {
        case .chat: String(localized: "scope.chatDetail")
        case .observe: String(localized: "scope.observeDetail")
        case .control: String(localized: "scope.controlDetail")
        }
    }
}
