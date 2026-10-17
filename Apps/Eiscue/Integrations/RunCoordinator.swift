import EiscueAgentKit
import EiscueDeviceCore
import Foundation

/// Owns one execution from durable admission through runtime shutdown, device
/// cleanup and final publication. AppModel remains the observable projection.
@MainActor
final class RunCoordinator {
    private unowned let model: AppModel
    private let makeAgent: (AgentConfiguration, URL, [AgentTool]) -> AgentClient
    private var executingAgent: AgentClient?
    private var executingDevice: DeviceClient?

    private struct Context {
        let settings: ModelSettings
        let skill: AgentSkill?
        let device: DeviceClient
    }

    init(model: AppModel,
         makeAgent: @escaping (AgentConfiguration, URL, [AgentTool]) -> AgentClient = {
             AgentClient(configuration: $0, storageDirectory: $1, tools: $2)
         }) {
        self.model = model; self.makeAgent = makeAgent
    }

    @discardableResult
    func perform(conversationID: UUID, requestID: UUID, prompt: String, history: [AgentMessage], resume: Bool, attachments: [AgentAttachment] = [], runScope: TaskScope) async -> Bool {
        guard !model.isRunning else { return false }
        let context = Context(settings: model.modelSettings, skill: model.selectedSkill, device: model.deviceClient)
        // The transcript's pending marker covers the earlier message-save
        // boundary; this journal owns preparation and runtime admission.
        let preparationInterrupted = model.isBusy || model.currentScenePhase != .active || (runScope != .chat && !model.isDeviceReady)
        model.stopRequested = false; model.streamingText = ""; model.currentTool = ""
        model.lastTaskPresentation = nil; model.isReceivingResponse = false
        let runID = UUID()
        var runningAgent: AgentClient?
        var modelRequestFailed = false
        model.activeRun = RunRecord(id: runID, conversationID: conversationID, requestID: requestID, startedAt: Date(),
                              scope: runScope, model: context.settings.model, skill: context.skill.map { "\($0.id)@\($0.digest)" },
                              state: .preparing, detail: String(localized: "run.preparing", table: "Runtime"), events: [])
        model.activeRun?.submission = .pending
        model.activeRun?.promptVersion = SystemPromptBuilder.version
        model.syncBoardCompanion()
        do {
            try await model.persistActiveRun()
            guard !preparationInterrupted else {
                throw AgentError.runtime(String(localized: "run.preparation_interrupted", table: "Runtime"))
            }
            guard let key = try model.selectedModelAPIKey() else { throw SettingsError.missingKey }
            let config = try context.settings.configuration(apiKey: key)
            let capabilities: Set<DeviceCapability>
            if runScope == .chat { capabilities = [] }
            else {
                let status = await context.device.status()
                model.deviceStatus = status
                switch status {
                case .ready(let available): capabilities = available
                case .unavailable(let reason):
                    model.connectionMessage = reason
                    throw DeviceControlError.connection(reason)
                }
            }
            let tools = DeviceToolSession(capabilities: capabilities, client: context.device, scope: runScope, timeoutSeconds: context.settings.timeoutSeconds,
                                          maxOperations: context.settings.maxToolCalls,
                                          log: { [weak model] kind, detail in
                                              guard let model, model.activeRun?.id == runID else { throw CancellationError() }
                                              try await model.logEvent(kind, detail)
                                          },
                                          onUnknown: { [weak model] in await model?.stop(expectedRunID: runID, reason: String(localized: "run.unknown_delivery", table: "Runtime")) },
                                          onObservationWillCapture: { [weak model] in await model?.prepareDeviceObservation(for: runID) },
                                          onActionFinished: { [weak model] in model?.releaseDeviceTranscript(for: runID) },
                                          onPhaseChanged: { [weak model] _ in
                                              guard let model, model.activeRun?.id == runID else { return }
                                              model.updateTaskStatus()
                                          })
            model.deviceTools = tools
            var availableTools = tools.tools
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--tool-timeline-fixture") {
                availableTools = AppModel.timelineFixtureTools
            }
            #endif
            model.agent = makeAgent(config, model.runtimeDirectory, availableTools)
            runningAgent = model.agent
            executingAgent = runningAgent
            executingDevice = context.device
            if runScope != .chat {
                try await model.background.begin(taskID: runID, title: String(localized: "run.activity_title", table: "Runtime"), subtitle: String(localized: "run.preparing_device", table: "Runtime"),
                                           totalUnitCount: TaskStatusPresentation.progressTotalUnitCount, onExpiration: { [weak model] in
                    Task { await model?.stop(expectedRunID: runID, reason: String(localized: "run.background_ended", table: "Runtime")) }
                })
            }
            guard !model.stopRequested else { throw CancellationError() }
            model.activeRun?.state = .running; model.activeRun?.detail = resume ? String(localized: "run.resuming", table: "Runtime") : String(localized: "run.waiting_model", table: "Runtime")
            try await model.logEvent("run.started", resume ? String(localized: "run.user_resumed", table: "Runtime") : String(format: String(localized: "run.started_scope", table: "Runtime"), runScope.title))
            guard !model.stopRequested else { throw CancellationError() }
            let systemPrompt = SystemPromptBuilder.build(scope: runScope, skill: context.skill)
            let request = AgentRequest(conversationID: conversationID, requestID: requestID, prompt: prompt,
                                       systemPrompt: systemPrompt, maxToolCalls: context.settings.maxToolCalls,
                                       timeoutSeconds: Double(context.settings.timeoutSeconds), mode: resume ? .resume : .message,
                                       history: history, attachments: attachments)
            let events = try await runningAgent!.run(request: request)
            guard !model.stopRequested else {
                try await runningAgent?.cancel()
                throw CancellationError()
            }
            for try await event in events {
                try await receive(event, conversationID: conversationID, requestID: requestID)
            }
            model.activeRun?.state = model.stopRequested ? .interrupted : .completed
            if !model.stopRequested { model.activeRun?.detail = String(localized: "run.round_finished", table: "Runtime") }
        } catch {
            // Losing durable host state stops the independent runtime before
            // releasing the UI lock or allowing another engine to open this DB.
            model.deviceTools?.stop()
            var reportedError = error
            do {
                try await runningAgent?.cancel()
                if case AgentError.modelRequestFailed = error { modelRequestFailed = true }
            } catch { reportedError = error }
            // Read the submission before the optional-chain write begins its
            // exclusive access to model.activeRun; reading it in the RHS traps.
            let interrupted = model.stopRequested || error is CancellationError || model.activeRun?.submission == .pending
            let pauseReason: RunPauseReason?
            if !interrupted, model.deviceTools?.hasUnknownOutcome != true {
                switch reportedError {
                case AgentError.toolLimitReached: pauseReason = .toolLimit
                case AgentError.toolExecutionPaused:
                    switch model.deviceTools?.pauseReason {
                    case .verificationUnavailable: pauseReason = .verification
                    case .connectionLost: pauseReason = .connection
                    default: pauseReason = .noProgress
                    }
                default: pauseReason = nil
                }
            } else { pauseReason = nil }
            model.activeRun?.state = interrupted ? .interrupted : (pauseReason == nil ? .failed : .paused)
            model.activeRun?.pauseReason = pauseReason
            if !model.stopRequested {
                model.activeRun?.detail = pauseReason == .toolLimit ? RunPauseReason.toolLimit.detail : model.safeError(reportedError)
            }
        }
        return await finish(runID: runID, conversationID: conversationID, context: context, modelRequestFailed: modelRequestFailed)
    }

    private func finish(runID: UUID, conversationID: UUID, context: Context, modelRequestFailed: Bool) async -> Bool {
        model.companionFinalizingRunID = runID
        model.deviceTools?.stop()
        model.activeRun?.interruptOpenActivities()
        model.updateTaskStatus(isFinishing: true)
        if let run = model.activeRun {
            do {
                try await DeviceRunCleanup.finish(run: run, disconnectAfterTask: model.disconnectAfterTask,
                    modelRequestFailed: modelRequestFailed, deviceTools: model.deviceTools, stopRequested: model.stopRequested,
                    finishConnection: { [model] in
                        try await context.device.finishTask()
                        model.screenshot = nil
                        await model.refreshDeviceStatus()
                    },
                    disconnect: { [model] in await model.releaseDeviceConnection() })
            } catch {
                model.activeRun?.state = .interrupted
                model.activeRun?.pauseReason = nil
                model.activeRun?.detail = model.safeError(error)
            }
        }
        model.activeRun?.endedAt = Date()
        if model.activeRun?.state == .interrupted { model.interruptedConversationIDs.insert(conversationID) }
        else { model.interruptedConversationIDs.remove(conversationID) }
        do { try await model.persistActiveRun() }
        catch {
            let message = String(format: String(localized: "error.save_run", table: "Runtime"), model.safeError(error))
            model.activeRun?.state = .failed
            model.activeRun?.pauseReason = nil
            model.activeRun?.detail = message
            model.errorMessage = message
            if model.activeRun?.scope != .chat { await model.releaseDeviceConnection() }
        }
        model.companionFinalizingRunID = nil
        model.updateTaskStatus()
        let systemActivityUpdated = model.background.end(taskID: runID, success: model.activeRun?.state == .completed)
        if let completed = model.activeRun, model.currentScenePhase == .background {
            await model.taskNotifications.notify(runID: completed.id, state: completed.state,
                                           systemActivityUpdated: systemActivityUpdated)
        }
        if let completed = model.activeRun { model.runs.removeAll { $0.id == completed.id }; model.runs.insert(completed, at: 0) }
        let succeeded = model.activeRun?.state == .completed
        model.activeRun = nil; model.streamingText = ""; model.currentTool = ""; model.deviceTools = nil
        model.lastTaskPresentation = nil; model.isReceivingResponse = false
        executingAgent = nil; executingDevice = nil
        return succeeded
    }

    func stop(expectedRunID: UUID? = nil, reason: String = String(localized: "run.user_stopped", table: "Runtime")) async {
        guard let run = model.activeRun, run.state == .running || run.state == .preparing,
              expectedRunID == nil || expectedRunID == run.id, !model.isStopping else { return }
        let runningAgent = executingAgent ?? model.agent
        let runningDevice = executingDevice ?? model.deviceClient
        model.isStopping = true
        defer { model.isStopping = false }
        model.stopRequested = true; model.deviceTools?.stop(); model.activeRun?.detail = reason
        model.updateTaskStatus(isFinishing: true)
        let cancellation = Task { try await runningAgent?.cancel() }
        if run.scope != .chat {
            await runningDevice.disconnect()
            await model.refreshDeviceStatus()
            model.screenshot = nil
            if case .unavailable(let reason) = model.deviceStatus { model.connectionMessage = reason }
        }
        do { try await cancellation.value } catch { model.errorMessage = String(format: String(localized: "error.stop_requested", table: "Runtime"), model.safeError(error)) }
        // `perform` still owns stream consumption, the final journal write,
        // notification, and lease completion. Runtime cancellation alone does
        // not prove that host cleanup has finished.
    }

    private func receive(_ event: AgentEvent, conversationID: UUID, requestID: UUID) async throws {
        switch event {
        case .requestAccepted:
            model.activeRun?.submission = .accepted
            try await model.persistActiveRun()
            if var conversation = model.conversations.first(where: { $0.id == conversationID }),
               conversation.pendingRequestID == requestID {
                conversation.pendingRequestID = nil
                try await model.repository.save(conversation); model.upsert(conversation)
            }
        case .assistantText(let text):
            model.streamingText = text
            model.isReceivingResponse = !text.isEmpty
            model.updateTaskStatus()
        case .message(let message):
            if var conversation = model.conversations.first(where: { $0.id == conversationID }) {
                if !conversation.messages.contains(where: { $0.id == message.id }) { conversation.messages.append(message) }
                conversation.updatedAt = Date(); try await model.repository.save(conversation); model.upsert(conversation)
                model.streamingText = ""
            }
        case .toolStarted(let call):
            model.isReceivingResponse = false
            model.currentTool = call.name
            model.activeRun?.detail = String(format: String(localized: "run.calling_tool", table: "Runtime"), DeviceToolPresentation.title(for: call.name) ?? call.name)
            if let runID = model.activeRun?.id {
                let activityID = "\(runID.uuidString):\(call.id)"
                if !(model.activeRun?.activities ?? []).contains(where: { $0.id == activityID }) {
                    var activities = model.activeRun?.activities ?? []
                    activities.append(ToolActivity(id: activityID, name: call.name,
                                                   arguments: model.sanitizedActivityText(ToolActivityFormatting.arguments(call.arguments)),
                                                   precedingMessageID: model.conversations.first(where: { $0.id == conversationID })?.messages.last?.id))
                    model.activeRun?.activities = activities
                }
            }
            try await model.logEvent("tool.started", call.name)
        case .toolFinished(let completion):
            model.isReceivingResponse = false
            model.currentTool = ""
            if let runID = model.activeRun?.id {
                let activityID = "\(runID.uuidString):\(completion.call.id)"
                model.toolImagePreviews.record(completion, activityID: activityID, conversationID: conversationID)
                var activities = model.activeRun?.activities ?? []
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
                model.activeRun?.activities = activities
            }
            try await model.logEvent(completion.result.isError ? "tool.failed" : "tool.finished", completion.call.name)
            if completion.result.isError {
                let text = completion.result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
                try await model.logEvent("tool.error", model.sanitizedText(text))
            }
        case .finished(let outcome):
            if outcome == .cancelled { model.stopRequested = true }
        }
    }
}
