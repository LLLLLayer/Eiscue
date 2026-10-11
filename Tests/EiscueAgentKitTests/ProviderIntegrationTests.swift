import Foundation
import Testing
import PiDurableKit
import os
@testable import EiscueAgentKit

@Suite("Custom provider protocols")
struct ProviderIntegrationTests {
    @Test func plainTextDisplayMetadataDoesNotChangeInstructionsOrBecomeModelContext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-plain-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = AgentConfiguration(api: .openAICompletions,
            baseURL: URL(string: "https://plain-context.fixture.invalid/v1")!, model: "fixture-model",
            apiKey: "plain-context-fixture-\(UUID())")
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ProviderFixtureProtocol.self]
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
        let client = AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory,
            modelFactory: { try await DefaultEngine.makeModels(configuration: configuration, runtime: runtime) }))
        let request = AgentRequest(conversationID: UUID(), prompt: "Plain text question",
            systemPrompt: "You are Eiscue. Reply concisely in the user's language.")
        for try await _ in try await client.run(request: request) {}
        let recorded = try #require(ProviderFixtureProtocol.requests.withLock {
            $0.last(where: { $0.authorization == "Bearer \(configuration.apiKey)" })
        })
        #expect(recorded.body["tools"] == nil || recorded.body["tools"] == .array([]))
        #expect(recorded.body["messages"] == .array([
            ["role": "system", "content": "<instructions>\nYou are Eiscue. Reply concisely in the user's language.\n</instructions>"],
            ["role": "user", "content": "Plain text question"],
        ]))
        let recovered = try await AgentClient(storageDirectory: directory).recover(conversationID: request.conversationID)
        #expect(recovered.messages.first?.id == request.requestID)
    }

    struct StoreEndpoint: Sendable, CustomStringConvertible {
        let url: String
        let api: AgentAPI
        let sendsStore: Bool
        var description: String { "\(api.rawValue): \(url)" }
    }

    @Test func googleCompatibleProviderRoundTripsDeviceImageTool() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-google-device-tools-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = AgentConfiguration(api: .openAICompletions,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!,
            model: "gemini-3.8-flash", apiKey: "google-device-tools-fixture-\(UUID())", supportsImages: true)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let screenshot = AgentTool(name: "device_screenshot", description: "Observe the current screen",
            parameters: ["type": "object", "properties": [:], "additionalProperties": false],
            mayHaveSideEffects: false) { _ in
                calls.withLock { $0 += 1 }
                return .image(Data([137, 80, 78, 71]), mimeType: "image/png", caption: "Frame fixture-frame-1")
            }
        // Exercise the real runtime and HTTP encoder entirely through the local fixture.
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ProviderFixtureProtocol.self]
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
        let client = AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory,
            tools: [screenshot], modelFactory: { try await DefaultEngine.makeModels(configuration: configuration, runtime: runtime) }))
        var events: [EiscueAgentKit.AgentEvent] = []
        for try await event in try await client.run(request: .init(conversationID: UUID(), prompt: "Observe my screen")) {
            events.append(event)
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(events.contains(.finished(.completed)))
        #expect(events.contains { if case .message(let message) = $0 { message.text == "Hello world" } else { false } })
        #expect(events.contains { if case .toolFinished(let completion) = $0 {
            completion.result.content.contains(.image(data: Data([137, 80, 78, 71]), mimeType: "image/png"))
        } else { false } })

        let requests = ProviderFixtureProtocol.requests.withLock {
            $0.filter { $0.authorization == "Bearer \(configuration.apiKey)" }
        }
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.url.path == "/v1beta/openai/chat/completions")
            #expect(request.body["store"] == nil)
            let tools = try #require(request.body["tools"]?.arrayValue)
            #expect(tools.count == 1)
            #expect(tools.first?["type"] == "function")
            #expect(tools.first?["function"]?["name"] == "device_screenshot")
            #expect(tools.first?["function"]?["parameters"]?["type"] == "object")
        }
        let second = try #require(requests.last)
        let messages = try #require(second.body["messages"]?.arrayValue)
        let result = try #require(messages.first { $0["role"] == "tool" })
        #expect(result["tool_call_id"] == "screen-1")
        #expect(result["content"]?.stringValue?.contains("Frame fixture-frame-1") == true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let wireBody = try #require(String(data: encoder.encode(second.body), encoding: .utf8))
        #expect(wireBody.contains("data:image/png;base64,iVBORw=="))
    }

    @Test(arguments: [
        StoreEndpoint(url: "https://generativelanguage.googleapis.com/v1beta/openai", api: .openAICompletions, sendsStore: false),
        StoreEndpoint(url: "https://generativelanguage.googleapis.com:443/v1beta/openai/", api: .openAICompletions, sendsStore: false),
        StoreEndpoint(url: "https://api.openai.com/v1", api: .openAICompletions, sendsStore: true),
        StoreEndpoint(url: "https://generativelanguage.googleapis.com.fixture.invalid/v1beta/openai", api: .openAICompletions, sendsStore: true),
        StoreEndpoint(url: "https://proxy.generativelanguage.googleapis.com/v1beta/openai", api: .openAICompletions, sendsStore: true),
        StoreEndpoint(url: "https://generativelanguage.googleapis.com/v1", api: .openAICompletions, sendsStore: true),
        StoreEndpoint(url: "https://generativelanguage.googleapis.com/v1beta/openai", api: .openAIResponses, sendsStore: true),
        StoreEndpoint(url: "https://generativelanguage.googleapis.com/v1beta/openai", api: .anthropicMessages, sendsStore: false),
    ])
    func googleStoreCompatibilityPreservesOtherProviderRequests(_ endpoint: StoreEndpoint) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-google-compat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = AgentConfiguration(api: endpoint.api, baseURL: try #require(URL(string: endpoint.url)),
                                               model: "gemini-3.8-flash", apiKey: "google-compat-fixture-\(UUID())",
                                               supportsImages: true)
        // Intercept every URL in this session, including the official hosts;
        // no DNS lookup, external request, or real credential is involved.
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ProviderFixtureProtocol.self]
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
        let client = AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory,
            modelFactory: { try await DefaultEngine.makeModels(configuration: configuration, runtime: runtime) }))
        let photo = AgentAttachment(name: "photo.png", mimeType: "image/png", content: .image(Data([137, 80, 78, 71])))
        var messages: [AgentMessage] = []
        var partials: [String] = []
        for try await event in try await client.run(request: .init(conversationID: UUID(), prompt: "Describe this photo", attachments: [photo])) {
            if case .message(let message) = event { messages.append(message) }
            if case .assistantText(let text) = event { partials.append(text) }
        }
        #expect(messages.last?.text == "Hello world")
        #expect(partials.contains { !$0.isEmpty })
        if endpoint.api == .openAICompletions {
            #expect(partials.contains { !$0.isEmpty && $0 != "Hello world" && "Hello world".hasPrefix($0) })
        }

        // Unique credentials distinguish parallel cases sharing Google's host.
        let requests = ProviderFixtureProtocol.requests.withLock {
            $0.filter { $0.authorization == "Bearer \(configuration.apiKey)" || $0.apiKey == configuration.apiKey }
        }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url.scheme == "https")
        #expect(request.url.host == configuration.baseURL.host)
        let path = configuration.baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix: String = switch endpoint.api {
        case .openAICompletions: "/chat/completions"
        case .openAIResponses: "/responses"
        case .anthropicMessages: "/v1/messages"
        }
        #expect(request.url.path == "/" + path + suffix)
        #expect(request.body["model"] == "gemini-3.8-flash")
        #expect(request.body["stream"] == true)
        if endpoint.sendsStore {
            #expect(request.body["store"] == false)
        } else {
            #expect(request.body["store"] == nil)
        }
        if endpoint.api == .anthropicMessages {
            #expect(request.apiKey == configuration.apiKey)
        } else {
            #expect(request.authorization == "Bearer \(configuration.apiKey)")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let wireBody = try #require(String(data: encoder.encode(request.body), encoding: .utf8))
        #expect(wireBody.contains("iVBORw=="))
        #expect(wireBody.contains("image/png"))
    }

    @Test(arguments: AgentAPI.allCases)
    func customProviderUsesConfiguredEndpointAndCredential(_ api: AgentAPI) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-provider-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = api.rawValue.lowercased() + ".fixture.invalid"
        let configuration = AgentConfiguration(api: api, baseURL: URL(string: "https://\(host)/v1")!,
                                               model: "fixture-model", apiKey: "credential-for-fixture-only")
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ProviderFixtureProtocol.self]
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
        let client = AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory,
            modelFactory: { try await DefaultEngine.makeModels(configuration: configuration, runtime: runtime) }))
        let id = UUID()
        var messages: [AgentMessage] = []
        var partials: [String] = []
        let photo = AgentAttachment(name: "photo.png", mimeType: "image/png", content: .image(Data([137, 80, 78, 71])))
        let document = AgentAttachment(name: "notes.txt", mimeType: "text/plain", content: .text("USER_FILE_CONTENT_42"))
        for try await event in try await client.run(request: .init(conversationID: id, prompt: "Say hello", attachments: [photo, document])) {
            if case .message(let message) = event { messages.append(message) }
            if case .assistantText(let text) = event { partials.append(text) }
        }
        #expect(messages.last?.text == "Hello world")
        let request = try #require(ProviderFixtureProtocol.requests.withLock { $0.last(where: { $0.url.host == host }) })
        let expectedPath: String = switch api {
        case .openAICompletions: "/v1/chat/completions"
        case .openAIResponses: "/v1/responses"
        case .anthropicMessages: "/v1/messages"
        }
        #expect(request.url.path == expectedPath)
        #expect(request.body["model"] == "fixture-model")
        #expect(request.body["stream"] == true)
        let wireEncoder = JSONEncoder(); wireEncoder.outputFormatting = [.withoutEscapingSlashes]
        let wireBody = String(data: try wireEncoder.encode(request.body), encoding: .utf8) ?? ""
        #expect(wireBody.contains("iVBORw=="))
        #expect(wireBody.contains("image/png"))
        #expect(wireBody.contains("USER_FILE_CONTENT_42"))
        if api == .anthropicMessages {
            #expect(request.apiKey == configuration.apiKey)
        } else {
            #expect(request.authorization == "Bearer \(configuration.apiKey)")
        }
        if api == .openAICompletions {
            #expect(partials.contains { !$0.isEmpty && $0 != "Hello world" && "Hello world".hasPrefix($0) })
        }
        // Configured credentials live in Models' memory store, not the durable transcript.
        let bytes = try Data(contentsOf: directory.appendingPathComponent(id.uuidString.lowercased() + ".sqlite"))
        #expect(bytes.range(of: Data(configuration.apiKey.utf8)) == nil)
        let offline = AgentClient(storageDirectory: directory)
        #expect(await offline.availability == .unconfigured)
        #expect(try await offline.recover(conversationID: id).messages.last?.text == "Hello world")
        #expect(try await offline.recover(conversationID: id).messages.first?.attachments == [photo, document])
        try await offline.removeConversation(id: id)
        #expect(try await offline.recover(conversationID: id).messages.isEmpty)
    }
}

