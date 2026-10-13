import Foundation
import PiDurableKit
import Testing
import os
@testable import EiscueAgentKit

@Suite("Model request failure isolation")
struct ModelRequestFailureTests {
    @Test func firstHTTP400IsTypedAndRedactedWithoutExecutingTools() async throws {
        let fixture = try await FailureFixture()
        defer { fixture.remove() }
        var accepted = false
        do {
            for try await event in try await fixture.client.run(request: .init(conversationID: UUID(), prompt: "Hello")) {
                if case .requestAccepted = event { accepted = true }
            }
            Issue.record("The fixture rejects the model request.")
        } catch AgentError.modelRequestFailed(let message) {
            #expect(message.contains("User location is not supported"))
            #expect(!message.contains(FailureFixture.secret))
            #expect(message.contains("[redacted]"))
        } catch { Issue.record("Expected a model request failure, got \(error)") }
        #expect(accepted)
        #expect(fixture.toolCalls.withLock { $0 } == 0)
    }

    @Test func durableAbortFailurePreventsPreservingAConnectionAfterHTTP400() async throws {
        let fixture = try await FailureFixture(abortOperation: { _ in
            throw AgentError.runtime("Durable cleanup failed: \(FailureFixture.secret)")
        })
        defer { fixture.remove() }
        do {
            for try await _ in try await fixture.client.run(request: .init(conversationID: UUID(), prompt: "Hello")) {}
            Issue.record("Durable cleanup failure must reach the host.")
        } catch AgentError.runtime(let message) {
            #expect(message.contains("Durable cleanup failed"))
            #expect(!message.contains(FailureFixture.secret))
            #expect(message.contains("[redacted]"))
        } catch { Issue.record("Cleanup must downgrade a model error to runtime failure, got \(error)") }
        #expect(fixture.toolCalls.withLock { $0 } == 0)
    }

    @Test func previousTurnErrorsAndReplayedSettlementsCannotClassifyAsANewModelFailure() throws {
        let old = try entry(8, .assistant(.init(content: [], stopReason: .error, errorMessage: "Old failure")))
        let input = try entry(9, .user(.init(content: [.text("New question")])))
        let failure = try entry(10, .assistant(.init(content: [], stopReason: .error, errorMessage: "New failure")))
        let answer = try entry(11, .assistant(.init(content: [.text("Recovered")], stopReason: .stop)))
        #expect(ModelRequestFailure.classify(entries: [old, input], input: input.id, existingEntries: [old.id]) == nil)
        // 10 sorts before 9 as text, but transcript order is authoritative.
        #expect(ModelRequestFailure.classify(entries: [old, input, failure], input: input.id, existingEntries: [old.id]) == .modelRequestFailed("New failure"))
        #expect(ModelRequestFailure.classify(entries: [old, input, failure], input: input.id,
            existingEntries: [old.id, input.id, failure.id]) == nil)
        #expect(ModelRequestFailure.classify(entries: [old, input, failure, answer], input: input.id, existingEntries: [old.id]) == nil)
        #expect(ModelRequestFailure.classify(entries: [old, failure], input: input.id, existingEntries: [old.id]) == nil)
        #expect(ModelRequestFailure.classify(entries: [old, input, failure], input: nil, existingEntries: [old.id]) == nil)
    }

    private func entry(_ id: Int, _ message: PiDurableKit.Message) throws -> Entry {
        struct Payload: Encodable {
            let id: Int
            let conversationId = 1
            let kind: EntryKind
            let model: [PiDurableKit.Message]
        }
        let kind: EntryKind = if case .user = message { .user } else { .assistant }
        return try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(Payload(id: id, kind: kind, model: [message])))
    }
}

private struct FailureFixture {
    // A fixed fake fixture credential, never read from a user or from requests.
    static let secret = "fixture-model-error-redaction-marker"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-model-failure-\(UUID())")
    let toolCalls = OSAllocatedUnfairLock(initialState: 0)
    let client: AgentClient

    init(abortOperation: DefaultEngine.AbortOperation? = nil) async throws {
        let configuration = AgentConfiguration(api: .openAICompletions,
            baseURL: URL(string: "https://model-failure.fixture.invalid/v1")!, model: "fixture-model", apiKey: Self.secret)
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ModelFailureHTTPProtocol.self]
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
        let calls = toolCalls
        let tool = AgentTool(name: "device_screenshot", description: "Observe", parameters: ["type": "object", "properties": [:], "additionalProperties": false],
            mayHaveSideEffects: false) { _ in
                calls.withLock { $0 += 1 }
                return .text("This fixture must not execute a device tool.")
            }
        client = AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory, tools: [tool],
            modelFactory: { try await DefaultEngine.makeModels(configuration: configuration, runtime: runtime) },
            abortOperation: abortOperation ?? { try await $0.abort(background: true) }))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class ModelFailureHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        // Constant test data, not a reflection of Authorization or any input.
        let body = """
        {"error":{"code":400,"status":"FAILED_PRECONDITION","message":"User location is not supported for the API use. fixture-model-error-redaction-marker"}}
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
