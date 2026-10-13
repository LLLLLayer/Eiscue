import Foundation
import Testing
import PiDurableKit
@testable import EiscueAgentKit

@Suite("Agent runtime")
struct AgentRuntimeTests {
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
                #expect(messages.contains { $0.text.contains("Remaining tool calls: 1.") })
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
            throw AgentError.toolExecutionPaused("Review test-secret-not-for-disk")
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
        } catch { #expect(error as? AgentError == .toolExecutionPaused("Review [redacted]")) }
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
            throw AgentError.toolExecutionPaused("Review progress")
        }
        let fixture = try await RuntimeFixture(tools: [action], abortOperation: { _ in throw failure })
        defer { fixture.remove() }
        try await fixture.faux.append(.toolCall("act", [:]))
        await #expect(throws: failure) {
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
            try await collect(fixture.client.run(request: .init(conversationID: UUID(), prompt: "Wait", timeoutSeconds: 0.7)))
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
        await #expect(throws: failure) { try await fixture.client.cancel() }
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

    init(tools: [AgentTool] = [], abortOperation: DefaultEngine.AbortOperation? = nil) async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("eiscue-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let models = Models(builtinProviders: false)
        let faux = FauxProvider()
        try await models.register(faux)
        self.models = models
        self.faux = faux
        client = AgentClient(engine: DefaultEngine(configuration: testConfiguration, storageDirectory: directory,
            tools: tools, modelFactory: { (models, faux.model) },
            abortOperation: abortOperation ?? { try await $0.abort(background: true) }))
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
