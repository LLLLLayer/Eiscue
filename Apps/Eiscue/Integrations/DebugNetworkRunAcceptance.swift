#if DEBUG && !EISCUE_HID_ONLY
import EiscueAgentKit
import EiscueDeviceCore
import Foundation
import SwiftUI
import UIKit

/// Explicit, zero-model host/device acceptance. This is a scripted diagnostic,
/// not Pi, visual reasoning, or a replacement production engine.
@MainActor
enum DebugNetworkRunAcceptance {
    private static var installation: Installation?
    nonisolated static let prompt = "DEBUG network acceptance: scripted device checks; zero model calls."

    static func makeModel() -> AppModel {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--network-run-acceptance") else { return AppModel() }
        let installed = Installation(arguments: arguments)
        installation = installed
        return installed.makeModel()
    }

    static func runIfRequested(model: AppModel) async {
        guard let installation else { return }
        await installation.run(model: model)
    }

    static var usesInputTarget: Bool { installation?.plan?.kind == .inflightStop }
    static func armInput(width: Int, height: Int) throws -> InputCoordinates {
        guard let installation else { throw Failure.invalidArguments }
        return try installation.armInput(width: width, height: height)
    }
    static func receive(_ touches: Set<UITouch>, phase: String, window: UIWindow?) {
        installation?.receive(touches, phase: phase, window: window)
    }

    struct InputCoordinates: Sendable { let fromX: Double; let fromY: Double; let toX: Double; let toY: Double }

    struct Plan: Sendable {
        enum Kind: String, Sendable { case background, inflightStop, appReturn }
        let kind: Kind
        let backend: DeviceControlBackend
        let seconds: Double
        let interval: Double
        let cancelAfter: Double?
        let resumeTunnel: Bool
        var sampleGapLimit: Double { interval + 5 }

        init(arguments: [String]) throws {
            func argument(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            guard !arguments.contains("--ui-testing"), !arguments.contains("--owned-device-check"),
                  !arguments.contains("--ble-device-check"),
                  let backend = argument("--network-run-backend").flatMap(DeviceControlBackend.init(rawValue:)),
                  backend == .coreDevice || backend == .xcTest else { throw Failure.invalidArguments }
            let kindName = argument("--network-run-case") ?? "background"
            if arguments.contains("--network-run-case"), argument("--network-run-case") == nil { throw Failure.invalidArguments }
            guard let kind = Kind(rawValue: kindName) else { throw Failure.invalidArguments }
            let parsedMinutes = argument("--network-run-minutes").flatMap(Double.init)
            let parsedInterval = argument("--network-run-interval-seconds").flatMap(Double.init)
            if arguments.contains("--network-run-minutes"), parsedMinutes == nil { throw Failure.invalidArguments }
            if arguments.contains("--network-run-interval-seconds"), parsedInterval == nil { throw Failure.invalidArguments }
            let minutes = parsedMinutes ?? 1
            let interval = parsedInterval ?? 15
            guard minutes.isFinite, (0.1...15).contains(minutes), interval.isFinite, (15...60).contains(interval) else {
                throw Failure.invalidArguments
            }
            let cancel = argument("--network-run-cancel-after-seconds").flatMap(Double.init)
            if arguments.contains("--network-run-cancel-after-seconds"), cancel == nil { throw Failure.invalidArguments }
            guard cancel.map({ $0.isFinite && (1...minutes * 60).contains($0) }) ?? true else { throw Failure.invalidArguments }
            guard kind == .background || cancel == nil else { throw Failure.invalidArguments }
            self.kind = kind
            self.backend = backend; seconds = minutes * 60; self.interval = interval; cancelAfter = cancel
            resumeTunnel = arguments.contains("--resume-existing-local-tunnel")
        }
    }

    enum Failure: String, Error {
        case invalidArguments, physicalDeviceRequired, permissionDisabled, identityRequired
        case tunnelRequired, connectionFailed, wrongScope, missingTool, invalidFrame, didNotBackground
        case unexpectedRequest, budget, persistence, cleanupUnconfirmed
        case backgroundGapExceeded, backgroundLeaseInactive
        case inputTargetUnavailable, inflightStopMissed, didNotReturnToApp
    }

    @MainActor private final class Installation {
        let report = Report()
        let store: ScriptStore
        let arguments: [String]
        var plan: Plan?
        var configurationFailure: String?
        var credentials: CredentialStore?
        var account: String?
        var started = false
        weak var model: AppModel?
        var inputRunID: UUID?
        var inputStart: CGPoint?
        var inputTouch: UITouch?
        var touchStop: Task<Void, Never>?

        init(arguments: [String]) {
            self.arguments = arguments
            store = ScriptStore(directory: report.directory.appendingPathComponent("Admission", isDirectory: true))
            do { plan = try Plan(arguments: arguments) }
            catch { configurationFailure = Failure.invalidArguments.rawValue }
        }