private final class ProviderFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let body: AgentJSONValue
        let authorization: String?
        let apiKey: String?
    }
    static let requests = OSAllocatedUnfairLock(initialState: [Request]())
    private let work = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let recorded = Request(url: url, body: (try? JSONDecoder().decode(AgentJSONValue.self, from: data)) ?? .null,
                               authorization: request.value(forHTTPHeaderField: "Authorization"),
                               apiKey: request.value(forHTTPHeaderField: "x-api-key"))
        Self.requests.withLock { $0.append(recorded) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunks: [String]
        if recorded.authorization?.hasPrefix("Bearer google-device-tools-fixture-") == true,
           !(recorded.body["messages"]?.arrayValue?.contains { $0["role"] == "tool" } ?? false) {
            chunks = Self.deviceToolCall
        }
        else if url.path.hasSuffix("chat/completions") { chunks = Self.completions }
        else if url.path.hasSuffix("responses") { chunks = Self.responses }
        else { chunks = Self.anthropic }
        work.withLock { task in
            task = Task {
                for chunk in chunks {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    client?.urlProtocol(self, didLoad: Data(chunk.utf8))
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() { work.withLock { $0?.cancel() } }

    static func sse(_ json: String, event: String? = nil) -> String {
        (event.map { "event: \($0)\n" } ?? "") + "data: \(json)\n\n"
    }

    static let completions = [
        sse(#"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#),
        sse(#"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":"stop"}]}"#),
        "data: [DONE]\n\n",
    ]

    static let deviceToolCall = [
        sse(#"{"id":"c-tool","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"screen-1","type":"function","function":{"name":"device_screenshot","arguments":"{}"}}]},"finish_reason":null}]}"#),
        sse(#"{"id":"c-tool","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
        "data: [DONE]\n\n",
    ]

    static let anthropic = [
        sse(#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"fixture-model","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":0}}}"#, event: "message_start"),
        sse(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, event: "content_block_start"),
        sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello world"}}"#, event: "content_block_delta"),
        sse(#"{"type":"content_block_stop","index":0}"#, event: "content_block_stop"),
        sse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}"#, event: "message_delta"),
        sse(#"{"type":"message_stop"}"#, event: "message_stop"),
    ]

    static var responses: [String] {
        let item = #"{"id":"msg_1","type":"message","status":"in_progress","role":"assistant","content":[]}"#
        let done = #"{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hello world","annotations":[]}]}"#
        func response(_ status: String, _ output: String) -> String {
            #"{"id":"resp_1","object":"response","created_at":1,"status":"\#(status)","model":"fixture-model","output":\#(output),"usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":0}}}"#
        }
        return [
            sse(#"{"type":"response.created","sequence_number":0,"response":\#(response("in_progress", "[]"))}"#, event: "response.created"),
            sse(#"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":\#(item)}"#, event: "response.output_item.added"),
            sse(#"{"type":"response.content_part.added","sequence_number":2,"item_id":"msg_1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#, event: "response.content_part.added"),
            sse(#"{"type":"response.output_text.delta","sequence_number":3,"item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello world"}"#, event: "response.output_text.delta"),
            sse(#"{"type":"response.output_item.done","sequence_number":4,"output_index":0,"item":\#(done)}"#, event: "response.output_item.done"),
            sse(#"{"type":"response.completed","sequence_number":5,"response":\#(response("completed", "[" + done + "]"))}"#, event: "response.completed"),
        ]
    }
}
