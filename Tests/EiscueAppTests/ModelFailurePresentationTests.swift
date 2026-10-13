import EiscueAgentKit
import Foundation
import XCTest
@testable import Eiscue

final class ModelFailurePresentationTests: XCTestCase {
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/"
    private let body = #"{"error":{"code":400,"status":"FAILED_PRECONDITION","message":"User location is not supported for the API use.","details":"fixture-private-value"}}"#

    func testRecognizesExactGoogleRegionFailureWithoutEchoingResponse() throws {
        for payload in ["400 \(body)", "400 [\(body)]", "\n400\n[\(body)]\n"] {
            for error in [AgentError.modelRequestFailed(payload), .runtime(payload)] {
                let message = try XCTUnwrap(ModelFailurePresentation.message(for: error,
                    api: .openAICompletions, baseURL: endpoint))
                XCTAssertEqual(message, String(localized: "error.model_region_unavailable", table: "Runtime"))
                XCTAssertFalse(message.contains("fixture-private-value"))
                XCTAssertFalse(message.contains("FAILED_PRECONDITION"))
            }
        }
        XCTAssertNotNil(ModelFailurePresentation.message(for: AgentError.runtime("400 \(body)"),
            api: .openAICompletions, baseURL: " https://generativelanguage.googleapis.com:443/v1beta/openai "))
    }

    func testDoesNotClassifyOtherEndpointsOrProtocols() {
        for url in ["http://generativelanguage.googleapis.com/v1beta/openai/",
                    "https://generativelanguage.googleapis.com.fixture.invalid/v1beta/openai/",
                    "https://proxy.generativelanguage.googleapis.com/v1beta/openai/",
                    "https://generativelanguage.googleapis.com:8443/v1beta/openai/",
                    "https://generativelanguage.googleapis.com/v1",
                    "https://api.openai.com/v1",
                    endpoint + "?key=fixture", endpoint + "#fixture",
                    "https://fixture@generativelanguage.googleapis.com/v1beta/openai/"] {
            XCTAssertNil(ModelFailurePresentation.message(for: AgentError.runtime("400 \(body)"),
                api: .openAICompletions, baseURL: url), url)
        }
        for api in [AgentAPI.openAIResponses, .anthropicMessages] {
            XCTAssertNil(ModelFailurePresentation.message(for: AgentError.runtime("400 \(body)"),
                api: api, baseURL: endpoint))
        }
    }

    func testRejectsApproximateOrUnstructuredErrors() {
        for detail in ["User location is not supported for the API use.", "400 User location is not supported for the API use.",
                       "400", body, "401 \(body)", "4000 \(body)", "400 [\(body),\(body)]",
                       "400 " + body.replacingOccurrences(of: "\"code\":400", with: "\"code\":403"),
                       "400 " + body.replacingOccurrences(of: "FAILED_PRECONDITION", with: "INVALID_ARGUMENT"),
                       "400 " + body.replacingOccurrences(of: "User location", with: "Unsupported User location"),
                       "400 " + body.replacingOccurrences(of: "\"status\":\"FAILED_PRECONDITION\",", with: ""),
                       "400 \(body) trailing text"] {
            XCTAssertNil(ModelFailurePresentation.message(for: AgentError.runtime(detail),
                api: .openAICompletions, baseURL: endpoint), detail)
        }
        XCTAssertNil(ModelFailurePresentation.message(for: AgentError.invalidConfiguration("400 \(body)"),
            api: .openAICompletions, baseURL: endpoint))
        XCTAssertNil(ModelFailurePresentation.message(for: NSError(domain: "fixture", code: 400,
            userInfo: [NSLocalizedDescriptionKey: "400 \(body)"]), api: .openAICompletions, baseURL: endpoint))
    }

    func testRegionGuidanceIsBundledInEnglishAndChinese() throws {
        let app = Bundle(for: AppModel.self)
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(app.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let key = "error.model_region_unavailable"
            let message = bundle.localizedString(forKey: key, value: nil, table: "Runtime")
            XCTAssertNotEqual(message, key)
            XCTAssertTrue(message.contains("Gemini"))
            XCTAssertFalse(message.contains("FAILED_PRECONDITION"))
            XCTAssertFalse(message.contains("%@"))
        }
    }
}
