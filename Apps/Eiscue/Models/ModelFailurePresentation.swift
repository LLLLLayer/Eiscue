import EiscueAgentKit
import Foundation

enum ModelFailurePresentation {
    /// Only replace a recognized service response; callers retain their normal
    /// redacted error presentation for every other failure.
    static func message(for error: any Error, api: AgentAPI, baseURL: String) -> String? {
        guard api == .openAICompletions,
              let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "generativelanguage.googleapis.com",
              url.port == nil || url.port == 443,
              url.path == "/v1beta/openai" || url.path == "/v1beta/openai/",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let failure = error as? AgentError else { return nil }
        let detail: String
        switch failure {
        case .modelRequestFailed(let message), .runtime(let message): detail = message
        default: return nil
        }
        guard isGoogleRegionRestriction(detail) else { return nil }
        return String(localized: "error.model_region_unavailable", table: "Runtime")
    }

    private static func isGoogleRegionRestriction(_ detail: String) -> Bool {
        let response = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response.utf8.count <= 16_384, response.hasPrefix("400"),
              response.dropFirst(3).first?.isWhitespace == true else { return false }
        let payload = Data(response.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let decoder = JSONDecoder()
        let envelope: ErrorEnvelope
        if let single = try? decoder.decode(ErrorEnvelope.self, from: payload) { envelope = single }
        else if let array = try? decoder.decode([ErrorEnvelope].self, from: payload), array.count == 1 {
            envelope = array[0]
        } else { return false }
        return envelope.error.code == 400 && envelope.error.status == "FAILED_PRECONDITION"
            && envelope.error.message == "User location is not supported for the API use."
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let code: Int; let status, message: String }
        let error: Detail
    }
}
