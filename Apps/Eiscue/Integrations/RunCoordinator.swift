import EiscueAgentKit
import EiscueDeviceCore
import Foundation
import Observation

/// Owns one execution from durable admission through runtime shutdown, device
/// cleanup and final publication. AppModel remains the observable projection.
@MainActor @Observable
final class RunCoordinator {
    private unowned let model: AppModel
    private let makeAgent: (AgentConfiguration, URL, [AgentTool]) -> AgentClient
    private(set) var current: RunSession?

    private struct Context {
        let settings: ModelSettings
        let skill: AgentSkill?
        let device: DeviceClient
    }

    init(model: AppModel,
         makeAgent: ((AgentConfiguration, URL, [AgentTool]) -> AgentClient)? = nil) {
        self.model = model; self.makeAgent = makeAgent ?? { [unowned model] in model.agentFactory($0, $1, $2) }
    }

    #if DEBUG
    func publish(_ record: RunRecord?) {
        if current?.id != record?.id, let previous = current { model.releaseDeviceTranscript(for: previous.id) }
        guard let record else { current = nil; return }
        if let current, current.id == record.id { current.record = record }
        else { current = RunSession(record: record, lease: nil) }
    }

    func updateSnapshot(_ update: (RunSession) -> Void) { if let current { update(current) } }
    #endif

    @discardableResult
    func perform(conversationID: UUID, requestID: UUID, prompt: String, history: [AgentMessage], resume: Bool, attachments: [AgentAttachment] = [], runScope: TaskScope) async -> Bool {
        guard !model.isRunning else { return false }
        let context = Context(settings: model.modelSettings, skill: model.selectedSkill, device: model.deviceClient)
        // The transcript's pending marker covers the earlier message-save
        // boundary; this journal owns preparation and runtime admission.
        let preparationInterrupted = model.isBusy || model.currentScenePhase != .active || (runScope != .chat && !model.isDeviceReady)
        let runID = UUID()
        let record = RunRecord(id: runID, conversationID: conversationID, requestID: requestID, startedAt: Date(),
                              scope: runScope, model: context.settings.model, skill: context.skill.map { "\($0.id)@\($0.digest)" },
                              state: .preparing, detail: String(localized: "run.preparing", table: "Runtime"), events: [])
        let lease = runScope == .chat ? nil : try? model.deviceSession.acquire(.run(runID))
        let session = RunSession(record: record, lease: lease)
        current = session
        session.record.submission = .pending
        session.record.promptVersion = SystemPromptBuilder.version
        model.syncBoardCompanion()
        session.completion = Task { [self] in
            await execute(session: session, context: context, conversationID: conversationID, requestID: requestID,
                          prompt: prompt, history: history, resume: resume, attachments: attachments,
                          preparationInterrupted: preparationInterrupted)
        }
        let result = await session.completion.value
        if current === session { current = nil }
        return result.state == .completed
    }