        func makeModel() -> AppModel {
            let suite = "org.eiscue.network-run-acceptance.\(report.id.uuidString)"
            let preferences = UserDefaults(suiteName: suite)!
            preferences.set(1, forKey: "onboardingVersion")
            preferences.set(DeviceConnectionMethod.localVPN.rawValue, forKey: "deviceConnectionMethod")
            preferences.set((plan?.backend ?? .coreDevice).rawValue, forKey: "deviceControlBackend")
            preferences.set(UserDefaults.standard.object(forKey: "allowsDeviceControl") as? Bool ?? true, forKey: "allowsDeviceControl")
            preferences.set(false, forKey: "disconnectAfterTask")
            var settings = ModelSettings()
            settings.baseURL = "https://network-acceptance.invalid"
            settings.model = "debug-script-zero-model"
            settings.maxToolCalls = plan?.kind == .appReturn ? 7 : 70
            settings.timeoutSeconds = Int((plan?.seconds ?? 60) + 120)
            let profile = ModelProfile(id: UUID(), name: "", settings: settings)
            let credentials = CredentialStore(service: suite)
            self.credentials = credentials; account = profile.credentialAccount
            do {
                try FileManager.default.createDirectory(at: report.directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                preferences.set(try JSONEncoder().encode(ModelProfileState(profiles: [profile], selectedID: profile.id)), forKey: ModelProfileState.preferencesKey)
                // A public marker in a fresh diagnostic-only Keychain service.
                // No original model account is read or modified.
                try credentials.write("debug-placeholder-not-a-model-secret", account: profile.credentialAccount)
            } catch { configurationFailure = Failure.persistence.rawValue }
            let background = Background(report: report)
            let notifications = Notifications(report: report)
            let store = store, report = report, plan = plan
            let model = AppModel(storageDirectory: report.directory.appendingPathComponent("Host", isDirectory: true),
                preferences: preferences, credentialStore: credentials, background: background, notifications: notifications,
                agentFactory: { _, _, tools in
                    // Deliberately ignores the model configuration. No branch
                    // constructs the network-backed AgentClient initializer.
                    AgentClient(engine: ScriptEngine(plan: plan, tools: tools, store: store, report: report))
                })
            self.model = model
            return model
        }

        func armInput(width: Int, height: Int) throws -> InputCoordinates {
            let proof = OwnedDeviceCheckState.shared
            guard plan?.kind == .inflightStop, let model, let runID = model.activeRun?.id,
                  report.value.runID == runID, UIApplication.shared.applicationState == .active,
                  let window = proof.window, let scene = window.windowScene,
                  scene.activationState == .foregroundActive, scene.effectiveGeometry.interfaceOrientation == .portrait,
                  proof.orientation == .portrait, proof.scroll.height > 60, proof.scroll.width > 0,
                  window.bounds.contains(proof.scroll), width > 1, height > width else { throw Failure.inputTargetUnavailable }
            let bounds = scene.screen.bounds
            guard bounds.width > 0, bounds.height > 0,
                  abs(Double(width) / Double(height) - Double(bounds.width / bounds.height)) < 0.01 else { throw Failure.inputTargetUnavailable }
            let start = CGPoint(x: proof.scroll.midX, y: proof.scroll.maxY - 30)
            let end = CGPoint(x: proof.scroll.midX, y: proof.scroll.minY + 30)
            let screenStart = window.convert(start, to: scene.screen.coordinateSpace)
            let screenEnd = window.convert(end, to: scene.screen.coordinateSpace)
            inputRunID = runID; inputStart = start; inputTouch = nil
            report.value.inputArmedUptime = ProcessInfo.processInfo.systemUptime
            report.value.inputStartPoints = [Double(start.x), Double(start.y)]
            report.value.inputEndPoints = [Double(end.x), Double(end.y)]
            report.event("inflight_armed")
            return InputCoordinates(fromX: Double((screenStart.x - bounds.minX) / bounds.width) * Double(width),
                fromY: Double((screenStart.y - bounds.minY) / bounds.height) * Double(height),
                toX: Double((screenEnd.x - bounds.minX) / bounds.width) * Double(width),
                toY: Double((screenEnd.y - bounds.minY) / bounds.height) * Double(height))
        }

        func receive(_ touches: Set<UITouch>, phase: String, window: UIWindow?) {
            guard let runID = inputRunID, let start = inputStart, let armed = report.value.inputArmedUptime,
                  let model, window === OwnedDeviceCheckState.shared.window else { return }
            for touch in touches {
                let point = touch.location(in: window)
                if phase == "began", inputTouch == nil, report.value.firstTouchDownUptime == nil,
                   let requested = report.value.inputCommandStartedUptime, model.activeRun?.id == runID,
                   touch.timestamp >= max(armed, requested), abs(point.x - start.x) <= 16, abs(point.y - start.y) <= 16 {
                    inputTouch = touch
                    report.value.firstTouchDownUptime = touch.timestamp
                    report.event("real_touch_began")
                    touchStop = Task { @MainActor [weak self, weak model] in
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                        guard let self, let model, self.inputRunID == runID,
                              model.activeRun?.id == runID, self.report.value.terminalTouchUptime == nil else { return }
                        self.report.value.stopRequestedUptime = ProcessInfo.processInfo.systemUptime
                        self.report.event("stop_from_real_touch")
                        await model.stop(expectedRunID: runID)
                        self.report.value.stopReturnedUptime = ProcessInfo.processInfo.systemUptime
                        self.report.event("touch_stop_returned")
                    }
                }
                guard touch === inputTouch else { continue }
                if report.value.touchReceipts.count < 128 {
                    report.value.touchReceipts.append(.init(phase: phase, uptime: touch.timestamp,
                        receivedUptime: ProcessInfo.processInfo.systemUptime, x: Double(point.x), y: Double(point.y)))
                }
                if phase == "ended" || phase == "cancelled" {
                    report.value.terminalTouchUptime = touch.timestamp
                    report.event("real_touch_terminal")
                }
            }
        }

        func run(model: AppModel) async {
            guard !started else { return }; started = true
            report.event("preflight")
            var cancellation: Task<Void, Never>?
            defer { cancellation?.cancel() }
            do {
                if let configurationFailure { throw Failure(rawValue: configurationFailure) ?? .invalidArguments }
                guard let plan else { throw Failure.invalidArguments }
                report.value.backend = plan.backend.rawValue
                report.value.acceptanceCase = plan.kind.rawValue
                report.value.plannedSeconds = plan.kind == .background ? plan.seconds : nil
                report.value.sampleIntervalSeconds = plan.kind == .background ? plan.interval : nil
                report.value.cancelAfterSeconds = plan.cancelAfter
                report.value.sampleGapLimitSeconds = plan.kind == .background ? plan.sampleGapLimit : nil
                #if targetEnvironment(simulator)
                throw Failure.physicalDeviceRequired
                #else
                guard model.scope == .control else { throw Failure.permissionDisabled }
                guard try await model.deviceClient.hasPairingIdentity() else { throw Failure.identityRequired }
                if !model.localTunnel.isConnected, plan.resumeTunnel { try await model.localTunnel.resumeExistingForDiagnostics() }
                guard model.localTunnel.isConnected else { throw Failure.tunnelRequired }
                report.event("connecting")
                await model.connectDevice()
                guard model.isDeviceReady, model.activeDeviceConnectionMethod == .localVPN,
                      model.activeDeviceControlBackend == plan.backend else { throw Failure.connectionFailed }
                report.value.connected = true
                if let after = plan.cancelAfter {
                    cancellation = Task { @MainActor [weak model, report] in
                        guard let model else { return }
                        while model.activeRun == nil {
                            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                        }
                        guard let runID = model.activeRun?.id else { return }
                        do { try await Task.sleep(for: .seconds(after)) } catch { return }
                        report.event("scheduled_stop")
                        await model.stop(expectedRunID: runID)
                    }
                }
                model.newConversation()
                model.draft = DebugNetworkRunAcceptance.prompt
                report.event("run_requested")
                await model.sendMessage()
                cancellation?.cancel()
                if plan.kind == .inflightStop {
                    await touchStop?.value
                    let terminalDeadline = (report.value.inputCommandStartedUptime ?? ProcessInfo.processInfo.systemUptime) + 4
                    while report.value.firstTouchDownUptime != nil, report.value.terminalTouchUptime == nil,
                          ProcessInfo.processInfo.systemUptime < terminalDeadline {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    inputRunID = nil; inputTouch = nil
                }
                guard let record = model.runs.first, record.model == "debug-script-zero-model", record.scope == .control else {
                    throw Failure.wrongScope
                }
                report.value.runID = record.id
                report.value.runState = record.state.rawValue
                report.value.stopCause = record.stopCause
                report.value.hostCleanupFailed = record.cleanupFailure != nil
                report.value.observationFailures = record.events.filter { $0.kind == "observation.failed" }.map(\.summary)
                report.value.hostFinishedAt = record.endedAt
                report.value.hostOwnerReleased = model.deviceSession.owner == nil && !model.isRunning
                report.value.state = record.state == .completed && record.cleanupFailure == nil ? "passed" :
                    (record.state == .interrupted && record.cleanupFailure == nil ? "cancelled" : "failed")
                if report.value.failure == Failure.backgroundGapExceeded.rawValue
                    || report.value.failure == Failure.backgroundLeaseInactive.rawValue { report.value.state = "failed" }
                if plan.kind == .inflightStop {
                    let down = report.value.firstTouchDownUptime, stop = report.value.stopRequestedUptime
                    let terminal = report.value.terminalTouchUptime, returned = report.value.inputCommandFinishedUptime
                    let hit: Bool
                    if let down, let stop, let terminal, let returned, let requested = report.value.inputCommandStartedUptime {
                        hit = requested <= down && down < stop && stop < terminal && stop < returned
                            && report.value.swipeAttemptCount == 1 && report.value.inflightToolOutcome == "unknown"
                    }
                    else { hit = false }
                    report.value.inflightHit = hit
                    report.value.state = hit && record.state == .outcomeUnknown && record.cleanupFailure == nil ? "passed" : "failed"
                    if report.value.state == "failed", report.value.failure == nil { report.value.failure = Failure.inflightStopMissed.rawValue }
                }
                #endif
            } catch {
                report.value.state = "failed"
                report.value.failure = (error as? Failure)?.rawValue ?? String(describing: type(of: error))
            }
            report.event("cleanup")
            touchStop?.cancel(); inputRunID = nil; inputTouch = nil
            // This typed session operation awaits the actual backend receipt;
            // cached not-ready status is never promoted to release confirmation.
            do {
                report.value.cleanupConfirmed = try await model.deviceSession.releaseConnection(owner: model.deviceSession.owner)
            } catch { report.value.cleanupConfirmed = false }
            report.value.engineClosed = await store.isUnowned
            report.value.hostOwnerReleased = !model.deviceSession.isBusy && !model.isRunning
            if let credentials, let account { try? credentials.delete(account) }
            if report.value.cleanupConfirmed && report.value.engineClosed && report.value.hostOwnerReleased {
                report.event("finished")
            } else {
                report.value.state = "failed"
                report.value.failure = Failure.cleanupUnconfirmed.rawValue
                report.event("cleanupIncomplete")
            }
        }
    }

    struct Event: Encodable, Sendable { let phase: String; let time: Date; let uptime: TimeInterval }
    struct TouchReceipt: Encodable, Sendable {
        let phase: String; let uptime: TimeInterval; let receivedUptime: TimeInterval; let x: Double; let y: Double
    }
    struct Sample: Encodable, Sendable {
        let time: Date
        let duration: Double
        let background: Bool
        let uptime: TimeInterval
        let gapSeconds: Double
        let isExecuting: Bool
    }
    struct Metadata: Encodable, Sendable {
        let version = 1
        let scripted = true
        let realAI = false
        let realPiRuntime = false
        let modelRequests = 0
        let noModelRequests = true
        let privateAcceptanceStorage = true
        var sessionID: UUID
        var phase = "created"
        var state = "running"
        var backend: String?
        var acceptanceCase: String?
        var plannedSeconds: Double?
        var sampleIntervalSeconds: Double?
        var cancelAfterSeconds: Double?
        var sampleGapLimitSeconds: Double?
        var connected = false
        var runID: UUID?
        var runState: String?
        var stopCause: StopCause?
        var failure: String?
        var hostFinishedAt: Date?
        var hostCleanupFailed = false
        var hostOwnerReleased = false
        var engineClosed = false
        var cleanupConfirmed = false
        var backgroundLaunched = false
        var backgroundExpired = false
        var systemActivityUpdated: Bool?
        var notificationRequested = false
        var notificationsEnabled: Bool?
        var observedToolCalls = 0
        var observationFailures: [String] = []
        var returnedToApp: Bool?
        var elapsedSeconds: Double?
        var backgroundStartedUptime: TimeInterval?
        var backgroundElapsedSeconds: Double?
        var maxSampleGapSeconds: Double?
        var inputArmedUptime: TimeInterval?
        var inputStartPoints: [Double]?
        var inputEndPoints: [Double]?
        var inputCommandStartedUptime: TimeInterval?
        var inputCommandFinishedUptime: TimeInterval?
        var firstTouchDownUptime: TimeInterval?
        var terminalTouchUptime: TimeInterval?
        var stopRequestedUptime: TimeInterval?
        var stopReturnedUptime: TimeInterval?
        var swipeAttemptCount = 0
        var swipeDurationSeconds: Double?
        var inflightToolOutcome: String?
        var inflightHit: Bool?
        var touchReceipts: [TouchReceipt] = []
        var samples: [Sample] = []
        var events: [Event] = []
    }

    @MainActor final class Report {
        let id: UUID
        let directory: URL
        var value: Metadata
        init() {
            let id = UUID()
            self.id = id
            directory = URL.cachesDirectory.appendingPathComponent("EiscueNetworkRunAcceptance/\(id.uuidString)", isDirectory: true)
            value = Metadata(sessionID: id)
        }
        func event(_ phase: String) {
            value.phase = phase
            value.events.append(Event(phase: phase, time: Date(), uptime: ProcessInfo.processInfo.systemUptime))
            save()
        }
        func save() {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(value)
                // The only Documents output contains this allowlisted metadata.
                let destination = URL.documentsDirectory.appendingPathComponent("EiscueNetworkRunAcceptance.json")
                try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch { /* A missing finished report must never be treated as successful cleanup. */ }
        }
        func inputReturned(outcome: String) {
            value.inputCommandFinishedUptime = ProcessInfo.processInfo.systemUptime
            value.inflightToolOutcome = outcome
            event("inflight_swipe_returned")
        }
    }

    @MainActor private final class Background: RunBackgroundExecuting {
        let report: Report
        init(report: Report) { self.report = report }
        var isExecuting: Bool { BackgroundExecution.shared.isExecuting }
        func register() throws { try BackgroundExecution.shared.register() }
        func begin(taskID: UUID, title: String, subtitle: String, totalUnitCount: Int64,
                   onExpiration: @escaping @Sendable () -> Void) async throws {
            report.value.runID = taskID; report.event("background_requested")
            try await BackgroundExecution.shared.begin(taskID: taskID, title: title, subtitle: subtitle, totalUnitCount: totalUnitCount,
                onExpiration: { [report] in
                    Task { @MainActor in report.value.backgroundExpired = true; report.event("background_expired") }
                    onExpiration()
                })
            report.value.backgroundLaunched = true; report.event("background_launched")
        }
        func update(taskID: UUID, completedUnitCount: Int64, totalUnitCount: Int64, title: String?, subtitle: String?) -> Bool {
            BackgroundExecution.shared.update(taskID: taskID, completedUnitCount: completedUnitCount,
                totalUnitCount: totalUnitCount, title: title, subtitle: subtitle)
        }
        func end(taskID: UUID, success: Bool) -> Bool {
            let updated = BackgroundExecution.shared.end(taskID: taskID, success: success)
            report.value.systemActivityUpdated = updated; report.event("background_ended")
            return updated
        }
    }

    @MainActor private final class Notifications: RunNotifying {
        let report: Report
        let base = TaskNotificationManager(preferences: .standard)
        init(report: Report) { self.report = report }
        var isEnabled: Bool { base.isEnabled }
        var isRequestingAuthorization: Bool { base.isRequestingAuthorization }
        var authorizationDescription: String { base.authorizationDescription }
        var lastError: String? { base.lastError }
        func refreshAuthorization() async { await base.refreshAuthorization() }
        func setEnabled(_ enabled: Bool) async { await base.setEnabled(enabled) }
        func notify(runID: UUID, state: RunState, systemActivityUpdated: Bool) async {
            report.value.notificationRequested = true; report.value.notificationsEnabled = base.isEnabled
            report.event("notification_checked")
            await base.notify(runID: runID, state: state, systemActivityUpdated: systemActivityUpdated)
        }
    }
}

/// The existing Owned view is only a private visual target here. Its separate
/// harness is not enabled, and this recognizer never prevents normal input.
struct DebugNetworkRunAcceptanceTargetView: View {
    var body: some View { OwnedDeviceCheckView().background(NetworkRunTouchProbe()) }
}

private struct NetworkRunTouchProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView(); view.isUserInteractionEnabled = false; return view
    }
    func updateUIView(_ uiView: ProbeView, context: Context) {}
    final class ProbeView: UIView {
        private let observer = TouchObserver()
        private weak var observedWindow: UIWindow?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            observedWindow?.removeGestureRecognizer(observer)
            observedWindow = window
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
            window?.addGestureRecognizer(observer)
        }
    }
    final class TouchObserver: UIGestureRecognizer {
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            DebugNetworkRunAcceptance.receive(touches, phase: "began", window: view as? UIWindow)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            DebugNetworkRunAcceptance.receive(touches, phase: "moved", window: view as? UIWindow)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            DebugNetworkRunAcceptance.receive(touches, phase: "ended", window: view as? UIWindow)
            state = .failed
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            DebugNetworkRunAcceptance.receive(touches, phase: "cancelled", window: view as? UIWindow)
            state = .failed
        }
    }
}

