import Foundation
import PiDurableKit

/// Runtime-specific types are kept behind AgentEngine.
actor DefaultEngine: AgentEngine {
    typealias ModelFactory = @Sendable () async throws -> (Models, ModelRef)
    typealias CloseOperation = @Sendable (Harness) async throws -> Void
    typealias AbortOperation = @Sendable (PiDurableKit.Conversation) async throws -> Void
    private let configuration: AgentConfiguration?
    private let storageDirectory: URL?
    private let tools: [AgentTool]
    private let modelFactory: ModelFactory?
    private let abortOperation: AbortOperation
    private let closeOperation: CloseOperation
    private var operation: UUID?
    private var active: ActiveRun?
    private var lastEnded: (conversationID: UUID, cleanupError: AgentError?)?

    init() {
        configuration = nil
        storageDirectory = nil
        tools = []
        modelFactory = nil
        abortOperation = Self.abort
        closeOperation = { try await $0.close() }
    }

    init(storageDirectory: URL) {
        configuration = nil
        self.storageDirectory = storageDirectory
        tools = []
        modelFactory = nil
        abortOperation = Self.abort
        closeOperation = { try await $0.close() }
    }

    init(configuration: AgentConfiguration, storageDirectory: URL, tools: [AgentTool] = [], modelFactory: ModelFactory? = nil,
         abortOperation: @escaping AbortOperation = DefaultEngine.abort,
         closeOperation: @escaping CloseOperation = { try await $0.close() }) {
        self.configuration = configuration
        self.storageDirectory = storageDirectory
        self.tools = tools
        self.modelFactory = modelFactory
        self.abortOperation = abortOperation
        self.closeOperation = closeOperation
    }

    var availability: AgentAvailability {
        guard let configuration, (try? configuration.validate()) != nil else { return .unconfigured }
        return .ready
    }

    func run(request: AgentRequest) throws -> AsyncThrowingStream<AgentEvent, Error> {
        try validate()
        guard operation == nil else { throw AgentError.busy }
        guard request.timeoutSeconds.isFinite, request.timeoutSeconds > 0,
              request.timeoutSeconds <= 86_400, request.maxToolCalls >= 0 else {
            throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-budget", defaultValue: "The task time limit or tool call limit is invalid.", bundle: .module))
        }
        try AgentAttachment.validate(request.attachments, supportsImages: configuration?.supportsImages ?? false)
        for message in request.history { try AgentAttachment.validate(message.attachments, supportsImages: configuration?.supportsImages ?? false) }
        if request.mode == .message, request.attachments.isEmpty, request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AgentError.invalidConfiguration(String(localized: "agent.configuration.empty-message", defaultValue: "Enter a message.", bundle: .module))
        }
        let id = UUID()
        let budget = RunBudget(limit: request.maxToolCalls, verificationCost: tools.filter(\.isVerification).map(\.executionCost).min())
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        operation = id
        active = ActiveRun(id: id, conversationID: request.conversationID, budget: budget, completion: RuntimeCompletion())
        let task = Task { await self.execute(request, id: id, budget: budget, continuation: continuation) }
        active?.task = task
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason {
                Task { try? await self?.requestStop(id: id, cause: .cancelled) }
            }
        }
        return stream
    }

    func cancel() async throws {
        guard let current = active else {
            if let cleanupError = lastEnded?.cleanupError { throw cleanupError }
            return
        }
        do { try await requestStop(id: current.id, cause: .cancelled) }
        catch {
            // An abort failure must not release the caller while the old task still owns the database.
            await current.task?.value
            if let cleanupError = await current.completion.cleanupError { throw cleanupError }
            throw sanitized(error)
        }
        await current.task?.value
        if let cleanupError = await current.completion.cleanupError { throw cleanupError }
    }

    func cancel(conversationID: UUID) async throws {
        if let current = active {
            guard current.conversationID == conversationID else { throw AgentError.busy }
            try await cancel()
            return
        }
        if lastEnded?.conversationID == conversationID, let cleanupError = lastEnded?.cleanupError { throw cleanupError }
        guard operation == nil else { throw AgentError.busy }
        try validateStorage()
        guard FileManager.default.fileExists(atPath: try fileURL(conversationID).path) else {
            let url = try fileURL(conversationID)
            let token = try await RuntimeOwnership.shared.acquire(url)
            await RuntimeOwnership.shared.release(url, token: token)
            return
        }
        operation = UUID()
        defer { operation = nil }
        let session = try await open(conversationID, budget: RunBudget(limit: 0))
        do { try await session.conversation.abort(background: true) }
        catch {
            try await close(session)
            throw sanitized(error)
        }
        try await close(session)
    }

    func recover(conversationID: UUID) async throws -> AgentRecovery {
        if let current = active, current.conversationID == conversationID, let session = current.session {
            return try recovery(try await session.conversation.view(), conversationID: conversationID)
        }
        guard operation == nil else { throw AgentError.busy }
        try validateStorage()
        guard FileManager.default.fileExists(atPath: try fileURL(conversationID).path) else {
            let url = try fileURL(conversationID)
            let token = try await RuntimeOwnership.shared.acquire(url)
            await RuntimeOwnership.shared.release(url, token: token)
            return AgentRecovery(messages: [], hasInterruptedRun: false)
        }
        operation = UUID()
        defer { operation = nil }
        let session = try await open(conversationID, budget: RunBudget(limit: 0))
        let recovered: AgentRecovery
        do { recovered = try recovery(try await session.conversation.view(), conversationID: conversationID) }
        catch {
            try await close(session)
            throw sanitized(error)
        }
        try await close(session)
        return recovered
    }

    func removeConversation(id: UUID) async throws {
        guard operation == nil else { throw AgentError.busy }
        operation = UUID()
        defer { operation = nil }
        let url = try fileURL(id)
        let ownership = try await RuntimeOwnership.shared.acquire(url)
        do {
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path + suffix)
                do { try FileManager.default.removeItem(at: file) }
                catch CocoaError.fileNoSuchFile { continue }
            }
            await RuntimeOwnership.shared.release(url, token: ownership)
        } catch {
            await RuntimeOwnership.shared.release(url, token: ownership)
            throw error
        }
    }

    private func recovery(_ view: ConversationView, conversationID: UUID) throws -> AgentRecovery {
        let recovered = RuntimeMapping.recovery(view, conversationID: conversationID)
        return AgentRecovery(messages: recovered.messages, hasInterruptedRun: recovered.hasInterruptedRun,
                             acceptedRequestIDs: try RuntimeToolHistory.acceptedRequestIDs(at: fileURL(conversationID)))
    }

    func toolResult(conversationID: UUID, requestID: UUID, toolCallID: String) async throws -> AgentToolCompletion? {
        guard !toolCallID.isEmpty else { return nil }
        try validateStorage()
        return try RuntimeToolHistory.result(at: fileURL(conversationID), requestID: requestID, toolCallID: toolCallID)
    }

    private func execute(_ request: AgentRequest, id: UUID, budget: RunBudget,
                         continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async {
        var session: Session?
        var reader: Task<Void, Never>?
        var translator: RuntimeEventTranslator?
        var admitted = false
        var failure: Error?
        var cleanupFailure: AgentError?
        let completion = active!.completion
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(request.timeoutSeconds)) }
            catch { return }
            try? await self?.requestStop(id: id, cause: .timedOut)
        }
        do {
            try checkRunning(id)
            let opened = try await open(request.conversationID, budget: budget)
            session = opened
            active?.session = opened
            try checkRunning(id)
            var view = try await opened.conversation.view()
            let pending = view.isBusy || !view.inbox.isEmpty
            if request.mode == .message, pending { throw AgentError.interruptedRun }
            if request.mode == .resume, !pending { throw AgentError.nothingToResume }
            if view.entries.isEmpty, !request.history.isEmpty {
                try await importHistory(request.history, into: opened.conversation)
                view = try await opened.conversation.view()
            }
            let existingEntries = Set(view.entries.map(\.id))
            var settledInputs: [EntryID] = []
            var settledAnswers: [EntryID] = []
            if configuration?.supportsImages == false,
               view.entries.contains(where: { ($0.userMessage?.content ?? []).contains { if case .image = $0 { true } else { false } } }) {
                throw AgentError.invalidConfiguration(String(localized: "agent.attachment.images-unavailable", defaultValue: "Choose a model that supports images to send this attachment.", bundle: .module))
            }
            try await opened.conversation.configure(AgentChange(model: opened.model, instructions: request.systemPrompt))
            try checkRunning(id)
            let events = try await opened.harness.watchEvents(opened.conversation.id)
            let mapping = RuntimeEventTranslator(conversationID: request.conversationID, snapshot: events.snapshot,
                                                 continuation: continuation, secret: configuration?.apiKey ?? "")
            translator = mapping
            reader = Task {
                do {
                    for try await batch in events {
                        for event in batch { await mapping.receive(event) }
                    }
                } catch {
                    // The final durable view reconciles output if an observer ends early.
                }
            }
            var submissions: [PiDurableKit.Submission] = []
            if request.mode == .message {
                if !view.entries.contains(where: { RuntimeMapping.storedMessageID($0) == request.requestID }) {
                    let message = AgentMessage(id: request.requestID, role: .user, text: request.prompt, attachments: request.attachments)
                    // Persist display metadata before admission. No model context
                    // is contributed by this entry; orphaned metadata is ignored.
                    try await opened.conversation.commit { transaction in
                        _ = try await transaction.append(EntryDraft(kind: RuntimeMapping.attachmentReferenceEntryKind,
                            data: .object(try RuntimeMapping.displayMetadata(message))), to: opened.conversation.id)
                    }
                }
                let submission = try await opened.conversation.submit(RuntimeMapping.userContent(text: request.prompt, attachments: request.attachments), whenBusy: .reject,
                                                                      requestId: request.requestID.uuidString)
                admitted = true
                continuation.yield(.requestAccepted(request.requestID))
                submissions = [submission]
            } else {
                let identifiers = Set((view.live.run?.inputs ?? []) + view.inbox.map(\.id))
                submissions = identifiers.sorted().map { opened.harness.submission($0) }
                admitted = true
                continuation.yield(.requestAccepted(request.requestID))
            }
            try checkRunning(id)
            try await opened.harness.resume()
            for submission in submissions {
                let settled = try await submission.wait()
                try checkRunning(id)
                if await budget.terminalCause != nil { throw RuntimeStopSignal.outcomeUnknown }
                if let budgetError = await budget.failure { throw budgetError }
                if case .unanswered(let input, let reason, let detail) = settled.status {
                    let failedView = try await opened.conversation.view()
                    if let modelFailure = ModelRequestFailure.classify(entries: failedView.entries, input: input, existingEntries: existingEntries) {
                        throw modelFailure
                    }
                    let detailText = detail?.stringValue ?? detail?["message"]?.stringValue ?? ""
                    throw AgentError.runtime(String(localized: "agent.runtime.unfinished", defaultValue: "The task did not finish (\(String(describing: reason))). \(String(describing: detailText))", bundle: .module))
                }
                if case .done(let input, let answer) = settled.status {
                    settledInputs.append(input)
                    if let answer { settledAnswers.append(answer) }
                }
            }
            try await opened.conversation.waitForIdle()
            try checkRunning(id)
            if await budget.terminalCause != nil { throw RuntimeStopSignal.outcomeUnknown }
            if let budgetError = await budget.failure { throw budgetError }
            let finalView = try await opened.conversation.view()
            await mapping.reconcile(finalView)
            if let last = finalView.entries.last?.assistantMessage, last.stopReason == .error {
                if let modelFailure = settledInputs.reversed().compactMap({
                    ModelRequestFailure.classify(entries: finalView.entries, input: $0, existingEntries: existingEntries)
                }).first { throw modelFailure }
                throw AgentError.runtime(last.errorMessage ?? String(localized: "agent.runtime.model-failed", defaultValue: "The model request failed.", bundle: .module))
            }
            // A provider can incorrectly label tool calls as its final answer.
            // Never report those unexecuted calls as a successful task or replay them here.
            if finalView.entries.contains(where: { settledAnswers.contains($0.id) && !($0.assistantMessage?.toolCalls.isEmpty ?? true) }) {
                throw AgentError.runtime(String(localized: "agent.runtime.unhandled-tools", defaultValue: "The model ended its reply without running the requested actions.", bundle: .module))
            }
        } catch {
            failure = error
            if case .cleanupFailed = error as? AgentError { await completion.failCleanup(sanitized(error)) }
        }
        timeout.cancel()
        if let session {
            let priorFailure = failure
            let shouldAbort = failure != nil && (admitted || active?.stopCause != nil)
            let finalTranslator = translator
            let finalReader = reader
            // Bridge calls inherit task cancellation. A fresh task lets abort/close finish even
            // when abort failure forced the execution task's submission.wait to be cancelled.
            failure = await Task {
                var result = priorFailure
                if shouldAbort {
                    await budget.stop()
                    do { try await abortOperation(session.conversation) }
                    catch {
                        let cleanup = AgentError.cleanupFailed(RuntimeMapping.redact(error.localizedDescription, secret: configuration?.apiKey ?? ""))
                        await completion.failCleanup(cleanup)
                        if Self.requiresSuccessfulCleanup(result) { result = cleanup }
                    }
                }
                do { await finalTranslator?.reconcile(try await session.conversation.view()) }
                catch {
                    let cleanup = AgentError.cleanupFailed(RuntimeMapping.redact(error.localizedDescription, secret: configuration?.apiKey ?? ""))
                    await completion.failCleanup(cleanup)
                    if Self.requiresSuccessfulCleanup(result) { result = cleanup }
                }
                finalReader?.cancel()
                await finalReader?.value
                do { try await close(session) }
                catch {
                    let cleanup = AgentError.cleanupFailed(RuntimeMapping.redact(error.localizedDescription, secret: configuration?.apiKey ?? ""))
                    await completion.failCleanup(cleanup)
                    if Self.requiresSuccessfulCleanup(result) { result = cleanup }
                }
                return result
            }.value
        }
        cleanupFailure = await completion.cleanupError
        let stopCause = await budget.terminalCause ?? active?.stopCause
        if let cleanupFailure { continuation.yield(.cleanupFailed(cleanupFailure.localizedDescription)) }
        // A consumer can fail to save an earlier buffered event after execution
        // has ended. Its subsequent cancel must still report the close failure.
        lastEnded = (request.conversationID, cleanupFailure)
        active = nil
        operation = nil
        if case .outcomeUnknown = stopCause {
            continuation.yield(.finished(.stopped(stopCause!)))
            continuation.finish()
        } else if stopCause == .cancelled {
            continuation.yield(.finished(.cancelled))
            continuation.finish()
        } else if stopCause == .timedOut {
            continuation.finish(throwing: AgentError.timedOut)
        } else if let failure {
            continuation.finish(throwing: sanitized(failure))
        } else {
            continuation.yield(.finished(.completed))
            continuation.finish()
        }
    }

    private func validate() throws {
        guard let configuration else { throw AgentError.unconfigured }
        try configuration.validate()
        try validateStorage()
        var names = Set<String>()
        for tool in tools {
            guard !tool.name.isEmpty, names.insert(tool.name).inserted, tool.parameters.objectValue != nil else {
                throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-tools", defaultValue: "Tool names must be unique, and parameters must be JSON Schema objects.", bundle: .module))
            }
            guard !tool.isVerification || !tool.mayHaveSideEffects else {
                throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-verification", defaultValue: "Verification tools must be read-only.", bundle: .module))
            }
            if case .latest(let limit) = tool.contextImagePolicy, limit < 0 {
                throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-image-limit", defaultValue: "Image context limits must not be negative.", bundle: .module))
            }
            guard tool.executionCost > 0,
                  !tool.verifiesSideEffects || (tool.mayHaveSideEffects && tool.executionCost >= 2) else {
                throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-tool-cost", defaultValue: "Tool execution costs must be positive. An action with built-in verification must reserve at least two units.", bundle: .module))
            }
        }
    }

    private func validateStorage() throws {
        guard let storageDirectory, storageDirectory.isFileURL else {
            throw AgentError.invalidConfiguration(String(localized: "agent.configuration.invalid-storage", defaultValue: "The agent storage directory must be a local file URL.", bundle: .module))
        }
    }

    private func fileURL(_ id: UUID) throws -> URL {
        guard let storageDirectory else { throw AgentError.unconfigured }
        try validateStorage()
        return storageDirectory.appendingPathComponent(id.uuidString.lowercased() + ".sqlite")
    }

    private func open(_ id: UUID, budget: RunBudget) async throws -> Session {
        let url = try fileURL(id)
        let ownership = try await RuntimeOwnership.shared.acquire(url)
        do {
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
            let (models, model): (Models, ModelRef)
            if let modelFactory { (models, model) = try await modelFactory() }
            else if let configuration { (models, model) = try await Self.makeModels(configuration: configuration) }
            else {
                models = Models(credentials: .inMemory, builtinProviders: false)
                model = ModelRef(provider: "eiscue", modelId: "unconfigured")
            }
            let runtimeTools = try tools.map { try RuntimeMapping.tool($0, budget: budget, secret: configuration?.apiKey ?? "") }
            let outcomeGate = RuntimeOutcomeGate()
            var extensions = [Extension("eiscue", tools: runtimeTools), try DeviceImageContext.runtimeExtension(tools: tools), outcomeGate.runtimeExtension(budget: budget)]
            if let configuration, GoogleCompletionCompatibility.applies(to: configuration) {
                extensions.append(GoogleCompletionCompatibility.runtimeExtension)
            }
            let harness = try await Harness.open(.sqlite(at: url), models: models,
                extensions: extensions,
                settings: Settings(stream: .init(timeout: .seconds(120), maxRetries: 0), retry: .init(enabled: false),
                                   progress: .init(partialInterval: .milliseconds(80)), toolExecution: .sequential),
                resume: false)
            await outcomeGate.attach(harness)
            do {
                let root = try await harness.root(agent: configuration == nil ? nil : AgentChange(model: model))
                return Session(harness: harness, conversation: root, model: model, url: url, ownership: ownership, outcomeGate: outcomeGate)
            } catch {
                do { try await closeOperation(harness) }
                catch { throw AgentError.cleanupFailed(error.localizedDescription) }
                await outcomeGate.detach()
                throw error
            }
        } catch {
            if case .cleanupFailed = error as? AgentError {} else { await RuntimeOwnership.shared.release(url, token: ownership) }
            throw error
        }
    }

    private func close(_ session: Session) async throws {
        do { try await closeOperation(session.harness) }
        catch { throw AgentError.cleanupFailed(RuntimeMapping.redact(error.localizedDescription, secret: configuration?.apiKey ?? "")) }
        await session.outcomeGate.detach()
        await RuntimeOwnership.shared.release(session.url, token: session.ownership)
    }

    static func makeModels(configuration: AgentConfiguration, runtime: Runtime = .shared) async throws -> (Models, ModelRef) {
        let models = Models(credentials: .inMemory, builtinProviders: false, runtime: runtime)
        let api: CustomProvider.API = switch configuration.api {
        case .openAICompletions: .openAICompletions
        case .openAIResponses: .openAIResponses
        case .anthropicMessages: .anthropicMessages
        }
        // Anthropic's SDK adds /v1 itself; accept the common API-root spelling as well.
        let baseURL = configuration.api == .anthropicMessages && configuration.baseURL.lastPathComponent == "v1"
            ? configuration.baseURL.deletingLastPathComponent() : configuration.baseURL
        try await models.register(CustomProvider(id: "eiscue", baseURL: baseURL, api: api,
            apiKey: configuration.apiKey.isEmpty ? nil : configuration.apiKey,
            models: [.init(id: configuration.model, input: configuration.supportsImages ? ["text", "image"] : ["text"],
                           contextWindow: configuration.contextWindow, maxTokens: configuration.maxOutputTokens,
                           compat: completionCompatibility(for: configuration))]))
        return (models, ModelRef(provider: "eiscue", modelId: configuration.model))
    }

    private static func completionCompatibility(for configuration: AgentConfiguration) -> PiDurableKit.JSONObject? {
        guard GoogleCompletionCompatibility.applies(to: configuration) else { return nil }
        // Google's OpenAI compatibility endpoint rejects even `store: false`.
        // Disable Pi's default field only for this endpoint and wire protocol.
        return ["supportsStore": .bool(false)]
    }

    private func importHistory(_ history: [AgentMessage], into conversation: PiDurableKit.Conversation) async throws {
        try await conversation.commit { transaction in
            for message in history {
                let model: PiDurableKit.Message
                let kind: EntryKind
                switch message.role {
                case .user:
                    kind = .user
                    model = .user(UserMessage(content: RuntimeMapping.userContent(text: message.text, attachments: message.attachments), timestamp: message.createdAt))
                case .assistant:
                    kind = .assistant
                    model = .assistant(AssistantMessage(content: [.text(message.text)], timestamp: message.createdAt))
                case .system, .tool: continue
                }
                var metadata: PiDurableKit.JSONObject = ["eiscueID": .string(message.id.uuidString)]
                if message.role == .user { metadata.merge(try RuntimeMapping.displayMetadata(message)) { _, value in value } }
                _ = try await transaction.append(EntryDraft(kind: kind, data: .object(metadata), model: [model]), to: conversation.id)
            }
        }
    }

    private func checkRunning(_ id: UUID) throws {
        guard let active, active.id == id else { throw CancellationError() }
        switch active.stopCause {
        case .cancelled: throw CancellationError()
        case .timedOut: throw AgentError.timedOut
        case nil: break
        default: throw CancellationError()
        }
    }

    private func requestStop(id: UUID, cause: StopCause) async throws {
        guard let current = active, current.id == id else { return }
        if active?.stopCause == nil { active?.stopCause = cause }
        await current.budget.stop()
        // Capture the target before suspension; a late cancellation must not abort a later run.
        guard active?.id == id else { return }
        do {
            if let conversation = current.session?.conversation { try await abortOperation(conversation) }
        } catch {
            // Submission.wait is cancellable even when the durable abort cannot be committed.
            // Cleanup then closes the scheduler and storage; the pending run remains recoverable.
            current.task?.cancel()
            throw error
        }
    }

    private static func abort(_ conversation: PiDurableKit.Conversation) async throws {
        try await conversation.abort(background: true)
    }

    private func sanitized(_ error: Error) -> AgentError {
        if let error = error as? AgentError {
            if case .runtime(let text) = error { return .runtime(RuntimeMapping.redact(text, secret: configuration?.apiKey ?? "")) }
            if case .modelRequestFailed(let text) = error { return .modelRequestFailed(RuntimeMapping.redact(text, secret: configuration?.apiKey ?? "")) }
            if case .cleanupFailed(let text) = error { return .cleanupFailed(RuntimeMapping.redact(text, secret: configuration?.apiKey ?? "")) }
            return error
        }
        return .runtime(RuntimeMapping.redact(error.localizedDescription, secret: configuration?.apiKey ?? ""))
    }

    private static func requiresSuccessfulCleanup(_ error: Error?) -> Bool {
        switch error as? AgentError {
        case .modelRequestFailed, .toolLimitReached, .toolExecutionPaused: true
        default: false
        }
    }

    private struct Session: Sendable {
        let harness: Harness
        let conversation: PiDurableKit.Conversation
        let model: ModelRef
        let url: URL
        let ownership: UUID
        let outcomeGate: RuntimeOutcomeGate
    }
    private struct ActiveRun {
        let id: UUID
        let conversationID: UUID
        let budget: RunBudget
        let completion: RuntimeCompletion
        var task: Task<Void, Never>?
        var session: Session?
        var stopCause: StopCause?
    }
}
