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

    @Test(arguments: AgentAPI.allCases)
    func screenshotContextBoundsPreserveUserAndOtherToolImagesAcrossProtocols(_ api: AgentAPI) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-image-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = AgentConfiguration(api: api, baseURL: URL(string: "https://images.fixture.invalid/v1")!,
            model: "fixture-model", apiKey: "images-fixture-\(UUID())", supportsImages: true)
        let network = URLSessionConfiguration.ephemeral; network.protocolClasses = [ProviderFixtureProtocol.self]
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
        let (models, model) = try await DefaultEngine.makeModels(configuration: configuration, runtime: runtime)
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString.lowercased() + ".sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let harness = try await Harness.open(.sqlite(at: url), models: models, resume: false)
        let root = try await harness.root(agent: AgentChange(model: model))
        let images = (1...6).map { Data(repeating: UInt8($0), count: 1024) }
        try await root.write(EntryDraft(kind: .user, model: [.user(UserMessage(content: [.text("Keep this user photo"),
            .image(ImageContent(data: images[0], mimeType: "image/png"))]))]))
        for index in 1...5 {
            let name = index == 5 ? "other_image_tool" : "device_screenshot"
            let callID = "retained-call-\(index)"
            let assistant = AssistantMessage(content: [.toolCall(ToolCall(id: callID, name: name, arguments: [:]))],
                api: api.rawValue, provider: "eiscue", model: configuration.model, stopReason: .toolUse)
            try await root.write(EntryDraft(kind: .assistant, model: [.assistant(assistant)]))
            let json: PiDurableKit.JSONValue = ["role": "toolResult", "toolCallId": .string(callID),
                "toolName": .string(name), "isError": false, "timestamp": 1,
                "content": [["type": "text", "text": .string("frameId=preserved-\(index)")],
                            ["type": "image", "mimeType": "image/png", "data": .string(images[index].base64EncodedString())]]]
            let result = try json.decode(as: ToolResultMessage.self)
            try await root.write(EntryDraft(kind: .toolResult, model: [.toolResult(result)]))
        }
        try await harness.close()
        let client = AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory,
            modelFactory: { (models, model) }))
        for try await _ in try await client.run(request: .init(conversationID: id, prompt: "Continue")) {}
        let request = try #require(ProviderFixtureProtocol.requests.withLock {
            $0.last { $0.authorization == "Bearer \(configuration.apiKey)" || $0.apiKey == configuration.apiKey }
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let wire = String(decoding: try encoder.encode(request.body), as: UTF8.self)
        for index in [0, 3, 4, 5] { #expect(wire.contains(images[index].base64EncodedString())) }
        for index in [1, 2] { #expect(!wire.contains(images[index].base64EncodedString())) }
        for index in 1...5 {
            #expect(wire.contains("retained-call-\(index)"))
            #expect(wire.contains("frameId=preserved-\(index)"))
        }
        let reopened = try await Harness.open(.sqlite(at: url), models: models, resume: false)
        let savedRoot = try await reopened.root()
        let saved = String(decoding: try encoder.encode(try await savedRoot.view().messages), as: UTF8.self)
        for bytes in images { #expect(saved.contains(bytes.base64EncodedString())) }
        #expect(!saved.contains("Older device screenshot omitted"))
        try await reopened.close()
    }

    struct StoreEndpoint: Sendable, CustomStringConvertible {
        let url: String
        let api: AgentAPI
        let sendsStore: Bool
        var description: String { "\(api.rawValue): \(url)" }
    }

    @Test(arguments: ["tool_calls", "stop"])
    func googleCompatibleProviderRoundTripsDeviceImageTool(_ finishReason: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-google-device-tools-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = AgentConfiguration(api: .openAICompletions,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!,
            model: "gemini-3.8-flash", apiKey: "google-device-tools-fixture-\(finishReason)-\(UUID())", supportsImages: true)
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

    @Test(arguments: [true, false])
    func googleToolSignaturesStayWithTheirCallsAcrossRoundsAndReopening(_ officialEndpoint: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-google-signatures-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = AgentConfiguration(api: .openAICompletions,
            baseURL: URL(string: officialEndpoint ? "https://generativelanguage.googleapis.com/v1beta/openai/" : "https://signatures.fixture.invalid/v1")!,
            model: "gemini-3.8-flash", apiKey: "google-signatures-fixture-\(UUID())", supportsImages: true)
        let arguments = OSAllocatedUnfairLock(initialState: [AgentJSONValue]())
        let probe = AgentTool(name: "device_screenshot", description: "Observe a fixture step",
            parameters: ["type": "object", "properties": ["step": ["type": "integer"]], "required": ["step"], "additionalProperties": false],
            mayHaveSideEffects: false) { value in
                arguments.withLock { $0.append(value) }
                return .image(Data(repeating: UInt8(arguments.withLock { $0.count }), count: 1024), mimeType: "image/png", caption: "Observed fixture step")
            }
        func makeClient(_ configuration: AgentConfiguration) -> AgentClient {
            let network = URLSessionConfiguration.ephemeral
            network.protocolClasses = [ProviderFixtureProtocol.self]
            let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
            return AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory,
                tools: [probe], modelFactory: { try await DefaultEngine.makeModels(configuration: configuration, runtime: runtime) }))
        }
        let id = UUID()
        let client = makeClient(configuration)
        var answers = 0
        for try await event in try await client.run(request: .init(conversationID: id, prompt: "Observe two rounds")) {
            if case .message(let message) = event, message.text == "Hello world" { answers += 1 }
        }
        #expect(answers == 1)
        #expect(arguments.withLock { $0 } == [["step": 1], ["step": 2], ["step": 3]])

        // New Models and JavaScript runtime ensure signatures come from SQLite,
        // not a previous request's in-memory capture map. Completed calls stay done.
        let reopened = makeClient(configuration)
        #expect(try await !reopened.recover(conversationID: id).hasInterruptedRun)
        for try await event in try await reopened.run(request: .init(conversationID: id, prompt: "A follow-up after reopening")) {
            if case .message(let message) = event, message.text == "Hello world" { answers += 1 }
            if case .toolStarted = event { Issue.record("Completed fixture tools must not replay on reopen.") }
        }
        #expect(answers == 2)
        #expect(arguments.withLock { $0 } == [["step": 1], ["step": 2], ["step": 3]])

        var changedConfiguration = configuration
        changedConfiguration.model = "different-fixture-model"
        let switched = makeClient(changedConfiguration)
        for try await event in try await switched.run(request: .init(conversationID: id, prompt: "Continue with a different model")) {
            if case .message(let message) = event, message.text == "Hello world" { answers += 1 }
            if case .toolStarted = event { Issue.record("Changing model must not replay completed tools.") }
        }
        #expect(answers == 3)
        #expect(arguments.withLock { $0 } == [["step": 1], ["step": 2], ["step": 3]])

        let requests = ProviderFixtureProtocol.requests.withLock {
            $0.filter { $0.authorization == "Bearer \(configuration.apiKey)" }
        }
        #expect(requests.count == 5)
        #expect(requests.last?.body["model"] == "different-fixture-model")
        let expectedIDs = ["signed-call-1", "unsigned-call-1", "signed-call-2"]
        for (index, request) in requests.enumerated().dropFirst() {
            let messages = try #require(request.body["messages"]?.arrayValue)
            let calls = messages.flatMap { $0["tool_calls"]?.arrayValue ?? [] }
            let wireImages = messages.flatMap { $0["content"]?.arrayValue ?? [] }.filter { $0["type"] == "image_url" }
            #expect(wireImages.count == 2)
            let imageBytes = wireImages.compactMap { block -> Data? in
                guard let url = block["image_url"]?["url"]?.stringValue, let comma = url.firstIndex(of: ",") else { return nil }
                return Data(base64Encoded: String(url[url.index(after: comma)...]))
            }
            #expect(imageBytes.reduce(0) { $0 + $1.count } == 2048)
            let count = index == 1 ? 2 : 3
            #expect(imageBytes.compactMap(\.first) == (count == 2 ? [1, 2] : [2, 3]))
            #expect(calls.compactMap { $0["id"]?.stringValue } == Array(expectedIDs.prefix(count)))
            #expect(messages.filter { $0["role"] == "tool" }.compactMap { $0["tool_call_id"]?.stringValue } == Array(expectedIDs.prefix(count)))
            for (callIndex, call) in calls.enumerated() {
                let sameModel = request.body["model"] == .string(configuration.model)
                let expectedSignature: AgentJSONValue? = !officialEndpoint || !sameModel || callIndex == 1 ? nil
                    : .string(callIndex == 0 ? ProviderFixtureProtocol.firstSignature : ProviderFixtureProtocol.secondSignature)
                #expect(call["extra_content"]?["google"]?["thought_signature"] == expectedSignature)
                if expectedSignature == nil { #expect(call["extra_content"] == nil) }
                let rawArguments = try #require(call["function"]?["arguments"]?.stringValue)
                let decoded = try JSONDecoder().decode(AgentJSONValue.self, from: Data(rawArguments.utf8))
                #expect(decoded == ["step": .number(Double(callIndex + 1))])
            }
        }
    }

    @Test(arguments: ["length", "content_filter", "other-endpoint", "malformed-stop"])
    func abnormalToolRepliesDoNotAuthorizeExecution(_ scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-unhandled-tools-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = AgentConfiguration(api: .openAICompletions,
            baseURL: URL(string: scenario == "other-endpoint" ? "https://unhandled.fixture.invalid/v1" : "https://generativelanguage.googleapis.com/v1beta/openai/")!,
            model: "gemini-3.8-flash", apiKey: "google-device-tools-fixture-\(scenario)-\(UUID())")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let screenshot = AgentTool(name: "device_screenshot", description: "Observe",
            parameters: ["type": "object", "properties": [:], "additionalProperties": false], mayHaveSideEffects: false) { _ in
            calls.withLock { $0 += 1 }
            return .text("Unexpected execution")
        }
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ProviderFixtureProtocol.self]
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
        let client = AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory,
            tools: [screenshot], modelFactory: { try await DefaultEngine.makeModels(configuration: configuration, runtime: runtime) }))
        var completed = false
        do {
            for try await event in try await client.run(request: .init(conversationID: UUID(), prompt: "Observe")) {
                if event == .finished(.completed) { completed = true }
            }
            Issue.record("A rejected or unhandled tool response must not complete silently.")
        } catch let error as AgentError {
            if scenario == "content_filter" {
                guard case .modelRequestFailed(let message) = error else { throw error }
                #expect(message.contains("content_filter"))
            } else {
                let expected = NSLocalizedString("agent.runtime.unhandled-tools", bundle: .module,
                                                 value: "MISSING RESOURCE", comment: "")
                #expect(error == .runtime(expected))
            }
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(!completed)
        #expect(calls.withLock { $0 } == 0)
        #expect(ProviderFixtureProtocol.requests.withLock {
            $0.filter { $0.authorization == "Bearer \(configuration.apiKey)" }.count
        } == 1)
    }

    @Test func completedHistoryWithAnUnexecutedToolCallIsNotReplayed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-old-unhandled-tool-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let models = Models(credentials: .inMemory, builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        try await faux.append([FauxResponse(.toolCall("device_screenshot", [:], id: "old-call"), stopReason: .stop)])
        let harness = try await Harness.open(.sqlite(at: directory.appendingPathComponent(id.uuidString.lowercased() + ".sqlite")),
                                             models: models, resume: false)
        let conversation = try await harness.root(agent: AgentChange(model: faux.model))
        let submission = try await conversation.submit("Old request", requestId: "old-request")
        try await harness.resume()
        let settled = try await submission.wait()
        guard case .done = settled.status else { Issue.record("The old runtime must mark this anomaly done."); return }
        let oldView = try await conversation.view()
        #expect(oldView.entries.last?.assistantMessage?.stopReason == .stop)
        #expect(oldView.entries.last?.assistantMessage?.toolCalls.first?.id == "old-call")
        try await harness.close()

        let configuration = AgentConfiguration(api: .openAICompletions,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!,
            model: "gemini-3.8-flash", apiKey: "old-tool-history-fixture-\(UUID())")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let screenshot = AgentTool(name: "device_screenshot", description: "Observe",
            parameters: ["type": "object", "properties": [:], "additionalProperties": false], mayHaveSideEffects: false) { _ in
            calls.withLock { $0 += 1 }
            return .text("Old calls must remain unexecuted")
        }
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ProviderFixtureProtocol.self]
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
        let client = AgentClient(engine: DefaultEngine(configuration: configuration, storageDirectory: directory,
            tools: [screenshot], modelFactory: { try await DefaultEngine.makeModels(configuration: configuration, runtime: runtime) }))
        #expect(try await !client.recover(conversationID: id).hasInterruptedRun)
        var receivedAnswer = false
        for try await event in try await client.run(request: .init(conversationID: id, prompt: "A new question")) {
            if case .message(let message) = event, message.text == "Hello world" { receivedAnswer = true }
            if case .toolStarted = event { Issue.record("An old completed tool call must not restart.") }
        }
        #expect(receivedAnswer)
        #expect(calls.withLock { $0 } == 0)
        #expect(ProviderFixtureProtocol.requests.withLock {
            $0.filter { $0.authorization == "Bearer \(configuration.apiKey)" }.count
        } == 1)
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
        if recorded.authorization?.hasPrefix("Bearer google-signatures-fixture-") == true {
            let resultCount = recorded.body["messages"]?.arrayValue?.filter { $0["role"] == "tool" }.count ?? 0
            if resultCount == 0 { chunks = Self.signedToolCalls(round: 1) }
            else if resultCount == 2 { chunks = Self.signedToolCalls(round: 2) }
            else { chunks = Self.completions }
        }
        else if recorded.authorization?.hasPrefix("Bearer google-device-tools-fixture-") == true,
           !(recorded.body["messages"]?.arrayValue?.contains { $0["role"] == "tool" } ?? false) {
            let finishReason: String
            if recorded.authorization?.contains("-length-") == true { finishReason = "length" }
            else if recorded.authorization?.contains("-content_filter-") == true { finishReason = "content_filter" }
            else if recorded.authorization?.contains("-stop-") == true || recorded.authorization?.contains("-other-endpoint-") == true { finishReason = "stop" }
            else { finishReason = "tool_calls" }
            let arguments = recorded.authorization?.contains("-malformed-stop-") == true ? "{" : "{}"
            chunks = Self.deviceToolCall(finishReason: finishReason, arguments: arguments)
        }
        else if url.path.hasSuffix("chat/completions") { chunks = Self.completions }
        else if url.path.hasSuffix("responses") { chunks = Self.responses }
        else { chunks = Self.anthropic }
        work.withLock { task in
            task = Task { @Sendable [self, chunks] in
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

    static func deviceToolCall(finishReason: String, arguments: String = "{}") -> [String] {
        [
            // The provider may add the numeric index after identifying the call.
            sse(#"{"id":"c-tool","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{"tool_calls":[{"id":"screen-1","type":"function","function":{"name":"device_screenshot","arguments":"{"}}]},"finish_reason":null}]}"#),
            sse(#"{"id":"c-tool","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"screen-1","function":{"arguments":"\#(arguments.dropFirst())"}}]},"finish_reason":null}]}"#),
            sse(#"{"id":"c-tool","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{},"finish_reason":"\#(finishReason)"}]}"#),
            "data: [DONE]\n\n",
        ]
    }

    static let firstSignature = "fixture/opaque+round-1=="
    static let secondSignature = "fixture/opaque+round-2=="

    static func signedToolCalls(round: Int) -> [String] {
        let first: String
        let continuation: String
        let signature: String
        if round == 1 {
            first = #"{"index":0,"id":"signed-call-1","type":"function","function":{"name":"device_screenshot","arguments":"{"}}"#
            continuation = #"{"index":0,"function":{"arguments":"\"step\":1}"}},{"index":1,"id":"unsigned-call-1","type":"function","function":{"name":"device_screenshot","arguments":"{\"step\":2}"}}"#
            signature = firstSignature
        } else {
            first = #"{"index":0,"id":"signed-call-2","type":"function","function":{"name":"device_screenshot","arguments":"{"}}"#
            continuation = #"{"index":0,"function":{"arguments":"\"step\":3}"}}"#
            signature = secondSignature
        }
        func chunk(_ calls: String) -> String {
            sse(#"{"id":"signature-round-\#(round)","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{"tool_calls":[\#(calls)]},"finish_reason":null}]}"#)
        }
        return [
            chunk(first), chunk(continuation),
            // Google can supply this separately, without id/name/arguments.
            chunk(#"{"index":0,"extra_content":{"google":{"thought_signature":"\#(signature)"}}}"#),
            sse(#"{"id":"signature-round-\#(round)","object":"chat.completion.chunk","created":1,"model":"fixture-model","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
            "data: [DONE]\n\n",
        ]
    }

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