/// Durable admission metadata, with tool images retained only in process memory.
/// Resume is intentionally unsupported: a crashed diagnostic is never replayed.
private actor ScriptStore {
    private struct Admission: Codable { var accepted: Set<UUID> = []; var pending: UUID? }
    private let directory: URL
    private var admissions: [UUID: Admission] = [:]
    private var owners: Set<UUID> = []
    private var results: [UUID: [String: AgentToolCompletion]] = [:]
    init(directory: URL) { self.directory = directory }
    var isUnowned: Bool { owners.isEmpty }
    func admit(_ request: AgentRequest) throws -> Bool {
        guard request.mode == .message else { throw AgentError.nothingToResume }
        guard !owners.contains(request.conversationID) else { throw AgentError.busy }
        var admission = try load(request.conversationID)
        guard admission.pending == nil else { throw AgentError.interruptedRun }
        if admission.accepted.contains(request.requestID) { return false }
        admission.accepted.insert(request.requestID); admission.pending = request.requestID
        try save(admission, id: request.conversationID)
        owners.insert(request.conversationID)
        return true
    }
    func record(_ completion: AgentToolCompletion, requestID: UUID) { results[requestID, default: [:]][completion.call.id] = completion }
    func settle(_ id: UUID) throws {
        var admission = try load(id); admission.pending = nil
        try save(admission, id: id); owners.remove(id)
    }
    func recovery(_ id: UUID) throws -> AgentRecovery {
        let admission = try load(id)
        return AgentRecovery(messages: [], hasInterruptedRun: admission.pending != nil, acceptedRequestIDs: admission.accepted)
    }
    func result(requestID: UUID, toolCallID: String) -> AgentToolCompletion? { results[requestID]?[toolCallID] }
    func remove(_ id: UUID) throws {
        guard !owners.contains(id) else { throw AgentError.busy }
        if FileManager.default.fileExists(atPath: file(id).path) { try FileManager.default.removeItem(at: file(id)) }
        admissions[id] = nil
    }
    private func load(_ id: UUID) throws -> Admission {
        if let value = admissions[id] { return value }
        let value = FileManager.default.fileExists(atPath: file(id).path) ? try JSONDecoder().decode(Admission.self, from: Data(contentsOf: file(id))) : Admission()
        admissions[id] = value; return value
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func save(_ value: Admission, id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try JSONEncoder().encode(value).write(to: file(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        admissions[id] = value
    }
}

private actor ScriptEngine: AgentEngine {
    let plan: DebugNetworkRunAcceptance.Plan?
    let tools: [AgentTool]
    let store: ScriptStore
    let report: DebugNetworkRunAcceptance.Report
    var task: Task<Void, Never>?
    var conversationID: UUID?
    var cleanupFailed = false
    var availability: AgentAvailability { .ready }
    init(plan: DebugNetworkRunAcceptance.Plan?, tools: [AgentTool], store: ScriptStore, report: DebugNetworkRunAcceptance.Report) {
        self.plan = plan; self.tools = tools; self.store = store; self.report = report
    }
    func run(request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard task == nil else { throw AgentError.busy }
        guard request.prompt == DebugNetworkRunAcceptance.prompt, request.history.isEmpty, request.attachments.isEmpty,
              let plan else { throw DebugNetworkRunAcceptance.Failure.unexpectedRequest }
        let admitted = try await store.admit(request)
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        continuation.yield(.requestAccepted(request.requestID))
        guard admitted else { continuation.yield(.finished(.completed)); continuation.finish(); return stream }
        conversationID = request.conversationID
        task = Task { await self.execute(request: request, plan: plan, continuation: continuation) }
        return stream
    }
    private func execute(request: AgentRequest, plan: DebugNetworkRunAcceptance.Plan,
                         continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async {
        let clock = ContinuousClock(), start = ContinuousClock.now
        var consumed = 0
        var terminalError: (any Error)?
        var backgroundStarted: ContinuousClock.Instant?
        var lastSampleAt: ContinuousClock.Instant?
        var maximumGap = 0.0
        func seconds(_ duration: Duration) -> Double {
            let value = duration.components
            return Double(value.seconds) + Double(value.attoseconds) / 1e18
        }
        do {
            let observation = try await call(.screenshot, arguments: [:], request: request, consumed: &consumed, continuation: continuation)
            let id = try frameID(in: observation)
            if plan.kind == .appReturn {
                guard let ownBundleID = await MainActor.run(body: { Bundle.main.bundleIdentifier }) else {
                    throw DebugNetworkRunAcceptance.Failure.invalidArguments
                }
                await report.event("app_return_calculator_requested")
                let calculator = try await call(.launchApplication,
                    arguments: ["frameId": .string(id.uuidString), "bundleId": .string("com.apple.calculator")],
                    request: request, consumed: &consumed, continuation: continuation)
                let calculatorFrame = try frameID(in: calculator)
                await report.event("app_return_calculator_postcapture")
                let home = try await call(.home, arguments: ["frameId": .string(calculatorFrame.uuidString)],
                    request: request, consumed: &consumed, continuation: continuation)
                let homeFrame = try frameID(in: home)
                await report.event("app_return_home_postcapture")
                let returned = try await call(.launchApplication,
                    arguments: ["frameId": .string(homeFrame.uuidString), "bundleId": .string(ownBundleID)],
                    request: request, consumed: &consumed, continuation: continuation)
                _ = try frameID(in: returned)
                await report.event("app_return_eiscue_postcapture")
                let returnDeadline = clock.now.advanced(by: .seconds(5))
                while await MainActor.run(body: { UIApplication.shared.applicationState != .active }) {
                    guard clock.now < returnDeadline else { throw DebugNetworkRunAcceptance.Failure.didNotReturnToApp }
                    try await Task.sleep(for: .milliseconds(50))
                }
                await MainActor.run { report.value.returnedToApp = true; report.event("app_return_foreground_confirmed") }
            } else if plan.kind == .inflightStop {
                func dimension(_ name: String) -> Int? {
                    guard let range = observation.text.range(of: name + "=") else { return nil }
                    return Int(observation.text[range.upperBound...].prefix(while: \.isNumber))
                }
                guard let width = dimension("width"), let height = dimension("height") else {
                    throw DebugNetworkRunAcceptance.Failure.invalidFrame
                }
                let points = try await DebugNetworkRunAcceptance.armInput(width: width, height: height)
                await MainActor.run {
                    report.value.swipeAttemptCount += 1
                    report.value.swipeDurationSeconds = 2
                    report.value.inputCommandStartedUptime = ProcessInfo.processInfo.systemUptime
                    report.event("inflight_swipe_requested")
                }
                do {
                    _ = try await call(.swipe, arguments: ["frameId": .string(id.uuidString),
                        "fromX": .number(points.fromX), "fromY": .number(points.fromY),
                        "toX": .number(points.toX), "toY": .number(points.toY), "duration": .number(2)],
                        request: request, consumed: &consumed, continuation: continuation)
                    await report.inputReturned(outcome: "succeeded")
                } catch {
                    let outcome = (error as? AgentToolError) == .outcomeUnknown ? "unknown" : (error is CancellationError ? "interrupted" : "failed")
                    await report.inputReturned(outcome: outcome)
                    throw error
                }
                throw DebugNetworkRunAcceptance.Failure.inflightStopMissed
            } else {
                _ = try await call(.home, arguments: ["frameId": .string(id.uuidString)], request: request, consumed: &consumed, continuation: continuation)
                let homeDeadline = clock.now.advanced(by: .seconds(5))
                while await MainActor.run(body: { UIApplication.shared.applicationState != .background }) {
                    guard clock.now < homeDeadline else { throw DebugNetworkRunAcceptance.Failure.didNotBackground }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let backgroundStart = clock.now
                backgroundStarted = backgroundStart; lastSampleAt = backgroundStart
                let deadline = backgroundStart.advanced(by: .seconds(plan.seconds))
                await MainActor.run {
                    report.value.backgroundStartedUptime = ProcessInfo.processInfo.systemUptime
                    report.value.backgroundElapsedSeconds = 0
                    report.value.maxSampleGapSeconds = 0
                    report.event("sampling_background")
                }
                repeat {
                    try await Task.sleep(until: min(deadline, clock.now.advanced(by: .seconds(plan.interval))), clock: .continuous)
                    try Task.checkCancellation()
                    let awakeGap = seconds((lastSampleAt ?? backgroundStart).duration(to: clock.now))
                    maximumGap = max(maximumGap, awakeGap)
                    guard awakeGap <= plan.sampleGapLimit else { throw DebugNetworkRunAcceptance.Failure.backgroundGapExceeded }
                    let before = await MainActor.run {
                        (UIApplication.shared.applicationState == .background, BackgroundExecution.shared.isExecuting, report.value.backgroundExpired)
                    }
                    guard before.0 else { throw DebugNetworkRunAcceptance.Failure.didNotBackground }
                    guard before.1 && !before.2 else { throw DebugNetworkRunAcceptance.Failure.backgroundLeaseInactive }
                    let sampleStart = clock.now
                    _ = try await call(.screenshot, arguments: [:], request: request, consumed: &consumed, continuation: continuation)
                    let sampleFinished = clock.now
                    let duration = seconds(sampleStart.duration(to: sampleFinished))
                    let gap = seconds((lastSampleAt ?? backgroundStart).duration(to: sampleFinished))
                    lastSampleAt = sampleFinished; maximumGap = max(maximumGap, gap)
                    let snapshot = await MainActor.run {
                        (UIApplication.shared.applicationState == .background, BackgroundExecution.shared.isExecuting,
                         report.value.backgroundExpired, ProcessInfo.processInfo.systemUptime)
                    }
                    let elapsed = seconds(backgroundStart.duration(to: sampleFinished)), maxGap = maximumGap
                    await MainActor.run {
                        report.value.samples.append(.init(time: Date(), duration: duration, background: snapshot.0,
                            uptime: snapshot.3, gapSeconds: gap, isExecuting: snapshot.1))
                        report.value.backgroundElapsedSeconds = elapsed
                        report.value.maxSampleGapSeconds = maxGap
                        report.save()
                    }
                    guard snapshot.0 else { throw DebugNetworkRunAcceptance.Failure.didNotBackground }
                    guard snapshot.1 && !snapshot.2 else { throw DebugNetworkRunAcceptance.Failure.backgroundLeaseInactive }
                    guard gap <= plan.sampleGapLimit else { throw DebugNetworkRunAcceptance.Failure.backgroundGapExceeded }
                } while clock.now < deadline
            }
        } catch { terminalError = error }
        if let backgroundStarted {
            let ended = clock.now
            let elapsed = seconds(backgroundStarted.duration(to: ended))
            if let lastSampleAt { maximumGap = max(maximumGap, seconds(lastSampleAt.duration(to: ended))) }
            if maximumGap > plan.sampleGapLimit { terminalError = DebugNetworkRunAcceptance.Failure.backgroundGapExceeded }
            let maxGap = maximumGap
            await MainActor.run {
                report.value.backgroundElapsedSeconds = elapsed
                report.value.maxSampleGapSeconds = maxGap
            }
        }
        if let failure = terminalError as? DebugNetworkRunAcceptance.Failure {
            await MainActor.run { report.value.failure = failure.rawValue }
        }
        do { try await store.settle(request.conversationID) }
        catch { cleanupFailed = true; continuation.yield(.cleanupFailed("Diagnostic admission close failed.")) }
        let duration = start.duration(to: clock.now).components
        await MainActor.run {
            report.value.elapsedSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            report.event("script_closed")
        }
        if cleanupFailed { continuation.finish(throwing: AgentError.cleanupFailed("Diagnostic admission close failed.")) }
        else if let terminalError { continuation.finish(throwing: terminalError) }
        else { continuation.yield(.finished(.completed)); continuation.finish() }
        task = nil; conversationID = nil
    }
    private func frameID(in result: AgentToolResult) throws -> UUID {
        guard let range = result.text.range(of: "frameId="),
              let id = UUID(uuidString: String(result.text[range.upperBound...].prefix(36))) else {
            throw DebugNetworkRunAcceptance.Failure.invalidFrame
        }
        return id
    }
    private func call(_ spec: DeviceToolSpec, arguments: AgentJSONValue, request: AgentRequest, consumed: inout Int,
                      continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws -> AgentToolResult {
        try Task.checkCancellation()
        guard let tool = tools.first(where: { $0.name == spec.rawValue }) else { throw DebugNetworkRunAcceptance.Failure.missingTool }
        guard request.maxToolCalls - consumed >= tool.executionCost else { throw AgentError.toolLimitReached }
        consumed += tool.executionCost
        let call = AgentToolCall(id: UUID().uuidString, name: spec.rawValue, arguments: arguments)
        continuation.yield(.toolStarted(call))
        let result: AgentToolResult
        do { result = try await tool.execute(arguments) }
        catch {
            let outcome: AgentToolOutcome = error is CancellationError ? .interrupted : ((error as? AgentToolError) == .outcomeUnknown ? .unknown : .failed)
            let completion = AgentToolCompletion(call: call, result: .init(content: [], outcome: outcome))
            await store.record(completion, requestID: request.requestID); continuation.yield(.toolFinished(completion))
            throw error
        }
        let completion = AgentToolCompletion(call: call, result: result)
        await store.record(completion, requestID: request.requestID); continuation.yield(.toolFinished(completion))
        await MainActor.run { report.value.observedToolCalls += 1; report.save() }
        guard result.outcome == .succeeded else { throw AgentError.toolExecutionPaused(.verificationUnavailable) }
        return result
    }
    func recover(conversationID: UUID) async throws -> AgentRecovery { try await store.recovery(conversationID) }
    func toolResult(conversationID: UUID, requestID: UUID, toolCallID: String) async throws -> AgentToolCompletion? {
        await store.result(requestID: requestID, toolCallID: toolCallID)
    }
    func cancel() async throws {
        task?.cancel(); await task?.value
        if cleanupFailed { throw AgentError.cleanupFailed("Diagnostic admission close failed.") }
    }
    func cancel(conversationID: UUID) async throws {
        guard self.conversationID == nil || self.conversationID == conversationID else { throw AgentError.busy }
        try await cancel()
    }
    func removeConversation(id: UUID) async throws {
        guard task == nil else { throw AgentError.busy }; try await store.remove(id)
    }
}
#endif