    private func execute(session: RunSession, context: Context, conversationID: UUID, requestID: UUID,
                         prompt: String, history: [AgentMessage], resume: Bool, attachments: [AgentAttachment],
                         preparationInterrupted: Bool) async -> RunRecord {
        let runID = session.id, runScope = session.scope
        var runningAgent: AgentClient?
        var modelRequestFailed = false
        var eventSaveFailure: String?
        do {
            try await persist(session)
            try checkRunning(session)
            guard !preparationInterrupted, runScope == .chat || session.lease != nil else {
                throw AgentError.runtime(String(localized: "run.preparation_interrupted", table: "Runtime"))
            }
            guard let key = try model.selectedModelAPIKey() else { throw SettingsError.missingKey }
            let config = try context.settings.configuration(apiKey: key)
            let capabilities: Set<DeviceCapability>
            if runScope == .chat { capabilities = [] }
            else {
                let identity = model.deviceSession.identity
                let status = await context.device.status()
                try checkRunning(session)
                guard context.device.device === model.deviceClient.device,
                      model.deviceSession.updateStatus(status, expected: identity) else { throw CancellationError() }
                switch status {
                case .ready(let available): capabilities = available
                case .unavailable(let reason):
                    model.connectionMessage = reason
                    throw DeviceControlError.connection(reason)
                }
            }
            let tools = DeviceToolSession(capabilities: capabilities, client: context.device, scope: runScope, timeoutSeconds: context.settings.timeoutSeconds,
                                          maxOperations: context.settings.maxToolCalls,
                                          log: { [weak self, weak session] kind, detail in
                                              guard let self, let session, self.current === session else { throw CancellationError() }
                                              try await self.logEvent(session: session, kind, detail)
                                          },
                                          onUnknown: { [weak self, weak session] in
                                              guard let self, let session, self.current === session else { return }
                                              await self.stop(expectedRunID: runID, reason: String(localized: "run.unknown_delivery", table: "Runtime"), cause: .outcomeUnknown(toolName: session.currentTool))
                                          },
                                          onObservationWillCapture: { [weak model] in await model?.prepareDeviceObservation(for: runID) },
                                          onActionFinished: { [weak model] in model?.releaseDeviceTranscript(for: runID) },
                                          onPhaseChanged: { [weak self, weak session] _ in
                                              guard let self, let session, self.current === session else { return }
                                              self.updateTaskStatus(session: session)
                                          })
            session.tools = tools
            var availableTools = tools.tools
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--tool-timeline-fixture") {
                availableTools = AppModel.timelineFixtureTools
            }
            #endif
            runningAgent = makeAgent(config, model.runtimeDirectory, availableTools)
            session.bind(engine: runningAgent!)
            try checkRunning(session)
            if runScope != .chat {
                let preparation = Task { [model] in try await model.background.begin(taskID: runID, title: String(localized: "run.activity_title", table: "Runtime"), subtitle: String(localized: "run.preparing_device", table: "Runtime"),
                                           totalUnitCount: TaskStatusPresentation.progressTotalUnitCount, onExpiration: { [weak model] in
                    Task { await model?.stop(expectedRunID: runID, reason: String(localized: "run.background_ended", table: "Runtime")) }
                }) }
                session.preparation = preparation
                try await preparation.value
                session.preparation = nil
            }
            try checkRunning(session)
            session.transition(to: .running)
            session.record.state = .running; session.record.detail = resume ? String(localized: "run.resuming", table: "Runtime") : String(localized: "run.waiting_model", table: "Runtime")
            try await logEvent(session: session, "run.started", resume ? String(localized: "run.user_resumed", table: "Runtime") : String(format: String(localized: "run.started_scope", table: "Runtime"), runScope.title))
            try checkRunning(session)
            let systemPrompt = SystemPromptBuilder.build(scope: runScope, skill: context.skill)
            let request = AgentRequest(conversationID: conversationID, requestID: requestID, prompt: prompt,
                                       systemPrompt: systemPrompt, maxToolCalls: context.settings.maxToolCalls,
                                       timeoutSeconds: Double(context.settings.timeoutSeconds), mode: resume ? .resume : .message,
                                       history: history, attachments: attachments)
            let events = try await runningAgent!.run(request: request)
            if session.stopCause != nil {
                do { try await runningAgent?.cancel() }
                catch { session.record.cleanupFailure = model.safeError(error) }
            }
            // Admission and a tool outcome can already be committed while the
            // stream crosses actors. Cancellation must drain those facts too.
            for try await event in events {
                do { try await receive(event, session: session, conversationID: conversationID, requestID: requestID) }
                catch {
                    eventSaveFailure = String(format: String(localized: "error.save_run", table: "Runtime"), model.safeError(error))
                    session.requestStop(.eventSaveFailed)
                    throw error
                }
            }
            session.record.state = session.record.stopCause?.isOutcomeUnknown == true ? .outcomeUnknown : ((session.stopCause != nil) ? .interrupted : .completed)
            if session.stopCause == nil { session.record.detail = String(localized: "run.round_finished", table: "Runtime") }
        } catch {
            // Losing durable host state stops the independent runtime before
            // releasing the UI lock or allowing another engine to open this DB.
            if session.tools?.hasUnknownOutcome == true, session.stopCause?.isOutcomeUnknown != true {
                markUnknownOutcome(session, toolName: session.currentTool)
            }
            session.tools?.stop()
            var reportedError = error
            do {
                try await runningAgent?.cancel()
                if case AgentError.modelRequestFailed = error { modelRequestFailed = true }
            } catch {
                session.record.cleanupFailure = model.safeError(error)
                reportedError = error
            }
            if let eventSaveFailure {
                session.record.cleanupFailure = session.record.cleanupFailure.map { $0 + "\n" + eventSaveFailure } ?? eventSaveFailure
                model.errorMessage = eventSaveFailure
            }
            let persistenceFailed = eventSaveFailure != nil
            let interrupted = (session.stopCause != nil && !persistenceFailed) || error is CancellationError || session.record.submission == .pending
            let pauseReason: RunPauseReason?
            if !interrupted, session.tools?.hasUnknownOutcome != true {
                switch reportedError {
                case AgentError.toolLimitReached: pauseReason = .toolLimit
                case AgentError.toolExecutionPaused(let reason):
                    switch reason {
                    case .verificationUnavailable: pauseReason = .verification
                    case .connectionLost: pauseReason = .connection
                    case .toolBudget: pauseReason = .toolLimit
                    default: pauseReason = .noProgress
                    }
                default: pauseReason = nil
                }
            } else { pauseReason = nil }
            session.record.state = session.stopCause?.isOutcomeUnknown == true ? .outcomeUnknown :
                (interrupted ? .interrupted : (pauseReason == nil ? .failed : .paused))
            session.record.pauseReason = pauseReason
            if session.stopCause?.isOutcomeUnknown != true, session.stopCause == nil || persistenceFailed {
                session.record.detail = pauseReason == .toolLimit ? RunPauseReason.toolLimit.detail : model.safeError(reportedError)
            }
        }
        return await finish(session: session, conversationID: conversationID, context: context, modelRequestFailed: modelRequestFailed)
    }

    private func finish(session: RunSession, conversationID: UUID, context: Context, modelRequestFailed: Bool) async -> RunRecord {
        let runID = session.id
        session.transition(to: .finishing)
        await session.stopCleanup?.value
        model.companionFinalizingRunID = runID
        session.tools?.stop()
        session.record.interruptOpenActivities()
        updateTaskStatus(session: session, isFinishing: true)
        do {
            let run = session.record
            do {
                try await DeviceRunCleanup.finish(run: run, disconnectAfterTask: model.disconnectAfterTask,
                    modelRequestFailed: modelRequestFailed, deviceTools: session.tools, stopRequested: (session.stopCause != nil),
                    finishConnection: { [model] in
                        try await context.device.finishTask()
                        if context.device.device === model.deviceClient.device {
                            model.screenshot = nil
                            await model.refreshDeviceStatus()
                        }
                    },
                    disconnect: { [model] in await model.releaseDeviceConnection(client: context.device) })
            } catch {
                session.record.cleanupFailure = model.safeError(error)
                model.errorMessage = model.safeError(error)
            }
        }
        session.record.endedAt = Date()
        if session.record.state == .interrupted || session.record.state == .outcomeUnknown { model.interruptedConversationIDs.insert(conversationID) }
        else { model.interruptedConversationIDs.remove(conversationID) }
        do { try await persist(session) }
        catch {
            let message = String(format: String(localized: "error.save_run", table: "Runtime"), model.safeError(error))
            session.record.cleanupFailure = session.record.cleanupFailure.map { $0 + "\n" + message } ?? message
            if session.record.stopCause?.isOutcomeUnknown != true {
                session.record.state = .failed
                session.record.pauseReason = nil
                session.record.detail = message
            }
            model.errorMessage = message
            if session.record.scope != .chat { await model.releaseDeviceConnection(client: context.device) }
        }
        model.companionFinalizingRunID = nil
        updateTaskStatus(session: session)
        let systemActivityUpdated = model.background.end(taskID: runID, success: session.record.state == .completed && session.record.cleanupFailure == nil)
        if model.currentScenePhase == .background {
            let completed = session.record
            await model.taskNotifications.notify(runID: completed.id, state: completed.state,
                                           systemActivityUpdated: systemActivityUpdated)
        }
        let completed = session.record
        model.runs.removeAll { $0.id == completed.id }; model.runs.insert(completed, at: 0)
        let completedRecord = session.record
        session.transition(to: .ended(completedRecord))
        session.lease?.release()
        model.releaseDeviceTranscript(for: session.id)
        if current === session { current = nil }
        return completedRecord
    }

    func stop(expectedRunID: UUID? = nil, reason: String = String(localized: "run.user_stopped", table: "Runtime"), cause: StopCause = .userRequested) async {
        guard let session = current, session.record.state == .running || session.record.state == .preparing,
              expectedRunID == nil || expectedRunID == session.id, session.stopCleanup == nil else { return }
        session.requestStop(cause)
        session.record.stopCause = session.stopCause
        session.isCancelling = true
        session.tools?.stop(); session.record.detail = reason
        updateTaskStatus(session: session, isFinishing: true)
        let cleanup = Task { [self] in
            let cancellation = Task { try await session.engine?.cancel() }
            if let device = session.device {
                await model.releaseDeviceConnection(client: device)
            }
            do { try await cancellation.value }
            catch {
                session.record.cleanupFailure = model.safeError(error)
                if current === session { model.errorMessage = String(format: String(localized: "error.stop_requested", table: "Runtime"), model.safeError(error)) }
            }
            session.isCancelling = false
        }
        session.stopCleanup = cleanup
        await cleanup.value
        // `perform` still owns stream consumption, the final journal write,
        // notification, and lease completion. Runtime cancellation alone does
        // not prove that host cleanup has finished.
    }

    func stopAndWait(runID: UUID) async -> RunRecord? {
        guard let session = current, session.id == runID else { return nil }
        await stop(expectedRunID: runID)
        guard let completion = session.completion else { return session.record }
        return await completion.value
    }

    func clearStreamingText() { current?.streamingText = "" }
    func interruptTools(expectedRunID: UUID? = nil) {
        guard let current, expectedRunID == nil || current.id == expectedRunID else { return }
        current.tools?.stop()
    }

    func persistActiveRun() async throws { if let current { try await persist(current) } }
    private func persist(_ session: RunSession) async throws { try await model.journal.save(session.record) }

    func logEvent(_ kind: String, _ summary: String) async throws {
        if let current { try await logEvent(session: current, kind, summary) }
    }
    private func logEvent(session: RunSession, _ kind: String, _ summary: String) async throws {
        session.record.events.append(RunLogEntry(kind: kind, summary: summary))
        try await persist(session)
        updateTaskStatus(session: session)
    }
    func updateTaskStatus(isFinishing: Bool = false) {
        guard let current else { model.syncBoardCompanion(isFinishing: isFinishing); return }
        updateTaskStatus(session: current, isFinishing: isFinishing)
    }
    private func updateTaskStatus(session: RunSession, isFinishing: Bool = false) {
        guard current === session else { return }
        model.syncBoardCompanion(isFinishing: isFinishing)
        guard let presentation = model.taskStatusPresentation(isFinishing: isFinishing),
              presentation != session.lastTaskPresentation else { return }
        if model.background.update(taskID: session.id, completedUnitCount: presentation.completedWorkUnits,
                                   totalUnitCount: presentation.totalWorkUnits, title: presentation.title, subtitle: presentation.subtitle) {
            session.lastTaskPresentation = presentation
        }
    }
    private func checkRunning(_ session: RunSession) throws {
        guard current === session, session.stopCause == nil else { throw CancellationError() }
    }

    private func markUnknownOutcome(_ session: RunSession, toolName: String) {
        session.requestStop(.outcomeUnknown(toolName: DeviceToolSpec(rawValue: toolName)?.rawValue ?? ""))
        session.record.detail = String(localized: "run.unknown_delivery", table: "Runtime")
    }

    private func receive(_ event: AgentEvent, session: RunSession, conversationID: UUID, requestID: UUID) async throws {
        switch event {
        case .requestAccepted:
            session.record.submission = .accepted
            try await persist(session)
            if var conversation = model.conversations.first(where: { $0.id == conversationID }),
               conversation.pendingRequestID == requestID {
                conversation.pendingRequestID = nil
                try await model.repository.save(conversation); model.upsert(conversation)
            }
        case .assistantText(let text):
            session.streamingText = text
            session.isReceivingResponse = !text.isEmpty
            updateTaskStatus(session: session)
        case .message(let message):
            if var conversation = model.conversations.first(where: { $0.id == conversationID }) {
                if !conversation.messages.contains(where: { $0.id == message.id }) { conversation.messages.append(message) }
                conversation.updatedAt = Date(); try await model.repository.save(conversation); model.upsert(conversation)
                session.streamingText = ""
            }
        case .toolStarted(let call):
            session.isReceivingResponse = false
            session.currentTool = call.name
            session.record.detail = String(format: String(localized: "run.calling_tool", table: "Runtime"), DeviceToolPresentation.title(for: call.name) ?? call.name)
            do {
                let runID = session.id
                let activityID = "\(runID.uuidString):\(call.id)"
                if !(session.record.activities ?? []).contains(where: { $0.id == activityID }) {
                    var activities = session.record.activities ?? []
                    activities.append(ToolActivity(id: activityID, name: call.name,
                                                   arguments: model.sanitizedActivityText(ToolActivityFormatting.arguments(call.arguments)),
                                                   precedingMessageID: model.conversations.first(where: { $0.id == conversationID })?.messages.last?.id))
                    session.record.activities = activities
                }
            }
            try await logEvent(session: session, "tool.started", call.name)
        case .toolFinished(let completion):
            // The terminal event may still be buffered when this event's save
            // fails. Preserve the already committed delivery fact first.
            if completion.result.outcome == .unknown { markUnknownOutcome(session, toolName: completion.call.name) }
            session.isReceivingResponse = false
            session.currentTool = ""
            do {
                let runID = session.id
                let activityID = "\(runID.uuidString):\(completion.call.id)"
                model.toolImagePreviews.record(completion, activityID: activityID, conversationID: conversationID)
                var activities = session.record.activities ?? []
                if let index = activities.firstIndex(where: { $0.id == activityID }) {
                    activities[index].endedAt = Date()
                    activities[index].output = model.sanitizedActivityText(completion.result.text)
                    activities[index].isError = completion.result.isError
                } else {
                    activities.append(ToolActivity(id: activityID, name: completion.call.name, endedAt: Date(),
                                                   arguments: model.sanitizedActivityText(ToolActivityFormatting.arguments(completion.call.arguments)),
                                                   output: model.sanitizedActivityText(completion.result.text), isError: completion.result.isError,
                                                   precedingMessageID: model.conversations.first(where: { $0.id == conversationID })?.messages.last?.id))
                }
                session.record.activities = activities
            }
            try await logEvent(session: session, completion.result.isError ? "tool.failed" : "tool.finished", completion.call.name)
            if completion.result.isError {
                let text = completion.result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
                try await logEvent(session: session, "tool.error", model.sanitizedText(text))
            }
        case .cleanupFailed(let message):
            session.record.cleanupFailure = model.sanitizedText(message)
        case .finished(let outcome):
            if outcome == .cancelled {
                session.requestStop(.engineCancelled)
            }
            if case .stopped(let cause) = outcome {
                session.requestStop(cause)
            }
        }
    }
}
