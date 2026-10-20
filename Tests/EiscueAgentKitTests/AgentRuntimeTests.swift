import Foundation
import Testing
import PiDurableKit
@testable import EiscueAgentKit

@Suite("Agent runtime")
struct AgentRuntimeTests {
    @Test(arguments: [nil, .toolBudget, .noProgress, .verificationUnavailable, .connectionLost, .hostRequested] as [AgentPauseReason?])
    func mixedToolRoundPauseStopsBeforeAnotherModelRequest(reason: AgentPauseReason?) async throws {
        let evidence = RuntimeEvidence()
        let first = AgentTool(name: "first", description: "Observe", parameters: emptySchema,
                              mayHaveSideEffects: false, isVerification: true) { _ in
            await evidence.record("first"); return .text("Observed")
        }
        let pause = AgentTool(name: "pause", description: "Host-controlled action", parameters: emptySchema,
                              executionCost: 2, verifiesSideEffects: true) { _ in
            await evidence.record("paused")
            throw AgentToolError.paused(reason ?? .toolBudget)
        }
        let later = AgentTool(name: "later", description: "Must not run", parameters: emptySchema) { _ in
            await evidence.record("unexpected"); return .text("Wrong")
        }
        let fixture = try await RuntimeFixture(tools: [first, pause, later])
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("first", [:], id: "first"), .toolCall("pause", [:], id: "pause"),
                                      .toolCall("later", [:], id: "later"))
        try await fixture.faux.append(.toolCall("first", [:], id: "fresh"))
        try await fixture.faux.append(.text("Continued after a new request."))
        // Nil exercises the runtime's own reservation failure, before the host tool executes.
        let request = AgentRequest(conversationID: UUID(), prompt: "Work", maxToolCalls: reason == nil ? 1 : 30)
        let expected = reason.map(AgentError.toolExecutionPaused) ?? .toolLimitReached
        await #expect(throws: expected) { try await collect(fixture.client.run(request: request)) }
        let expectedCalls = reason == nil ? ["first"] : ["first", "paused"]
        #expect(await evidence.values == expectedCalls)
        let result = try await fixture.client.toolResult(conversationID: request.conversationID,
                                                        requestID: request.requestID, toolCallID: "pause")
        #expect(result?.result.outcome == (reason == nil ? .notExecuted : .failed))
        let recovery = try await fixture.client.recover(conversationID: request.conversationID)
        #expect(!recovery.hasInterruptedRun)
        #expect(recovery.messages.map(\.text) == ["Work"])
        try #require(try await fixture.faux.pendingResponseCount() == 2)
        await #expect(throws: AgentError.nothingToResume) {
            try await collect(fixture.client.run(request: .init(conversationID: request.conversationID, prompt: "", mode: .resume)))
        }
        let next = try await collect(fixture.client.run(request: .init(conversationID: request.conversationID, prompt: "Continue")))
        #expect(next.contains(.finished(.completed)))
        #expect(await evidence.values == expectedCalls + ["first"])
        #expect(try await fixture.faux.pendingResponseCount() == 0)
    }

    @Test(arguments: [false, true])
    func unknownOutcomeTerminatesAMixedToolRoundBeforeAnotherModelRequest(asResult: Bool) async throws {
        let evidence = RuntimeEvidence()
        let first = AgentTool(name: "first", description: "Known action", parameters: emptySchema) { _ in
            await evidence.record("first"); return .text("Done")
        }
        let unknown = AgentTool(name: "uncertain", description: "Unknown action", parameters: emptySchema) { _ in
            await evidence.record("unknown")
            if asResult { return .init(content: [.text("Unknown")], outcome: .unknown) }
            throw AgentToolError.outcomeUnknown
        }
        let later = AgentTool(name: "later", description: "Must not run", parameters: emptySchema) { _ in
            await evidence.record("unexpected"); return .text("Wrong")
        }
        let fixture = try await RuntimeFixture(tools: [first, unknown, later])
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("first", [:], id: "first"), .toolCall("uncertain", [:], id: "unknown"), .toolCall("later", [:], id: "later"))
        try await fixture.faux.append(.text("Must remain unused"))
        let request = AgentRequest(conversationID: UUID(), prompt: "Act")
        let events = try await collect(fixture.client.run(request: request))
        #expect(events.contains(.finished(.stopped(.outcomeUnknown(toolName: "uncertain")))))
        #expect(!events.contains(.finished(.completed)))
        #expect(await evidence.values == ["first", "unknown"])
        #expect(try await fixture.faux.pendingResponseCount() == 1)
        let result = try await fixture.client.toolResult(conversationID: request.conversationID, requestID: request.requestID, toolCallID: "unknown")
        #expect(result?.result.outcome == .unknown)
        let skipped = try await fixture.client.toolResult(conversationID: request.conversationID, requestID: request.requestID, toolCallID: "later")
        #expect(skipped?.result.outcome == .notExecuted)
        #expect(try await !fixture.client.recover(conversationID: request.conversationID).hasInterruptedRun)
        // An explicit fresh request can inspect the state; the old unknown result does not block it.
        let next = try await collect(fixture.client.run(request: .init(conversationID: request.conversationID, prompt: "I checked the result. Continue.")))
        #expect(next.contains(.finished(.completed)))
    }

    @Test func successfulWorkKeepsItsOutcomeWhenStorageCloseFails() async throws {
        let fixture = try await RuntimeFixture(closeOperation: { harness in
            try await harness.close(); throw AgentError.runtime("Injected close failure")
        })
        defer { fixture.remove() }
        try await fixture.faux.append(.text("Completed answer"))
        let events = try await collect(fixture.client.run(request: .init(conversationID: UUID(), prompt: "Work")))
        #expect(events.contains(.cleanupFailed("Injected close failure")))
        #expect(events.last == .finished(.completed))
    }

    @Test func lateCancelReportsEndedCloseFailureButDoesNotReplaceANewerRunsCleanup() async throws {
        let closes = RuntimeEvidence(), toolWork = RuntimeEvidence()
        let slow = AgentTool(name: "slow", description: "Wait", parameters: emptySchema) { _ in
            await toolWork.record("started"); try await Task.sleep(for: .seconds(30)); return .text("Wrong")
        }
        let fixture = try await RuntimeFixture(tools: [slow], closeOperation: { harness in
            try await harness.close()
            await closes.record("closed")
            if await closes.values.count == 1 { throw AgentError.runtime("Ended close failure") }
        })
        defer { fixture.remove() }
        try await fixture.faux.append(.text("Completed answer"))
        let first = AgentRequest(conversationID: UUID(), prompt: "First")
        let events = try await collect(fixture.client.run(request: first))
        #expect(events.last == .finished(.completed))
        #expect(events.contains(.cleanupFailed("Ended close failure")))
        await #expect(throws: AgentError.cleanupFailed("Ended close failure")) { try await fixture.client.cancel() }
        await #expect(throws: AgentError.cleanupFailed("Ended close failure")) { try await fixture.client.cancel(conversationID: first.conversationID) }
        let reader = AgentClient(storageDirectory: fixture.directory)
        await #expect(throws: AgentError.busy) { try await reader.recover(conversationID: first.conversationID) }

        try await fixture.faux.append(.toolCall("slow", [:]))
        let next = AgentRequest(conversationID: UUID(), prompt: "New run")
        let work = Task { try await collect(fixture.client.run(request: next)) }
        try await eventually { await toolWork.values == ["started"] }
        try await fixture.client.cancel()
        #expect(try await work.value.last == .finished(.cancelled))
        try await fixture.client.cancel()
        #expect(await closes.values.count == 2)
    }

    @Test func cancellingReportsCloseFailureAndKeepsTheDatabaseOwned() async throws {
        let evidence = RuntimeEvidence()
        let slow = AgentTool(name: "slow", description: "Wait", parameters: emptySchema) { _ in
            await evidence.record("started"); try await Task.sleep(for: .seconds(30)); return .text("Wrong")
        }
        let fixture = try await RuntimeFixture(tools: [slow], closeOperation: { harness in
            try await harness.close()
            throw AgentError.runtime("Injected close failure")
        })
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("slow", [:]))
        let request = AgentRequest(conversationID: UUID(), prompt: "Work")
        let reader = Task { try await collect(fixture.client.run(request: request)) }
        try await eventually { await evidence.values == ["started"] }
        await #expect(throws: AgentError.cleanupFailed("Injected close failure")) { try await fixture.client.cancel() }
        let events = try await reader.value
        #expect(events.contains(.cleanupFailed("Injected close failure")))
        #expect(events.contains(.finished(.cancelled)))
        let other = AgentClient(storageDirectory: fixture.directory)
        await #expect(throws: AgentError.busy) { try await other.recover(conversationID: request.conversationID) }
        await #expect(throws: AgentError.busy) { try await other.removeConversation(id: request.conversationID) }
    }

    @Test func processWideOwnershipRejectsAnotherEngineUntilCloseCompletes() async throws {
        let evidence = RuntimeEvidence()
        let slow = AgentTool(name: "slow", description: "Wait", parameters: emptySchema) { _ in
            await evidence.record("started"); try await Task.sleep(for: .seconds(30)); return .text("Wrong")
        }
        let fixture = try await RuntimeFixture(tools: [slow])
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("slow", [:]))
        let request = AgentRequest(conversationID: UUID(), prompt: "Work")
        let reader = Task { try await collect(fixture.client.run(request: request)) }
        try await eventually { await evidence.values == ["started"] }
        let other = AgentClient(storageDirectory: fixture.directory.appendingPathComponent("..", isDirectory: true).appendingPathComponent(fixture.directory.lastPathComponent))
        await #expect(throws: AgentError.busy) { try await other.recover(conversationID: request.conversationID) }
        await #expect(throws: AgentError.busy) { try await other.cancel(conversationID: request.conversationID) }
        await #expect(throws: AgentError.busy) { try await other.removeConversation(id: request.conversationID) }
        try await fixture.client.cancel()
        _ = try await reader.value
        #expect(try await !other.recover(conversationID: request.conversationID).hasInterruptedRun)
    }

    @Test func endpointValidationRequiresHTTPSOrAnExplicitLiteralLoopbackException() throws {
        for endpoint in ["http://example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#part", "https://u:p@example.com/v1", "http://127.0.0.1:18765/v1"] {
            var configuration = testConfiguration; configuration.baseURL = URL(string: endpoint)!
            #expect(throws: AgentError.self) { try configuration.validate() }
        }
        for endpoint in ["http://127.0.0.1:18765/v1", "http://[::1]:18765/v1", "http://localhost:18765/v1"] {
            var configuration = testConfiguration; configuration.baseURL = URL(string: endpoint)!; configuration.allowsLoopbackHTTP = true
            try configuration.validate()
        }
        var remote = testConfiguration; remote.baseURL = URL(string: "http://127.0.0.1.evil.invalid/v1")!; remote.allowsLoopbackHTTP = true
        #expect(throws: AgentError.self) { try remote.validate() }
    }

    @Test func legacyToolResultsInferTheirTypedOutcomeWithoutMetadata() throws {
        for failed in [false, true] {
            let json: PiDurableKit.JSONValue = ["role": "toolResult", "toolCallId": "legacy", "toolName": "old", "isError": .bool(failed), "timestamp": 1, "content": [["type": "text", "text": "Legacy result"]]]
            let result = RuntimeMapping.result(try json.decode(as: ToolResultMessage.self))
            #expect(result.outcome == (failed ? .failed : .succeeded))
            #expect(result.text == "Legacy result")
        }
    }

    @Test func attachmentMetadataReferencesDurableContentAcrossImportRetryAndReopen() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.remove() }
        let photo = AgentAttachment(name: "named-photo.png", mimeType: "image/png", content: .image(Data(repeating: 9, count: 65_536)))
        let document = AgentAttachment(name: "notes.txt", mimeType: "text/plain", content: .text("document-content-unique"))
        let history = [AgentMessage(role: .user, text: "Imported", attachments: [photo, document]),
                       AgentMessage(role: .assistant, text: "Imported reply")]
        try await fixture.faux.respond { _, count in
            #expect(count == 1)
            return .text("New reply")
        }
        let request = AgentRequest(conversationID: UUID(), prompt: "Current", history: history, attachments: [photo, document])
        try await collect(fixture.client.run(request: request))
        try await collect(fixture.client.run(request: request))
        let harness = try await Harness.open(.sqlite(at: fixture.fileURL(request.conversationID)), models: fixture.models, resume: false)
        let root = try await harness.root()
        let entries = try await root.entries().items
        let metadata = entries.compactMap { $0.data?["eiscueMessageReference"] }
        #expect(metadata.count == 2)
        for reference in metadata {
            let encoded = try JSONEncoder().encode(reference)
            #expect(encoded.count < 1024)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("document-content-unique"))
        }
        #expect(!entries.contains { $0.data?["eiscueMessage"] != nil })
        try await harness.close()
        let recovered = try await AgentClient(storageDirectory: fixture.directory).recover(conversationID: request.conversationID)
        #expect(recovered.messages.first == history[0])
        #expect(recovered.messages[1].id == history[1].id)
        #expect(recovered.messages[1].text == history[1].text)
        #expect(recovered.messages.filter { $0.role == .user }.map(\.id) == [history[0].id, request.requestID])
        #expect(recovered.messages.filter { $0.role == .user }.allSatisfy { $0.attachments == [photo, document] })
    }

    @Test func deviceImagesAreBoundedOnlyInRequestsAndNeverReplayOnRecovery() async throws {
        let evidence = RuntimeEvidence()
        let action = AgentTool(name: "capture_after_action", description: "Fixture input with observation", parameters: emptySchema,
            executionCost: 2, verifiesSideEffects: true, contextImagePolicy: .latest(2)) { _ in
                await evidence.record("tap")
                let step = await evidence.values.count
                return .image(Data(repeating: UInt8(step), count: 1024), mimeType: "image/png", caption: "frameId=frame-\(step)")
            }
        let fixture = try await RuntimeFixture(tools: [action])
        defer { fixture.remove() }
        try await fixture.faux.respond { messages, count in
            let results = messages.compactMap { message -> ToolResultMessage? in
                if case .toolResult(let result) = message { result } else { nil }
            }
            let images = results.flatMap(\.content).compactMap { block -> Data? in
                if case .image(let image) = block { image.bytes } else { nil }
            }
            let expectedResults = min(count - 1, 4)
            #expect(results.count == expectedResults)
            #expect(images.count == min(expectedResults, 2))
            #expect(images.reduce(0) { $0 + $1.count } == min(expectedResults, 2) * 1024)
            #expect(results.enumerated().allSatisfy { index, result in
                result.toolCallId == "tap-\(index + 1)" && result.text.contains("frameId=frame-\(index + 1)")
            })
            if expectedResults > 2 {
                #expect(images.first?.first == UInt8(expectedResults - 1))
                #expect(images.last?.first == UInt8(expectedResults))
                #expect(results.first?.text.contains("Older tool image omitted") == true)
            }
            return count <= 4 ? FauxResponse(.toolCall("capture_after_action", [:], id: "tap-\(count)")) : .text("Done")
        }
        let request = AgentRequest(conversationID: UUID(), prompt: "Four fixture inputs")
        try await collect(fixture.client.run(request: request))
        #expect(await evidence.values.count == 4)
        let reader = AgentClient(storageDirectory: fixture.directory)
        #expect(try await !reader.recover(conversationID: request.conversationID).hasInterruptedRun)
        for step in 1...4 {
            let completion = try #require(try await reader.toolResult(conversationID: request.conversationID,
                requestID: request.requestID, toolCallID: "tap-\(step)"))
            #expect(completion.result.content.contains(.image(data: Data(repeating: UInt8(step), count: 1024), mimeType: "image/png")))
            #expect(!completion.result.text.contains("Older tool image omitted"))
        }
        // Reopen with no registered tools: persisted image policy still applies, and no input replays.
        let reopened = AgentClient(engine: DefaultEngine(configuration: testConfiguration, storageDirectory: fixture.directory,
            modelFactory: { (fixture.models, fixture.faux.model) }))
        try await collect(reopened.run(request: .init(conversationID: request.conversationID, prompt: "Continue as chat")))
        #expect(await evidence.values.count == 4)
    }

    @Test func toolHistoryRestoresExactRequestAndConversationAfterResetWithoutRunningAnything() async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Observe", parameters: emptySchema, mayHaveSideEffects: false) { _ in
            await evidence.record("capture")
            return .image(Data([UInt8(await evidence.values.count)]), mimeType: "image/png")
        }
        let fixture = try await RuntimeFixture(tools: [capture])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            count.isMultiple(of: 2) ? .text("Done") : FauxResponse(.toolCall("capture", [:], id: "reused-call"))
        }
        let conversationID = UUID()
        let requests = [AgentRequest(conversationID: conversationID, prompt: "Observe"),
                        AgentRequest(conversationID: conversationID, prompt: "Observe"),
                        AgentRequest(conversationID: UUID(), prompt: "Observe")]
        for request in requests { try await collect(fixture.client.run(request: request)) }
        let harness = try await Harness.open(.sqlite(at: fixture.fileURL(conversationID)), models: fixture.models, resume: false)
        let root = try await harness.root()
        try await root.reset()
        try await harness.close()
        let before = try Data(contentsOf: fixture.fileURL(conversationID))
        let reader = AgentClient(storageDirectory: fixture.directory)
        for (index, request) in requests.enumerated() {
            let restored = try await reader.toolResult(conversationID: request.conversationID,
                requestID: request.requestID, toolCallID: "reused-call")
            #expect(restored?.call.name == "capture")
            #expect(restored?.result.content == [.image(data: Data([UInt8(index + 1)]), mimeType: "image/png")])
        }
        #expect(try await reader.toolResult(conversationID: conversationID, requestID: requests[2].requestID, toolCallID: "reused-call") == nil)
        #expect(try await reader.toolResult(conversationID: conversationID, requestID: requests[0].requestID, toolCallID: "unknown") == nil)
        #expect(try Data(contentsOf: fixture.fileURL(conversationID)) == before)
        #expect(await evidence.values == ["capture", "capture", "capture"])
    }

    @Test func toolHistoryReadsCommittedImageWhileTheRuntimeIsStillGenerating() async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Observe", parameters: emptySchema, mayHaveSideEffects: false) { _ in
            await evidence.record("capture")
            return .image(Data([7]), mimeType: "image/png")
        }
        let fixture = try await RuntimeFixture(tools: [capture])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            if count == 1 { return FauxResponse(.toolCall("capture", [:], id: "call")) }
            try await Task.sleep(for: .milliseconds(500))
            return .text("Done")
        }
        let request = AgentRequest(conversationID: UUID(), prompt: "Observe")
        var restored = false
        for try await event in try await fixture.client.run(request: request) {
            if case .toolFinished = event {
                let separateReader = AgentClient(storageDirectory: fixture.directory)
                for reader in [fixture.client, separateReader] {
                    let result = try await reader.toolResult(conversationID: request.conversationID, requestID: request.requestID, toolCallID: "call")
                    #expect(result?.result.content == [.image(data: Data([7]), mimeType: "image/png")])
                }
                restored = true
            }
        }
        #expect(restored)
        #expect(await evidence.values == ["capture"])
    }

    @Test func toolHistoryDoesNotCreateMissingStorageOrResumeQueuedWork() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.remove() }
        let request = AgentRequest(conversationID: UUID(), prompt: "Queued")
        let reader = AgentClient(storageDirectory: fixture.directory)
        #expect(try await reader.toolResult(conversationID: request.conversationID, requestID: request.requestID, toolCallID: "call") == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL(request.conversationID).path))
        let harness = try await Harness.open(.sqlite(at: fixture.fileURL(request.conversationID)), models: fixture.models, resume: false)
        let root = try await harness.root(agent: AgentChange(model: fixture.faux.model))
        try await root.submit(request.prompt, requestId: request.requestID.uuidString)
        try await harness.close()
        try await fixture.faux.append(.text("Not yet"))
        let before = try Data(contentsOf: fixture.fileURL(request.conversationID))
        #expect(try await reader.toolResult(conversationID: request.conversationID, requestID: request.requestID, toolCallID: "call") == nil)
        #expect(try Data(contentsOf: fixture.fileURL(request.conversationID)) == before)
        #expect(try await fixture.faux.pendingResponseCount() == 1)
        #expect(try await reader.recover(conversationID: request.conversationID).hasInterruptedRun)
    }

    @Test func toolHistoryRejectsAmbiguousCallReuseWithinOneRequest() async throws {
        let capture = AgentTool(name: "capture", description: "Observe", parameters: emptySchema, mayHaveSideEffects: false) { _ in
            .image(Data([1]), mimeType: "image/png")
        }
        let fixture = try await RuntimeFixture(tools: [capture])
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("capture", [:], id: "duplicate"))
        try await fixture.faux.append(.text("Done"))
        let request = AgentRequest(conversationID: UUID(), prompt: "Observe")
        try await collect(fixture.client.run(request: request))
        let harness = try await Harness.open(.sqlite(at: fixture.fileURL(request.conversationID)), models: fixture.models, resume: false)
        let root = try await harness.root()
        let entry = try #require(try await root.entries().items.first { $0.toolResult != nil })
        try await root.write(EntryDraft(kind: entry.kind, model: entry.model))
        try await harness.close()
        #expect(try await fixture.client.toolResult(conversationID: request.conversationID, requestID: request.requestID, toolCallID: "duplicate") == nil)
    }

    @Test func configurationIsValidatedBeforeAnyWork() async throws {
        let client = AgentClient()
        #expect(await client.availability == .unconfigured)
        await #expect(throws: AgentError.unconfigured) {
            try await client.run(request: AgentRequest(conversationID: UUID(), prompt: "hello"))
        }
        var configuration = testConfiguration
        configuration.baseURL = URL(string: "file:///tmp/not-an-endpoint")!
        #expect(throws: AgentError.self) { try configuration.validate() }
        configuration = testConfiguration
        configuration.maxOutputTokens = configuration.contextWindow + 1
        #expect(throws: AgentError.self) { try configuration.validate() }
    }

    @Test func realRuntimeLoopsThroughImageToolAndKeepsMultiTurnContext() async throws {
        let images = Data([137, 80, 78, 71])
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Observe", parameters: emptySchema, mayHaveSideEffects: false) { _ in
            await evidence.record("capture")
            return .image(images, mimeType: "image/png", caption: "Current display")
        }
        let fixture = try await RuntimeFixture(tools: [capture])
        defer { fixture.remove() }
        try await fixture.faux.respond { messages, count in
            if count == 1 { return FauxResponse(.toolCall("capture", [:], id: "capture-1")) }
            if count == 2 {
                let image = messages.compactMap { message -> ImageContent? in
                    guard case .toolResult(let result) = message else { return nil }
                    for block in result.content { if case .image(let image) = block { return image } }
                    return nil
                }.first
                #expect(image?.bytes == images)
                return .text("I can see the screen.")
            }
            #expect(messages.contains { $0.text == "I can see the screen." })
            #expect(messages.contains { $0.text == "What did you just see?" })
            return .text("The same screen as before.")
        }
        let id = UUID()
        let first = try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "Observe")))
        #expect(first.contains(.finished(.completed)))
        #expect(first.contains { if case .toolStarted(let call) = $0 { call.id == "capture-1" } else { false } })
        #expect(first.contains { if case .toolFinished(let completion) = $0 {
            completion.result.content.contains(.image(data: images, mimeType: "image/png"))
        } else { false } })
        let committed = try #require(first.compactMap { event -> AgentMessage? in
            if case .message(let message) = event { return message }; return nil
        }.last)
        #expect(committed.text == "I can see the screen.")
        #expect(first.contains(.assistantText(committed.text)))
        let reopened = try await fixture.client.recover(conversationID: id)
        #expect(reopened.messages.last == committed)
        #expect(!reopened.hasInterruptedRun)
        let second = try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "What did you just see?")))
        #expect(second.contains { if case .message(let message) = $0 { message.text == "The same screen as before." } else { false } })
        #expect(await evidence.values == ["capture"])
    }

    @Test func toolLimitPreventsFurtherSideEffects() async throws {
        let evidence = RuntimeEvidence()
        let tool = AgentTool(name: "act", description: "Action", parameters: emptySchema) { _ in
            await evidence.record("action")
            return .text("Done")
        }
        let fixture = try await RuntimeFixture(tools: [tool])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, _ in FauxResponse(.toolCall("act", [:])) }
        let id = UUID()
        await #expect(throws: AgentError.toolLimitReached) {
            try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "Work", maxToolCalls: 1)))
        }
        #expect(await evidence.values == ["action"])
        #expect(try await !fixture.client.recover(conversationID: id).hasInterruptedRun)
    }

    @Test func verificationCanUseTheLastSlotAndTheModelCanFinish() async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Verify", parameters: emptySchema,
                                mayHaveSideEffects: false, isVerification: true) { _ in
            await evidence.record("capture")
            return .text("Observed")
        }
        let action = AgentTool(name: "act", description: "Action", parameters: emptySchema) { _ in
            await evidence.record("action")
            return .text("Sent")
        }
        let fixture = try await RuntimeFixture(tools: [capture, action])
        defer { fixture.remove() }
        try await fixture.faux.respond { messages, count in
            switch count {
            case 1, 3: return FauxResponse(.toolCall("capture", [:]))
            case 2: return FauxResponse(.toolCall("act", [:]))
            default:
                #expect(count == 4)
                #expect(messages.contains { $0.text.contains("Remaining execution units: 1.") })
                return .text("Verified the result.")
            }
        }
        let id = UUID()
        let events = try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "Work", maxToolCalls: 3)))
        #expect(events.contains(.finished(.completed)))
        #expect(await evidence.values == ["capture", "action", "capture"])
        #expect(try await !fixture.client.recover(conversationID: id).hasInterruptedRun)
    }

    @Test func lastSlotCannotStartAnUnverifiableAction() async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Verify", parameters: emptySchema,
                                mayHaveSideEffects: false, isVerification: true) { _ in
            await evidence.record("capture")
            return .text("Observed")
        }
        let action = AgentTool(name: "act", description: "Action", parameters: emptySchema) { _ in
            await evidence.record("should-not-start")
            return .text("Sent")
        }
        let fixture = try await RuntimeFixture(tools: [capture, action])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            #expect(count <= 2)
            return FauxResponse(.toolCall(count == 1 ? "capture" : "act", [:]))
        }
        let id = UUID()
        var events: [EiscueAgentKit.AgentEvent] = []
        do {
            for try await event in try await fixture.client.run(request: .init(conversationID: id, prompt: "Work", maxToolCalls: 2)) {
                events.append(event)
            }
            Issue.record("The final action should be rejected")
        } catch { #expect(error as? AgentError == .toolLimitReached) }
        #expect(!events.contains(.finished(.completed)))
        #expect(await evidence.values == ["capture"])
        #expect(try await !fixture.client.recover(conversationID: id).hasInterruptedRun)
    }

    @Test(arguments: [2, 3])
    func actionReservesTheLeastRegisteredVerificationCost(limit: Int) async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Verify", parameters: emptySchema,
                                mayHaveSideEffects: false, isVerification: true, executionCost: 2) { _ in
            await evidence.record("capture")
            return .text("Observed")
        }
        let expensive = AgentTool(name: "expensive", description: "Costlier verification", parameters: emptySchema,
                                  mayHaveSideEffects: false, isVerification: true, executionCost: 3) { _ in
            Issue.record("The model selected the cheaper verification tool")
            return .text("Unexpected")
        }
        let action = AgentTool(name: "act", description: "Action", parameters: emptySchema) { _ in
            await evidence.record("action")
            return .text("Sent")
        }
        let fixture = try await RuntimeFixture(tools: [capture, expensive, action])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            switch count {
            case 1: return FauxResponse(.toolCall("act", [:]))
            case 2: return FauxResponse(.toolCall("capture", [:]))
            default: return .text("Verified")
            }
        }
        let request = AgentRequest(conversationID: UUID(), prompt: "Work", maxToolCalls: limit)
        if limit == 2 {
            await #expect(throws: AgentError.toolLimitReached) { try await collect(fixture.client.run(request: request)) }
            #expect(await evidence.values.isEmpty, "Do not dispatch an action whose observation cannot fit.")
        } else {
            let events = try await collect(fixture.client.run(request: request))
            #expect(events.contains(.finished(.completed)))
            #expect(await evidence.values == ["action", "capture"])
        }
    }

    @Test func unrelatedReadOnlyWorkCannotConsumeCostlierVerificationReservation() async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Verify", parameters: emptySchema,
                                mayHaveSideEffects: false, isVerification: true, executionCost: 2) { _ in .text("Observed") }
        let action = AgentTool(name: "act", description: "Action", parameters: emptySchema) { _ in
            await evidence.record("action")
            return .text("Sent")
        }
        let list = AgentTool(name: "list", description: "Read metadata", parameters: emptySchema,
                             mayHaveSideEffects: false) { _ in
            await evidence.record("must-not-list")
            return .text("Unexpected")
        }
        let fixture = try await RuntimeFixture(tools: [capture, action, list])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            #expect(count <= 2)
            return FauxResponse(.toolCall(count == 1 ? "act" : "list", [:]))
        }
        await #expect(throws: AgentError.toolLimitReached) {
            try await collect(fixture.client.run(request: .init(conversationID: UUID(), prompt: "Work", maxToolCalls: 3)))
        }
        #expect(await evidence.values == ["action"])
    }

    @Test func compoundActionUsesTheFinalTwoUnitsAndReturnsItsObservation() async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Observe", parameters: emptySchema,
                                mayHaveSideEffects: false, isVerification: true) { _ in
            await evidence.record("capture")
            return .text("Initial observation")
        }
        let action = AgentTool(name: "act", description: "Act and verify", parameters: emptySchema,
                               executionCost: 2, verifiesSideEffects: true) { _ in
            await evidence.record("action")
            await evidence.record("verification")
            return .image(Data([137, 80, 78, 71]), mimeType: "image/png", caption: "Verified observation")
        }
        let fixture = try await RuntimeFixture(tools: [capture, action])
        defer { fixture.remove() }
        try await fixture.faux.respond { messages, count in
            switch count {
            case 1: return FauxResponse(.toolCall("capture", [:]))
            case 2: return FauxResponse(.toolCall("act", [:]))
            default:
                #expect(count == 3)
                #expect(messages.contains { $0.text.contains("Verified observation") })
                #expect(!messages.contains { $0.text.contains("Use the verification tool now") })
                return .text("Observed the result.")
            }
        }
        let events = try await collect(fixture.client.run(request: .init(conversationID: UUID(), prompt: "Work", maxToolCalls: 3)))
        #expect(events.contains(.finished(.completed)))
        #expect(await evidence.values == ["capture", "action", "verification"])
    }

    @Test func compoundActionReservesBothUnitsBeforeAnySideEffect() async throws {
        let evidence = RuntimeEvidence()
        let action = AgentTool(name: "act", description: "Act and verify", parameters: emptySchema,
                               executionCost: 2, verifiesSideEffects: true) { _ in
            await evidence.record("must-not-act")
            return .text("Verified")
        }
        let fixture = try await RuntimeFixture(tools: [action])
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("act", [:]))
        let id = UUID()
        await #expect(throws: AgentError.toolLimitReached) {
            try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "Work", maxToolCalls: 1)))
        }
        #expect(await evidence.values.isEmpty)
        #expect(try await !fixture.client.recover(conversationID: id).hasInterruptedRun)
    }

    @Test(arguments: [false, true])
    func compoundVerificationDischargesReservationOnlyOnSuccess(fails: Bool) async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Observe", parameters: emptySchema,
                                mayHaveSideEffects: false, isVerification: true) { _ in .text("Observed") }
        let action = AgentTool(name: "act", description: "Act and verify", parameters: emptySchema,
                               executionCost: 2, verifiesSideEffects: true) { _ in
            await evidence.record("action")
            return fails ? .error("Observation unavailable") : .text("Observed result")
        }
        let list = AgentTool(name: "list", description: "Read metadata", parameters: emptySchema,
                             mayHaveSideEffects: false) { _ in
            await evidence.record("list")
            return .text("Metadata")
        }
        let fixture = try await RuntimeFixture(tools: [capture, action, list])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            switch count {
            case 1: return FauxResponse(.toolCall("act", [:]))
            case 2: return FauxResponse(.toolCall("list", [:]))
            default: return .text("Finished")
            }
        }
        let request = AgentRequest(conversationID: UUID(), prompt: "Work", maxToolCalls: 3)
        if fails {
            await #expect(throws: AgentError.toolLimitReached) { try await collect(fixture.client.run(request: request)) }
            #expect(await evidence.values == ["action"])
        } else {
            let events = try await collect(fixture.client.run(request: request))
            #expect(events.contains(.finished(.completed)))
            #expect(await evidence.values == ["action", "list"])
        }
    }

    @Test(arguments: [0, -1, 1, 2])
    func invalidCompoundBudgetMetadataIsRejectedBeforeExecution(variant: Int) async throws {
        let tool = AgentTool(name: "invalid", description: "Invalid metadata", parameters: emptySchema,
                             mayHaveSideEffects: variant != 2,
                             executionCost: variant, verifiesSideEffects: variant > 0) { _ in
            Issue.record("Invalid tool metadata must never execute")
            return .text("Unexpected")
        }
        let fixture = try await RuntimeFixture(tools: [tool])
        defer { fixture.remove() }
        do {
            _ = try await fixture.client.run(request: .init(conversationID: UUID(), prompt: "Work"))
            Issue.record("Expected invalid configuration")
        } catch {
            guard case .invalidConfiguration = error as? AgentError else {
                Issue.record("Expected invalid configuration, got \(error)")
                return
            }
        }
    }

    @Test func hostToolLimitTerminatesAndCanContinueOnlyWithANewRequest() async throws {
        let evidence = RuntimeEvidence()
        let action = AgentTool(name: "act", description: "Host-controlled task", parameters: emptySchema) { _ in
            await evidence.record("host-limit")
            throw AgentError.toolLimitReached
        }
        let capture = AgentTool(name: "capture", description: "Observe", parameters: emptySchema,
                                mayHaveSideEffects: false) { _ in
            await evidence.record("fresh-observation")
            return .text("Observed")
        }
        let fixture = try await RuntimeFixture(tools: [action, capture])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            switch count {
            case 1: return FauxResponse(.toolCall("act", [:]))
            case 2: return FauxResponse(.toolCall("capture", [:]))
            default: return .text("Continued")
            }
        }
        let id = UUID()
        await #expect(throws: AgentError.toolLimitReached) {
            try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "Work", maxToolCalls: 10)))
        }
        #expect(await evidence.values == ["host-limit"])
        #expect(try await !fixture.client.recover(conversationID: id).hasInterruptedRun)
        await #expect(throws: AgentError.nothingToResume) {
            try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "", mode: .resume)))
        }
        let events = try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "Continue from a fresh observation")))
        #expect(events.contains(.finished(.completed)))
        #expect(await evidence.values == ["host-limit", "fresh-observation"])
    }

    @Test func unrelatedReadOnlyToolCannotConsumeAnActionsReservedVerification() async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Verify", parameters: emptySchema,
                                mayHaveSideEffects: false, isVerification: true) { _ in
            await evidence.record("capture")
            return .text("Observed")
        }
        let action = AgentTool(name: "act", description: "Action", parameters: emptySchema) { _ in
            await evidence.record("action")
            return .text("Sent")
        }
        let list = AgentTool(name: "list_apps", description: "Read app names", parameters: emptySchema,
                             mayHaveSideEffects: false) { _ in
            await evidence.record("should-not-list")
            return .text("Apps")
        }
        let fixture = try await RuntimeFixture(tools: [capture, action, list])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            #expect(count <= 2)
            return FauxResponse(.toolCall(count == 1 ? "act" : "list_apps", [:]))
        }
        let id = UUID()
        await #expect(throws: AgentError.toolLimitReached) {
            try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "Work", maxToolCalls: 2)))
        }
        #expect(await evidence.values == ["action"])
        #expect(try await !fixture.client.recover(conversationID: id).hasInterruptedRun)
    }

    @Test func observationOnlyToolsCanUseTheEntireBudget() async throws {
        let evidence = RuntimeEvidence()
        let capture = AgentTool(name: "capture", description: "Verify", parameters: emptySchema,
                                mayHaveSideEffects: false, isVerification: true) { _ in .text("Observed") }
        let list = AgentTool(name: "list_apps", description: "Read app names", parameters: emptySchema,
                             mayHaveSideEffects: false) { _ in
            await evidence.record("list")
            return .text("Apps")
        }
        let fixture = try await RuntimeFixture(tools: [capture, list])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            if count == 1 { return FauxResponse(.toolCall("list_apps", [:])) }
            return .text("Read the app names.")
        }
        let events = try await collect(fixture.client.run(request: .init(conversationID: UUID(), prompt: "Observe", maxToolCalls: 1)))
        #expect(events.contains(.finished(.completed)))
        #expect(await evidence.values == ["list"])
    }

    @Test func verificationToolsMustBeReadOnly() async throws {
        let tool = AgentTool(name: "invalid", description: "Invalid verifier", parameters: emptySchema,
                             isVerification: true) { _ in .text("Should not execute") }
        let fixture = try await RuntimeFixture(tools: [tool])
        defer { fixture.remove() }
        do {
            _ = try await fixture.client.run(request: .init(conversationID: UUID(), prompt: "Work"))
            Issue.record("Side-effect tools cannot be verification tools")
        } catch {
            guard case .invalidConfiguration = error as? AgentError else {
                Issue.record("Expected invalid configuration, got \(error)")
                return
            }
        }
    }

    @Test func hostPauseTerminatesAndOnlyANewRequestContinues() async throws {
        let evidence = RuntimeEvidence()
        let pause = AgentTool(name: "pause", description: "Pause at a known boundary", parameters: emptySchema) { _ in
            await evidence.record("paused")
            throw AgentError.toolExecutionPaused(.noProgress)
        }
        let capture = AgentTool(name: "capture", description: "Observe again", parameters: emptySchema,
                               mayHaveSideEffects: false) { _ in
            await evidence.record("fresh-observation")
            return .text("Observed")
        }
        let fixture = try await RuntimeFixture(tools: [pause, capture])
        defer { fixture.remove() }
        try await fixture.faux.respond { _, count in
            switch count {
            case 1: return FauxResponse(.toolCall("pause", [:]))
            case 2: return FauxResponse(.toolCall("capture", [:]))
            default: return .text("Continued after a new request.")
            }
        }
        let id = UUID()
        var events: [EiscueAgentKit.AgentEvent] = []
        do {
            for try await event in try await fixture.client.run(request: .init(conversationID: id, prompt: "Work")) {
                events.append(event)
            }
            Issue.record("Host pause must surface to the caller")
        } catch { #expect(error as? AgentError == .toolExecutionPaused(.noProgress)) }
        #expect(!events.contains(.finished(.completed)))
        #expect(await evidence.values == ["paused"])
        #expect(try await !fixture.client.recover(conversationID: id).hasInterruptedRun)
        await #expect(throws: AgentError.nothingToResume) {
            try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "", mode: .resume)))
        }
        #expect(await evidence.values == ["paused"])
        let next = try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "Continue from a new observation")))
        #expect(next.contains(.finished(.completed)))
        #expect(await evidence.values == ["paused", "fresh-observation"])
    }

    @Test(arguments: [false, true])
    func cleanupFailureCannotBeReportedAsASafePause(hostPause: Bool) async throws {
        let failure = AgentError.runtime("Injected durable cleanup failure")
        let action = AgentTool(name: "act", description: "Action", parameters: emptySchema) { _ in
            throw AgentError.toolExecutionPaused(.noProgress)
        }
        let fixture = try await RuntimeFixture(tools: [action], abortOperation: { _ in throw failure })
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("act", [:]))
        await #expect(throws: AgentError.cleanupFailed(failure.localizedDescription)) {
            try await collect(fixture.client.run(request: .init(conversationID: UUID(), prompt: "Work", maxToolCalls: hostPause ? 1 : 0)))
        }
    }

    @Test func cancellationActuallyAbortsToolsAndPreventsTheNextAction() async throws {
        let evidence = RuntimeEvidence()
        let slow = AgentTool(name: "slow", description: "Wait", parameters: emptySchema) { _ in
            await evidence.record("started")
            try await Task.sleep(for: .seconds(30))
            await evidence.record("should-not-finish")
            return .text("Finished")
        }
        let later = AgentTool(name: "later", description: "Next action", parameters: emptySchema) { _ in
            await evidence.record("should-not-start")
            return .text("Finished")
        }
        let fixture = try await RuntimeFixture(tools: [slow, later])
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("slow", [:]), .toolCall("later", [:]))
        let id = UUID()
        let events = try await fixture.client.run(request: .init(conversationID: id, prompt: "Work"))
        let reader = Task { try await collect(events) }
        try await eventually { await evidence.values == ["started"] }
        await #expect(throws: AgentError.busy) {
            try await fixture.client.run(request: .init(conversationID: UUID(), prompt: "Concurrent"))
        }
        try await fixture.client.cancel()
        #expect(try await reader.value.contains(.finished(.cancelled)))
        #expect(await evidence.values == ["started"])
        #expect(try await !fixture.client.recover(conversationID: id).hasInterruptedRun)
    }

    @Test func timeoutStopsRealToolExecution() async throws {
        let evidence = RuntimeEvidence()
        let tool = AgentTool(name: "slow", description: "Wait", parameters: emptySchema) { _ in
            await evidence.record("started")
            try await Task.sleep(for: .seconds(30))
            await evidence.record("should-not-finish")
            return .text("Done")
        }
        let fixture = try await RuntimeFixture(tools: [tool])
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("slow", [:]))
        await #expect(throws: AgentError.timedOut) {
            try await collect(fixture.client.run(request: .init(conversationID: UUID(), prompt: "Wait", timeoutSeconds: 5)))
        }
        #expect(await evidence.values == ["started"])
    }

    @Test func abortFailureWaitsForExecutionCleanupBeforeReturning() async throws {
        let evidence = RuntimeEvidence()
        let slow = AgentTool(name: "slow", description: "Wait", parameters: emptySchema) { _ in
            await evidence.record("started")
            do { try await Task.sleep(for: .seconds(30)) }
            catch {
                await evidence.record("cancelled")
                throw error
            }
            await evidence.record("should-not-finish")
            return .text("Finished")
        }
        let failure = AgentError.runtime("Injected durable abort failure")
        let fixture = try await RuntimeFixture(tools: [slow], abortOperation: { _ in throw failure })
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("slow", [:]))
        let id = UUID()
        let events = try await fixture.client.run(request: .init(conversationID: id, prompt: "Work"))
        let reader = Task { try await collect(events) }
        try await eventually { await evidence.values == ["started"] }
        let started = ContinuousClock.now
        await #expect(throws: AgentError.cleanupFailed(failure.localizedDescription)) { try await fixture.client.cancel() }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await evidence.values == ["started", "cancelled"])
        #expect(try await reader.value.contains(.finished(.cancelled)))
        // close preserves the interrupted work when the abort itself could not be persisted.
        #expect(try await fixture.client.recover(conversationID: id).hasInterruptedRun)
        try await fixture.faux.append(.text("A new run can start after cleanup."))
        let next = try await collect(fixture.client.run(request: .init(conversationID: UUID(), prompt: "Next")))
        #expect(next.contains(.finished(.completed)))
    }

    @Test func recoveryIsReadOnlyAndResumeRequiresExplicitRequest() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.remove() }
        let id = UUID()
        let harness = try await Harness.open(.sqlite(at: fixture.fileURL(id)), models: fixture.models, resume: false)
        let root = try await harness.root(agent: AgentChange(model: fixture.faux.model))
        try await root.submit("Pending input", requestId: "pending")
        try await harness.close()
        try await fixture.faux.append(.text("Explicitly resumed"))
        let recovery = try await fixture.client.recover(conversationID: id)
        #expect(recovery.hasInterruptedRun)
        #expect(try await fixture.faux.pendingResponseCount() == 1)
        await #expect(throws: AgentError.interruptedRun) {
            try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "Unrelated input")))
        }
        #expect(try await fixture.client.recover(conversationID: id).hasInterruptedRun)
        #expect(try await fixture.faux.pendingResponseCount() == 1)
        let events = try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "", mode: .resume)))
        #expect(events.contains { if case .message(let message) = $0 { message.text == "Explicitly resumed" } else { false } })
        #expect(try await !fixture.client.recover(conversationID: id).hasInterruptedRun)
    }

    @Test func unsafeActionIsNotReplayedAfterInterruptedProcess() async throws {
        let evidence = RuntimeEvidence()
        let action = AgentTool(name: "touch", description: "Touch", parameters: emptySchema) { _ in
            await evidence.record("unexpected-replay")
            return .text("Touched")
        }
        let fixture = try await RuntimeFixture(tools: [action])
        defer { fixture.remove() }
        let id = UUID()
        let interruptedTool = PiDurableKit.Tool("touch", description: "Touch", replay: .unsafe) { _ in
            await evidence.record("original-action")
            try await Task.sleep(for: .seconds(30))
            return "Finished"
        }
        let harness = try await Harness.open(.sqlite(at: fixture.fileURL(id)), models: fixture.models,
                                            extensions: [Extension("eiscue", tools: [interruptedTool])])
        let root = try await harness.root(agent: AgentChange(model: fixture.faux.model))
        try await fixture.faux.append(.toolCall("touch", [:]))
        try await root.submit("Touch")
        try await eventually { await evidence.values == ["original-action"] }
        try await harness.close()
        #expect(try await fixture.client.recover(conversationID: id).hasInterruptedRun)
        #expect(await evidence.values == ["original-action"])
        try await fixture.faux.respond { messages, _ in
            #expect(messages.contains { message in
                if case .toolResult(let result) = message { return result.isError }
                return false
            })
            return .text("The interrupted action was not repeated.")
        }
        let events = try await collect(fixture.client.run(request: .init(conversationID: id, prompt: "", mode: .resume)))
        #expect(events.contains(.finished(.completed)))
        #expect(events.contains { if case .toolFinished(let result) = $0 { result.result.outcome == .interrupted } else { false } })
        #expect(await evidence.values == ["original-action"])
    }

    @Test func importsLegacyHistoryOnceAndRequestIDsPreventDuplicateSubmissions() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.remove() }
        let history = [AgentMessage(role: .user, text: "Old question"), AgentMessage(role: .assistant, text: "Old reply")]
        try await fixture.faux.respond { messages, count in
            #expect(count == 1)
            #expect(messages.filter { $0.text == "Old question" }.count == 1)
            #expect(messages.contains { $0.text == "Old reply" })
            return .text("New reply")
        }
        let request = AgentRequest(conversationID: UUID(), prompt: "New question", history: history)
        let first = try await collect(fixture.client.run(request: request))
        let retry = try await collect(fixture.client.run(request: request))
        #expect(first.first == .requestAccepted(request.requestID))
        #expect(retry.first == .requestAccepted(request.requestID))
        let recovery = try await fixture.client.recover(conversationID: request.conversationID)
        #expect(Array(recovery.messages.prefix(2)).map(\.id) == history.map(\.id))
        #expect(recovery.messages.map(\.text) == ["Old question", "Old reply", "New question", "New reply"])
        try await fixture.client.removeConversation(id: request.conversationID)
        #expect(try await fixture.client.recover(conversationID: request.conversationID).messages.isEmpty)
    }

    @Test func plainTextRequestRetainsItsIdentityAfterOpeningAnOfflineClient() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.remove() }
        try await fixture.faux.respond { messages, count in
            #expect(count == 1)
            #expect(messages.map(\.text) == ["", "Plain text question"])
            return .text("Plain text reply")
        }
        let request = AgentRequest(conversationID: UUID(), prompt: "Plain text question",
            systemPrompt: "You are Eiscue. Reply concisely in the user's language.")
        let events = try await collect(fixture.client.run(request: request))
        #expect(events.first == .requestAccepted(request.requestID))
        let reopened = AgentClient(storageDirectory: fixture.directory)
        let recovery = try await reopened.recover(conversationID: request.conversationID)
        #expect(recovery.messages.map(\.text) == [request.prompt, "Plain text reply"])
        #expect(recovery.messages.first?.id == request.requestID)
        #expect(recovery.messages.first?.attachments.isEmpty == true)
        #expect(!recovery.hasInterruptedRun)
    }

    @Test func repeatedPlainTextRequestsKeepDistinctIdentitiesAndRetryDoesNotMixThem() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.remove() }
        try await fixture.faux.respond { messages, count in
            #expect(count <= 2)
            #expect(messages.filter { if case .user = $0 { true } else { false } }.count == count)
            return .text("Reply \(count)")
        }
        let id = UUID()
        let first = AgentRequest(conversationID: id, prompt: "Same question")
        let second = AgentRequest(conversationID: id, prompt: "Same question")
        #expect(first.requestID != second.requestID)
        try await collect(fixture.client.run(request: first))
        try await collect(fixture.client.run(request: second))
        try await collect(fixture.client.run(request: first))
        let reopened = AgentClient(storageDirectory: fixture.directory)
        let recovery = try await reopened.recover(conversationID: id)
        let users = recovery.messages.filter { $0.role == .user }
        #expect(users.map(\.id) == [first.requestID, second.requestID])
        #expect(users.map(\.text) == ["Same question", "Same question"])
        #expect(recovery.messages.map(\.text) == ["Same question", "Reply 1", "Same question", "Reply 2"])
    }

    @Test func orphanedDisplayMetadataIsIgnoredAndCannotReplaceTheNextIdenticalRequest() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.remove() }
        let id = UUID()
        let orphan = AgentMessage(role: .user, text: "Same question")
        let harness = try await Harness.open(.sqlite(at: fixture.fileURL(id)), models: fixture.models, resume: false)
        let root = try await harness.root(agent: AgentChange(model: fixture.faux.model))
        try await root.commit { transaction in
            _ = try await transaction.append(EntryDraft(kind: RuntimeMapping.attachmentEntryKind,
                data: ["eiscueMessage": try PiDurableKit.JSONValue(encoding: orphan)]), to: root.id)
        }
        try await harness.close()
        let empty = try await fixture.client.recover(conversationID: id)
        #expect(empty.messages.isEmpty)
        #expect(!empty.hasInterruptedRun)
        try await fixture.faux.respond { messages, count in
            #expect(count == 1)
            #expect(messages.compactMap { if case .user(let user) = $0 { user.text } else { nil } } == ["Same question"])
            return .text("Accepted reply")
        }
        let accepted = AgentRequest(conversationID: id, prompt: "Same question")
        try await collect(fixture.client.run(request: accepted))
        let reopened = AgentClient(storageDirectory: fixture.directory)
        let recovery = try await reopened.recover(conversationID: id)
        #expect(recovery.messages.map(\.text) == ["Same question", "Accepted reply"])
        #expect(recovery.messages.first?.id == accepted.requestID)
        #expect(!recovery.messages.contains { $0.id == orphan.id })
    }

    @Test func oldPlainTextTranscriptWithoutDisplayMetadataStillRecovers() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.remove() }
        let id = UUID()
        let harness = try await Harness.open(.sqlite(at: fixture.fileURL(id)), models: fixture.models, resume: false)
        let root = try await harness.root(agent: AgentChange(model: fixture.faux.model))
        try await root.commit { transaction in
            _ = try await transaction.append(EntryDraft(kind: .user,
                model: [.user(UserMessage(content: [.text("Legacy plain text")]))]), to: root.id)
        }
        try await harness.close()
        let first = try await fixture.client.recover(conversationID: id)
        let second = try await AgentClient(storageDirectory: fixture.directory).recover(conversationID: id)
        #expect(first.messages.map(\.text) == ["Legacy plain text"])
        #expect(first.messages == second.messages)
        #expect(!first.hasInterruptedRun)
    }

    @Test func userAttachmentsReachModelAndSurviveRetryRecoveryAndHistoryImport() async throws {
        let fixture = try await RuntimeFixture()
        defer { fixture.remove() }
        let photo = AgentAttachment(name: "selected.jpg", mimeType: "image/jpeg", content: .image(Data([1, 2, 3, 4])))
        let document = AgentAttachment(name: "report.pdf", mimeType: "application/pdf", content: .text("Extracted report text"))
        let history = [AgentMessage(role: .user, text: "old image", attachments: [photo])]
        try await fixture.faux.respond { messages, count in
            #expect(count == 1)
            let users = messages.compactMap { if case .user(let user) = $0 { user } else { nil } }
            #expect(users.count == 2)
            #expect(users.last?.content.contains(.image(ImageContent(data: Data([1, 2, 3, 4]), mimeType: "image/jpeg"))) == true)
            #expect(users.last?.content.contains(.text("Extracted report text")) == true)
            return .text("Read both attachments")
        }
        let request = AgentRequest(conversationID: UUID(), prompt: "", history: history, attachments: [photo, document])
        try await collect(fixture.client.run(request: request))
        try await collect(fixture.client.run(request: request))
        let recovery = try await fixture.client.recover(conversationID: request.conversationID)
        #expect(recovery.messages.count == 3)
        #expect(recovery.messages[0] == history[0])
        #expect(recovery.messages[1].id == request.requestID)
        #expect(recovery.messages[1].text == "")
        #expect(recovery.messages[1].attachments == [photo, document])
    }
}

private let emptySchema: AgentJSONValue = ["type": "object", "properties": [:], "additionalProperties": false]
private let testConfiguration = AgentConfiguration(api: .openAICompletions, baseURL: URL(string: "https://fixture.invalid/v1")!,
                                                   model: "fixture", apiKey: "test-secret-not-for-disk")

private struct RuntimeFixture {
    let directory: URL
    let models: Models
    let faux: FauxProvider
    let client: AgentClient

    init(tools: [AgentTool] = [], abortOperation: DefaultEngine.AbortOperation? = nil, closeOperation: DefaultEngine.CloseOperation? = nil) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        self.models = models
        self.faux = faux
        client = AgentClient(engine: DefaultEngine(configuration: testConfiguration, storageDirectory: directory,
            tools: tools, modelFactory: { (models, faux.model) },
            abortOperation: abortOperation ?? { try await $0.abort(background: true) },
            closeOperation: closeOperation ?? { try await $0.close() }))
    }

    func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".sqlite") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor RuntimeEvidence {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

@discardableResult
private func collect(_ stream: AsyncThrowingStream<EiscueAgentKit.AgentEvent, Error>) async throws -> [EiscueAgentKit.AgentEvent] {
    var events: [EiscueAgentKit.AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentError.runtime("Test timed out waiting for the real runtime")
}
