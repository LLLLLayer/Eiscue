#if DEBUG && !EISCUE_HID_ONLY
import EiscueAgentKit
import EiscueDeviceCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// Explicit, zero-model host/device acceptance. This is a scripted diagnostic,
/// not Pi, visual reasoning, or a replacement production engine.
@MainActor
enum DebugNetworkRunAcceptance {
    private static var installation: Installation?
    @Observable fileprivate final class TargetPresentation { var ready = false }
    private static let targetPresentation = TargetPresentation()
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

    static var usesAcceptanceTarget: Bool { installation?.plan?.usesAcceptanceTarget == true }
    static var waitsForBluetoothSetup: Bool { installation?.plan?.route == .bluetoothBoard && !targetPresentation.ready }
    static func armInput(width: Int, height: Int, gesture: GestureLabel = .moving) throws -> InputCoordinates {
        guard let installation else { throw Failure.invalidArguments }
        return try installation.armInput(width: width, height: height, gesture: gesture)
    }
    static func receive(_ touches: Set<UITouch>, phase: String, window: UIWindow?) {
        installation?.receive(touches, phase: phase, window: window)
    }
    static func inputTargetAppeared() {
        captureCurrentReadiness(phase: "owned_target_appeared")
    }
    static func captureCurrentReadiness(phase: String) {
        guard let installation, let model = installation.model else { return }
        installation.captureReadiness(model: model, phase: phase, force: true)
    }

    struct InputCoordinates: Sendable { let fromX: Double; let fromY: Double; let toX: Double; let toY: Double }
    enum GestureLabel: String, Encodable, Sendable { case stationary, moving }
    static func touchTypeName(_ type: UITouch.TouchType) -> String {
        switch type {
        case .direct: "direct"
        case .indirect: "indirect"
        case .pencil: "pencil"
        case .indirectPointer: "indirectPointer"
        @unknown default: "unknown"
        }
    }

    struct Plan: Sendable {
        enum Kind: String, Sendable { case background, hidBackground, inflightStop, appReturn, foregroundSwipe }
        let kind: Kind
        let route: DeviceConnectionMethod
        let backend: DeviceControlBackend?
        let inputRoute: BluetoothBoardInputRoute?
        let seconds: Double
        let interval: Double
        let cancelAfter: Double?
        let resumeTunnel: Bool
        let contactComparison: Bool
        var sampleGapLimit: Double { interval + 5 }
        var requiresLocalTunnel: Bool { route == .localVPN }
        var samplesBackground: Bool { kind == .background || kind == .hidBackground }
        var backgroundWaitSeconds: Double { kind == .hidBackground ? 60 : 5 }
        var usesInputTarget: Bool { kind == .inflightStop || kind == .foregroundSwipe }
        var usesAcceptanceTarget: Bool { usesInputTarget || kind == .hidBackground }
        var expectedSwipeCount: Int { contactComparison ? 2 : 1 }
        var maxToolCalls: Int { kind == .foregroundSwipe ? (contactComparison ? 5 : 3) : (kind == .appReturn ? 7 : 70) }
        var requiredTools: [DeviceToolSpec] {
            switch kind {
            case .foregroundSwipe, .inflightStop: [.screenshot, .swipe]
            case .background: [.screenshot, .home]
            case .hidBackground: [.screenshot]
            case .appReturn: [.screenshot, .launchApplication, .home]
            }
        }
        func firstMissingTool(in tools: [AgentTool]) -> DeviceToolSpec? {
            let names = Set(tools.map(\.name))
            return requiredTools.first { !names.contains($0.rawValue) }
        }
        func validateBluetoothSetup(_ status: DeviceStatus) throws {
            guard route == .bluetoothBoard else { return }
            if kind == .hidBackground {
                // Observation only, after the real shared-screen tap/text
                // calibration. It neither requires nor exercises swipe.
                guard case .ready(let capabilities) = status,
                      capabilities.isSuperset(of: [.screenshot, .tap, .textInput]) else {
                    throw Failure.bluetoothCalibrationRequired
                }
                return
            }
            // Input acceptance needs an observed drag before submission.
            guard case .ready(let capabilities) = status, capabilities.contains(.swipe) else {
                throw Failure.bluetoothSwipeCheckRequired
            }
        }

        init(arguments: [String]) throws {
            func argument(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            guard !arguments.contains("--ui-testing"), !arguments.contains("--owned-device-check"),
                  !arguments.contains("--ble-device-check") else { throw Failure.invalidArguments }
            let routeName = argument("--network-run-route") ?? DeviceConnectionMethod.localVPN.rawValue
            guard !arguments.contains("--network-run-route") || argument("--network-run-route") != nil,
                  let route = DeviceConnectionMethod(rawValue: routeName),
                  route == .localVPN || route == .bluetoothBoard || route == .usbBoard else {
                throw Failure.invalidArguments
            }
            let backend = argument("--network-run-backend").flatMap(DeviceControlBackend.init(rawValue:))
            guard route == .bluetoothBoard ? !arguments.contains("--network-run-backend") : (backend == .coreDevice || backend == .xcTest) else {
                throw Failure.invalidArguments
            }
            let inputRouteName = argument("--network-run-input-route")
            let inputRoute = inputRouteName.flatMap(BluetoothBoardInputRoute.init(rawValue:))
            guard !arguments.contains("--network-run-input-route") || (route == .bluetoothBoard && inputRoute != nil) else {
                throw Failure.invalidArguments
            }
            let kindName = argument("--network-run-case") ?? "background"
            if arguments.contains("--network-run-case"), argument("--network-run-case") == nil { throw Failure.invalidArguments }
            guard let kind = Kind(rawValue: kindName) else { throw Failure.invalidArguments }
            let contactComparison = arguments.contains("--network-run-contact-comparison")
            guard !contactComparison || (route == .bluetoothBoard && kind == .foregroundSwipe) else { throw Failure.invalidArguments }
            // Home and bundle-ID launch are never available on the HID route.
            guard route != .bluetoothBoard || kind == .foregroundSwipe || kind == .inflightStop || kind == .hidBackground,
                  kind != .hidBackground || route == .bluetoothBoard,
                  route == .localVPN || !arguments.contains("--resume-existing-local-tunnel") else { throw Failure.invalidArguments }
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
            self.route = route
            self.inputRoute = route == .bluetoothBoard ? (inputRoute ?? .bluetooth) : nil
            self.backend = backend; seconds = minutes * 60; self.interval = interval; cancelAfter = cancel
            resumeTunnel = arguments.contains("--resume-existing-local-tunnel")
            self.contactComparison = contactComparison
        }
    }

    enum Failure: String, Error {
        case invalidArguments, physicalDeviceRequired, permissionDisabled, identityRequired
        case tunnelRequired, connectionFailed, wrongScope, missingTool, invalidFrame, didNotBackground
        case unexpectedRequest, budget, persistence, cleanupUnconfirmed
        case backgroundGapExceeded, backgroundLeaseInactive
        case inputTargetUnavailable, inflightStopMissed, didNotReturnToApp
        case bluetoothSetupTimedOut, bluetoothCalibrationRequired, bluetoothSwipeCheckRequired, postActionObservationMissing, swipeDidNotMove, retentionFailed
    }

    /// The external actor only changes application state. This wait cannot
    /// manufacture a device Home capability or grant background execution.
    static func waitForBackground(timeoutSeconds: Double,
        applicationState: () -> UIApplication.State = { UIApplication.shared.applicationState }) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while applicationState() != .background {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Failure.didNotBackground }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
    }

    struct SwipeEvidence: Sendable {
        let initialFrameID: UUID
        let postActionFrameID: UUID
        let postActionImageBytes: Int
        let rowDeltaPoints: Double
    }
    nonisolated static func frameID(in result: AgentToolResult) throws -> UUID {
        guard let range = result.text.range(of: "frameId="),
              let id = UUID(uuidString: String(result.text[range.upperBound...].prefix(36))) else { throw Failure.invalidFrame }
        return id
    }
    nonisolated static func swipeEvidence(initialFrameID: UUID, result: AgentToolResult,
                                         startRowY: Double, endRowY: Double) throws -> SwipeEvidence {
        let newID = try postActionFrameID(initialFrameID: initialFrameID, result: result)
        let bytes = result.content.reduce(0) { count, content in
            if case .image(let data, _) = content { count + data.count } else { count }
        }
        let delta = abs(endRowY - startRowY)
        guard startRowY.isFinite, endRowY.isFinite, delta > 30 else { throw Failure.swipeDidNotMove }
        return SwipeEvidence(initialFrameID: initialFrameID, postActionFrameID: newID, postActionImageBytes: bytes, rowDeltaPoints: delta)
    }
    nonisolated static func postActionFrameID(initialFrameID: UUID, result: AgentToolResult) throws -> UUID {
        let next = try frameID(in: result)
        let hasImage = result.content.contains { if case .image(let data, _) = $0 { !data.isEmpty } else { false } }
        guard result.outcome == .succeeded, next != initialFrameID, hasImage else { throw Failure.postActionObservationMissing }
        return next
    }
    nonisolated static func readinessReasonCode(_ reason: String) -> String {
        let known: [(String, DeviceControlError)] = [
            ("staleFrame", .staleFrame), ("busy", .busy), ("connectionLost", .connectionLost),
            ("notConnected", .notConnected), ("serviceUnavailable", .serviceUnavailable(.input))
        ]
        return known.first { $0.1.localizedDescription == reason }?.0 ?? "unclassified"
    }
    struct StabilityGate<Value: Equatable> {
        private var previous: Value?
        private var stableSince: TimeInterval?
        mutating func update(eligible: Bool, value: Value, uptime: TimeInterval) -> Bool {
            guard eligible, uptime.isFinite else { previous = nil; stableSince = nil; return false }
            if previous != value || stableSince == nil { previous = value; stableSince = uptime }
            return uptime - (stableSince ?? uptime) >= 1
        }
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
        var inputGesture: GestureLabel = .moving
        var contactOrdinals: [ObjectIdentifier: Int] = [:]
        var nextContactOrdinal = 1
        var touchStop: Task<Void, Never>?
        var setupScreenSessionID: UUID?
        var setupScreenGeometry: [Int]?
        var setupOperationID: UUID?

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
            preferences.set((plan?.route ?? .localVPN).rawValue, forKey: "deviceConnectionMethod")
            if let inputRoute = plan?.inputRoute { preferences.set(inputRoute.rawValue, forKey: "bluetoothInputRoute") }
            preferences.set((plan?.backend ?? .coreDevice).rawValue, forKey: "deviceControlBackend")
            preferences.set(UserDefaults.standard.object(forKey: "allowsDeviceControl") as? Bool ?? true, forKey: "allowsDeviceControl")
            preferences.set(false, forKey: "disconnectAfterTask")
            var settings = ModelSettings()
            settings.baseURL = "https://network-acceptance.invalid"
            settings.model = "debug-script-zero-model"
            settings.maxToolCalls = plan?.maxToolCalls ?? 70
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
                agentFactory: { [weak self] _, _, tools in
                    // Deliberately ignores the model configuration. No branch
                    // constructs the network-backed AgentClient initializer.
                    if let run = self?.model?.activeRun {
                        report.value.runID = run.id
                        report.value.runScope = run.scope.rawValue
                        report.value.registeredToolNames = tools.map(\.name).sorted()
                        report.event("run_tools_registered")
                    }
                    return AgentClient(engine: ScriptEngine(plan: plan, tools: tools, store: store, report: report))
                })
            self.model = model
            return model
        }

        func armInput(width: Int, height: Int, gesture: GestureLabel) throws -> InputCoordinates {
            let proof = OwnedDeviceCheckState.shared
            guard plan?.usesInputTarget == true, inputTargetSnapshot() != nil, let model, let runID = model.activeRun?.id,
                  report.value.runID == runID, UIApplication.shared.applicationState == .active,
                  let window = proof.window, let scene = window.windowScene,
                  scene.activationState == .foregroundActive, scene.effectiveGeometry.interfaceOrientation == .portrait,
                  proof.orientation == .portrait, proof.scroll.height > 60, proof.scroll.width > 0,
                  window.bounds.contains(proof.scroll), width > 1, height > width else { throw Failure.inputTargetUnavailable }
            let bounds = scene.screen.bounds
            guard bounds.width > 0, bounds.height > 0,
                  abs(Double(width) / Double(height) - Double(bounds.width / bounds.height)) < 0.01 else { throw Failure.inputTargetUnavailable }
            let start = CGPoint(x: proof.scroll.midX, y: proof.scroll.maxY - 30)
            let end = gesture == .stationary ? start : CGPoint(x: proof.scroll.midX, y: proof.scroll.minY + 30)
            let screenStart = window.convert(start, to: scene.screen.coordinateSpace)
            let screenEnd = window.convert(end, to: scene.screen.coordinateSpace)
            inputRunID = runID; inputStart = start; inputTouch = nil; inputGesture = gesture
            report.value.firstTouchDownUptime = nil; report.value.terminalTouchUptime = nil
            report.value.inputCommandStartedUptime = nil; report.value.inputCommandFinishedUptime = nil
            report.value.inputArmedUptime = ProcessInfo.processInfo.systemUptime
            report.value.inputStartPoints = [Double(start.x), Double(start.y)]
            report.value.inputEndPoints = [Double(end.x), Double(end.y)]
            report.value.swipeStartRowYPoints = Double(proof.rowY)
            report.event(plan?.kind == .inflightStop ? "inflight_armed" : (gesture == .stationary ? "stationary_contact_armed" : "foreground_swipe_armed"))
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
                let key = ObjectIdentifier(touch)
                if phase == "began" || contactOrdinals[key] == nil { contactOrdinals[key] = nextContactOrdinal; nextContactOrdinal += 1 }
                if report.value.touchReceipts.count < 128 {
                    report.value.touchReceipts.append(.init(gesture: inputGesture, contactID: contactOrdinals[key]!,
                        type: touch.type.rawValue, typeName: DebugNetworkRunAcceptance.touchTypeName(touch.type), phase: phase, uptime: touch.timestamp,
                        receivedUptime: ProcessInfo.processInfo.systemUptime, x: Double(point.x), y: Double(point.y)))
                }
                defer { if phase == "ended" || phase == "cancelled" { contactOrdinals[key] = nil } }
                if phase == "began", inputTouch == nil, report.value.firstTouchDownUptime == nil,
                   let requested = report.value.inputCommandStartedUptime, model.activeRun?.id == runID,
                   touch.timestamp >= max(armed, requested), abs(point.x - start.x) <= 16, abs(point.y - start.y) <= 16 {
                    inputTouch = touch
                    report.value.firstTouchDownUptime = touch.timestamp
                    report.event("real_touch_began")
                    if plan?.kind == .inflightStop { touchStop = Task { @MainActor [weak self, weak model] in
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                        guard let self, let model, self.inputRunID == runID,
                              model.activeRun?.id == runID, self.report.value.terminalTouchUptime == nil else { return }
                        self.report.value.stopRequestedUptime = ProcessInfo.processInfo.systemUptime
                        self.report.event("stop_from_real_touch")
                        await model.stop(expectedRunID: runID)
                        self.report.value.stopReturnedUptime = ProcessInfo.processInfo.systemUptime
                        self.report.event("touch_stop_returned")
                    } }
                }
                guard touch === inputTouch else { continue }
                if phase == "ended" || phase == "cancelled" {
                    report.value.terminalTouchUptime = touch.timestamp
                    report.event("real_touch_terminal")
                }
            }
        }

        private struct InputTargetSnapshot: Equatable {
            let window: ObjectIdentifier
            let geometry: [Double]
        }
        private func inputTargetSnapshot() -> InputTargetSnapshot? {
            let proof = OwnedDeviceCheckState.shared
            guard UIApplication.shared.applicationState == .active,
                  let window = proof.window, let scene = window.windowScene,
                  scene.activationState == .foregroundActive, window.rootViewController?.transitionCoordinator == nil,
                  window.rootViewController?.presentedViewController == nil,
                  scene.effectiveGeometry.interfaceOrientation == .portrait, proof.orientation == .portrait,
                  proof.screenBounds == scene.screen.bounds, proof.windowBounds == window.bounds,
                  proof.screenScale == scene.screen.scale, proof.screenScale > 0,
                  !proof.layout.isEmpty, proof.scroll.height > 60, proof.scroll.width > 0,
                  window.bounds.contains(proof.scroll), proof.rowY.isFinite else { return nil }
            let rects = [proof.screenBounds, proof.windowBounds, proof.layout, proof.scroll]
            return InputTargetSnapshot(window: ObjectIdentifier(window),
                geometry: rects.flatMap { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] } + [Double(proof.rowY), Double(proof.screenScale)])
        }
        private func setupPresentationSettled() -> Bool {
            guard UIApplication.shared.applicationState == .active,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
                  let window = scene.windows.first(where: { $0.isKeyWindow }), let root = window.rootViewController,
                  root.presentedViewController == nil, root.transitionCoordinator == nil,
                  !root.isBeingPresented, !root.isBeingDismissed else { return false }
            return true
        }
        private func waitForBluetoothSetupDismissal(model: AppModel) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 600
            var gate = StabilityGate<DeviceSession.Identity>()
            var observingDismissal = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard model.scope == .control else { throw Failure.permissionDisabled }
                await model.bluetoothController.refreshScreenState()
                model.handleBluetoothSessionChange()
                await model.refreshDeviceStatus()
                let ready = bluetoothReady(model), settled = setupPresentationSettled()
                if ready, !observingDismissal {
                    observingDismissal = true
                    report.event("bluetooth_waiting_for_dismissal")
                }
                if observingDismissal { captureReadiness(model: model, phase: "bluetooth_dismissal_wait") }
                // Replacing the setup page while its cover is dismissing can
                // recreate a calibration controller and cancel the valid map.
                // Leave that real UI mounted through dismissal and readiness.
                if gate.update(eligible: ready && !model.deviceSession.isBusy && settled,
                    value: model.deviceSession.identity, uptime: ProcessInfo.processInfo.systemUptime) {
                    captureReadiness(model: model, phase: "bluetooth_dismissal_stable", force: true)
                    try plan?.validateBluetoothSetup(model.deviceStatus)
                    return
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            captureReadiness(model: model, phase: "bluetooth_setup_timed_out", force: true)
            throw Failure.bluetoothSetupTimedOut
        }
        private func waitForInputTarget(model: AppModel, plan: Plan) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            var previous: InputTargetSnapshot?
            var previousIdentity = model.deviceSession.identity
            var stableSince = ProcessInfo.processInfo.systemUptime
            var nextProbe = 0.0
            captureReadiness(model: model, phase: "target_preparation_started", force: true)
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard model.scope == .control else { throw Failure.permissionDisabled }
                if plan.route == .bluetoothBoard {
                    captureReadiness(model: model, phase: "before_screen_refresh")
                    await model.bluetoothController.refreshScreenState()
                    model.handleBluetoothSessionChange()
                    captureReadiness(model: model, phase: "after_screen_refresh")
                    // The setup page's last ready projection can expire or be
                    // invalidated while the owned target replaces that page.
                    // Readiness still comes exclusively from the real route.
                    if !model.deviceSession.isBusy, ProcessInfo.processInfo.systemUptime >= nextProbe {
                        captureReadiness(model: model, phase: "before_probe", force: true)
                        _ = await model.deviceSession.refreshStatus(probe: true, transportConnected: model.isBluetoothConnected)
                        captureReadiness(model: model, phase: "after_probe", force: true)
                        nextProbe = ProcessInfo.processInfo.systemUptime + 1
                    } else { await model.refreshDeviceStatus() }
                }
                let current = inputTargetSnapshot()
                let identity = model.deviceSession.identity
                let ready = model.newRunScope == .control && model.activeDeviceConnectionMethod == plan.route
                    && !model.deviceSession.isBusy && (plan.route != .bluetoothBoard || bluetoothReady(model))
                report.value.scopeBeforeSubmission = model.newRunScope.rawValue
                report.value.readyBeforeSubmission = ready
                if current == nil || current != previous || identity != previousIdentity || !ready {
                    stableSince = ProcessInfo.processInfo.systemUptime; previous = current; previousIdentity = identity
                }
                if current != nil, ProcessInfo.processInfo.systemUptime - stableSince >= 1 {
                    captureReadiness(model: model, phase: "input_target_stable", force: true)
                    report.event("input_target_stable"); return
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            captureReadiness(model: model, phase: "input_target_preparation_failed", force: true)
            report.event("input_target_preparation_failed")
            throw report.value.readyBeforeSubmission == true ? Failure.inputTargetUnavailable : Failure.connectionFailed
        }

        func run(model: AppModel) async {
            guard !started else { return }; started = true
            report.event("preflight")
            var cancellation: Task<Void, Never>?
            defer { cancellation?.cancel() }
            do {
                if let configurationFailure { throw Failure(rawValue: configurationFailure) ?? .invalidArguments }
                guard let plan else { throw Failure.invalidArguments }
                report.value.backend = plan.backend?.rawValue
                report.value.route = plan.route.rawValue
                report.value.inputRoute = plan.inputRoute?.rawValue
                report.value.acceptanceCase = plan.kind.rawValue
                report.value.contactComparison = plan.contactComparison
                report.value.plannedSeconds = plan.samplesBackground ? plan.seconds : nil
                report.value.sampleIntervalSeconds = plan.samplesBackground ? plan.interval : nil
                report.value.cancelAfterSeconds = plan.cancelAfter
                report.value.sampleGapLimitSeconds = plan.samplesBackground ? plan.sampleGapLimit : nil
                #if targetEnvironment(simulator)
                throw Failure.physicalDeviceRequired
                #else
                guard model.scope == .control else { throw Failure.permissionDisabled }
                if plan.route == .bluetoothBoard {
                    // A fresh process has no calibration. Keep the real setup UI
                    // visible until its own user-driven work and lease finish.
                    report.event("awaiting_bluetooth_setup")
                    try await waitForBluetoothSetupDismissal(model: model)
                    captureReadiness(model: model, phase: "bluetooth_setup_ready", force: true)
                    report.event("bluetooth_setup_ready")
                    targetPresentation.ready = true
                } else {
                    guard try await model.deviceClient.hasPairingIdentity() else { throw Failure.identityRequired }
                    if plan.requiresLocalTunnel {
                        if !model.localTunnel.isConnected, plan.resumeTunnel { try await model.localTunnel.resumeExistingForDiagnostics() }
                        guard model.localTunnel.isConnected else { throw Failure.tunnelRequired }
                    }
                    report.event("connecting")
                    await model.connectDevice()
                    guard model.isDeviceReady, model.activeDeviceConnectionMethod == plan.route,
                          model.activeDeviceControlBackend == plan.backend else { throw Failure.connectionFailed }
                }
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
                if plan.usesInputTarget { try await waitForInputTarget(model: model, plan: plan) }
                report.value.scopeBeforeSubmission = model.newRunScope.rawValue
                report.value.readyBeforeSubmission = model.isDeviceReady
                guard model.newRunScope == .control, model.activeDeviceConnectionMethod == plan.route,
                      !model.deviceSession.isBusy else { throw Failure.wrongScope }
                try plan.validateBluetoothSetup(model.deviceStatus)
                model.draft = DebugNetworkRunAcceptance.prompt
                report.value.submissionAttempted = true
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
                guard let record = model.runs.first, record.model == "debug-script-zero-model" else {
                    throw Failure.wrongScope
                }
                report.value.runID = record.id
                report.value.runScope = record.scope.rawValue
                report.value.runState = record.state.rawValue
                report.value.stopCause = record.stopCause
                report.value.hostCleanupFailed = record.cleanupFailure != nil
                report.value.observationFailures = record.events.filter { $0.kind == "observation.failed" }.map(\.summary)
                report.value.hostFinishedAt = record.endedAt
                report.value.hostOwnerReleased = model.deviceSession.owner == nil && !model.isRunning
                report.value.hostEngineClosedBeforeTeardown = await store.isUnowned
                guard record.scope == .control else { throw Failure.wrongScope }
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
                if plan.kind == .foregroundSwipe {
                    report.value.retentionCheckedBeforeTeardown = true
                    report.value.retainedReady = model.isDeviceReady && model.activeDeviceConnectionMethod == plan.route
                    if plan.route == .bluetoothBoard {
                        report.value.retainedBluetoothConnected = model.isBluetoothConnected
                        report.value.retainedScreenSharing = model.isBluetoothScreenShared
                        report.value.retainedCalibration = model.isBluetoothPointerVerified
                    }
                    let retained = plan.route != .bluetoothBoard || bluetoothReady(model)
                    guard record.state == .completed, record.cleanupFailure == nil, report.value.hostOwnerReleased,
                          report.value.hostEngineClosedBeforeTeardown == true, report.value.retainedReady == true, retained,
                          report.value.postActionFrameID != nil, report.value.postActionImageBytes > 0,
                          report.value.swipeAttemptCount == plan.expectedSwipeCount,
                          report.value.observedToolCalls == 1 + plan.expectedSwipeCount,
                          report.value.observationFailures.isEmpty else { throw Failure.retentionFailed }
                    report.value.retentionVerified = true
                    report.value.state = report.value.motionVerified == true ? "passed" : "failed"
                    if report.value.motionVerified != true { report.value.failure = report.value.motionFailure ?? Failure.swipeDidNotMove.rawValue }
                    report.event("retention_before_diagnostic_teardown")
                }
                #endif
            } catch {
                report.value.state = "failed"
                if report.value.failure == nil { report.value.failure = (error as? Failure)?.rawValue ?? String(describing: type(of: error)) }
            }
            captureReadiness(model: model, phase: "before_diagnostic_teardown", force: true)
            report.event("cleanup")
            touchStop?.cancel(); inputRunID = nil; inputTouch = nil
            // This typed session operation awaits the actual backend receipt;
            // cached not-ready status is never promoted to release confirmation.
            var releaseReturned = false
            do {
                report.value.cleanupConfirmed = try await model.deviceSession.releaseConnection(owner: model.deviceSession.owner)
                releaseReturned = true
            } catch { report.value.cleanupConfirmed = false }
            report.value.engineClosed = await store.isUnowned
            report.value.diagnosticOwnerReleased = !model.deviceSession.isBusy && !model.isRunning
            report.value.cleanupLocallyAccepted = releaseReturned
                && DeviceRunCleanup.acceptsRelease(confirmed: report.value.cleanupConfirmed, method: plan?.route ?? .localVPN)
            captureReadiness(model: model, phase: "after_diagnostic_teardown", force: true)
            if let credentials, let account { try? credentials.delete(account) }
            if report.value.cleanupLocallyAccepted && report.value.engineClosed && report.value.diagnosticOwnerReleased {
                report.event("finished")
            } else {
                report.value.state = "failed"
                report.value.failure = Failure.cleanupUnconfirmed.rawValue
                report.event("cleanupIncomplete")
            }
        }
        private func bluetoothReady(_ model: AppModel) -> Bool {
            model.deviceConnectionMethod == .bluetoothBoard && model.activeDeviceConnectionMethod == .bluetoothBoard
                && model.isDeviceReady && model.isBluetoothConnected && model.isBluetoothScreenShared && model.isBluetoothPointerVerified
                && model.bluetoothInputRoute == plan?.inputRoute
                && (model.bluetoothController.outputInfo?.selectedRoute ?? .bluetooth) == plan?.inputRoute
        }
        func captureReadiness(model: AppModel, phase: String, force: Bool = false) {
            guard plan?.route == .bluetoothBoard else { return }
            let controller = model.bluetoothController, session = model.deviceSession, screen = controller.screenState
            var state = ReadinessState()
            switch model.deviceStatus {
            case .ready(let capabilities): state.status = "ready"; state.capabilities = capabilities.map(\.rawValue).sorted()
            case .unavailable(let reason):
                state.statusReasonCode = DebugNetworkRunAcceptance.readinessReasonCode(reason)
            }
            state.permissionScope = model.scope.rawValue; state.newRunScope = model.newRunScope.rawValue
            state.selectedRoute = session.selectedMethod.rawValue; state.activeRoute = session.activeMethod?.rawValue
            state.operationChangedFromSetup = setupOperationID.map { $0 != session.operationID }
            switch session.owner {
            case .setup: state.owner = "setup"
            case .run: state.owner = "run"
            case .dictation: state.owner = "dictation"
            case .repair: state.owner = "repair"
            case nil: state.owner = "none"
            }
            state.transitioning = session.isTransitioning
            state.boardState = String(describing: controller.board.state)
            state.connected = controller.isConnected; state.inputReady = controller.isInputReady
            state.pointerVerified = controller.isPointerVerified; state.calibrating = controller.isCalibrating
            state.hardwareStopped = controller.isHardwareStopLatched
            state.screenPhase = screen?.phase.rawValue ?? "missing"
            state.screenSessionChangedFromSetup = setupScreenSessionID.map { $0 != screen?.sessionID }
            state.screenOrientation = screen?.orientation?.rawValue; state.screenWidth = screen?.width; state.screenHeight = screen?.height
            let geometry = screen.flatMap { value -> [Int]? in
                guard let orientation = value.orientation, let width = value.width, let height = value.height else { return nil }
                return [Int(orientation.rawValue), width, height]
            }
            state.screenGeometryChangedFromSetup = setupScreenGeometry.map { $0 != geometry }
            if phase == "bluetooth_setup_ready" {
                setupScreenSessionID = screen?.sessionID; setupScreenGeometry = geometry; setupOperationID = session.operationID
                state.screenSessionChangedFromSetup = false; state.screenGeometryChangedFromSetup = false; state.operationChangedFromSetup = false
            }
            state.protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
            state.applicationState = UIApplication.shared.applicationState.rawValue
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            let window = scene?.windows.first { $0.isKeyWindow }
            state.modalPresented = window?.rootViewController?.presentedViewController != nil
            state.interfaceOrientation = scene?.effectiveGeometry.interfaceOrientation.rawValue
            state.inputTargetVisible = targetPresentation.ready
            report.value.recordReadiness(phase: phase, state: state, force: force)
            report.save()
        }
    }

    struct Event: Encodable, Sendable { let phase: String; let time: Date; let uptime: TimeInterval }
    struct TouchReceipt: Encodable, Sendable {
        let gesture: GestureLabel; let contactID: Int; let type: Int; let typeName: String
        let phase: String; let uptime: TimeInterval; let receivedUptime: TimeInterval; let x: Double; let y: Double
    }
    struct GestureReturn: Encodable, Sendable {
        let gesture: GestureLabel
        let initialFrameID: UUID
        let postActionFrameID: UUID?
        let postActionImageBytes: Int
        let startPoints: [Double]?
        let endPoints: [Double]?
        let durationSeconds: Double?
        let commandStartedUptime: TimeInterval?
        let commandFinishedUptime: TimeInterval?
        let firstTouchDownUptime: TimeInterval?
        let terminalTouchUptime: TimeInterval?
        let startRowYPoints: Double?
        let endRowYPoints: Double?
        let rowDeltaPoints: Double?
    }
    struct Sample: Encodable, Sendable {
        let time: Date
        let duration: Double
        let background: Bool
        let uptime: TimeInterval
        let gapSeconds: Double
        let isExecuting: Bool
    }
    struct ReadinessState: Encodable, Equatable, Sendable {
        var status = "unavailable"
        var statusReasonCode: String?
        var capabilities: [String] = []
        var permissionScope = "chat"
        var newRunScope = "chat"
        var selectedRoute = "bluetoothBoard"
        var activeRoute: String?
        var operationChangedFromSetup: Bool?
        var owner = "none"
        var transitioning = false
        var boardState = "idle"
        var connected = false
        var inputReady = false
        var pointerVerified = false
        var calibrating = false
        var hardwareStopped = false
        var screenPhase = "missing"
        var screenSessionChangedFromSetup: Bool?
        var screenGeometryChangedFromSetup: Bool?
        var screenOrientation: UInt32?
        var screenWidth: Int?
        var screenHeight: Int?
        var protectedDataAvailable = true
        var applicationState: Int?
        var modalPresented = false
        var interfaceOrientation: Int?
        var inputTargetVisible = false
    }
    struct ReadinessSample: Encodable, Sendable {
        let phase: String
        let uptime: TimeInterval
        let state: ReadinessState
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
        var route: String?
        var inputRoute: String?
        var acceptanceCase: String?
        var contactComparison = false
        var plannedSeconds: Double?
        var sampleIntervalSeconds: Double?
        var cancelAfterSeconds: Double?
        var sampleGapLimitSeconds: Double?
        var connected = false
        var runID: UUID?
        var runScope: String?
        var runState: String?
        var submissionAttempted = false
        var scopeBeforeSubmission: String?
        var readyBeforeSubmission: Bool?
        var registeredToolNames: [String] = []
        var missingToolName: String?
        var stopCause: StopCause?
        var failure: String?
        var hostFinishedAt: Date?
        var hostCleanupFailed = false
        var hostOwnerReleased = false
        var hostEngineClosedBeforeTeardown: Bool?
        var engineClosed = false
        var cleanupConfirmed = false
        var cleanupLocallyAccepted = false
        var diagnosticOwnerReleased = false
        var retentionCheckedBeforeTeardown = false
        var retentionVerified = false
        var retainedReady: Bool?
        var retainedBluetoothConnected: Bool?
        var retainedScreenSharing: Bool?
        var retainedCalibration: Bool?
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
        var swipeStartRowYPoints: Double?
        var swipeEndRowYPoints: Double?
        var swipeRowDeltaPoints: Double?
        var initialFrameID: UUID?
        var postActionFrameID: UUID?
        var postActionImageBytes = 0
        var motionVerified: Bool?
        var motionFailure: String?
        var inflightToolOutcome: String?
        var inflightHit: Bool?
        var touchReceipts: [TouchReceipt] = []
        var gestureReturns: [GestureReturn] = []
        var samples: [Sample] = []
        var readiness: [ReadinessSample] = []
        var events: [Event] = []
        mutating func recordSwipeReturn(initialFrameID: UUID, result: AgentToolResult,
                                        startRowY: Double?, endRowY: Double, gesture: GestureLabel = .moving) {
            self.initialFrameID = initialFrameID
            postActionFrameID = try? DebugNetworkRunAcceptance.frameID(in: result)
            postActionImageBytes = result.content.reduce(0) { count, content in
                if case .image(let data, _) = content { count + data.count } else { count }
            }
            swipeStartRowYPoints = startRowY.flatMap { $0.isFinite ? $0 : nil }
            swipeEndRowYPoints = endRowY.isFinite ? endRowY : nil
            swipeRowDeltaPoints = swipeStartRowYPoints.flatMap { start in
                swipeEndRowYPoints.map { abs($0 - start) }
            }
            let receipt = GestureReturn(gesture: gesture, initialFrameID: initialFrameID,
                postActionFrameID: postActionFrameID, postActionImageBytes: postActionImageBytes,
                startPoints: inputStartPoints, endPoints: inputEndPoints, durationSeconds: swipeDurationSeconds,
                commandStartedUptime: inputCommandStartedUptime, commandFinishedUptime: inputCommandFinishedUptime,
                firstTouchDownUptime: firstTouchDownUptime, terminalTouchUptime: terminalTouchUptime,
                startRowYPoints: swipeStartRowYPoints, endRowYPoints: swipeEndRowYPoints, rowDeltaPoints: swipeRowDeltaPoints)
            if let index = gestureReturns.firstIndex(where: { $0.gesture == gesture }) { gestureReturns[index] = receipt }
            else { gestureReturns.append(receipt) }
        }
        mutating func verifyMovingSwipe(initialFrameID: UUID, result: AgentToolResult,
                                        startRowY: Double, endRowY: Double) throws {
            do {
                _ = try DebugNetworkRunAcceptance.swipeEvidence(initialFrameID: initialFrameID, result: result, startRowY: startRowY, endRowY: endRowY)
                motionVerified = true; motionFailure = nil
            } catch Failure.swipeDidNotMove {
                // Visual failure is separate from tool/runtime completion so
                // normal host input cleanup and default retention are measured.
                motionVerified = false; motionFailure = Failure.swipeDidNotMove.rawValue
            }
        }
        mutating func recordReadiness(phase: String, state: ReadinessState, force: Bool = false,
                                     uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            guard force || readiness.last?.state != state else { return }
            // Keep the initial setup proof and the most recent transitions.
            if readiness.count == 32 { readiness.remove(at: 1) }
            readiness.append(.init(phase: phase, uptime: uptime, state: state))
        }
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
        func inputReturned(outcome: String, inflight: Bool = true, gesture: GestureLabel = .moving) {
            value.inputCommandFinishedUptime = ProcessInfo.processInfo.systemUptime
            if inflight { value.inflightToolOutcome = outcome }
            event(inflight ? "inflight_swipe_returned" : (gesture == .stationary ? "stationary_swipe_returned" : "foreground_swipe_returned"))
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
    var body: some View {
        if DebugNetworkRunAcceptance.waitsForBluetoothSetup { RootView(initialDestination: .device) }
        else { OwnedDeviceCheckView().background(NetworkRunTouchProbe()).onAppear { DebugNetworkRunAcceptance.inputTargetAppeared() } }
    }
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
            let missing = plan.firstMissingTool(in: tools)
            await MainActor.run {
                report.value.registeredToolNames = tools.map(\.name).sorted()
                report.value.missingToolName = missing?.rawValue
            }
            guard missing == nil else { throw DebugNetworkRunAcceptance.Failure.missingTool }
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
            } else if plan.usesInputTarget {
                func dimension(_ name: String, in result: AgentToolResult) -> Int? {
                    guard let range = result.text.range(of: name + "=") else { return nil }
                    return Int(result.text[range.upperBound...].prefix(while: \.isNumber))
                }
                var currentObservation = observation
                var currentFrameID = id
                if plan.contactComparison {
                    guard let width = dimension("width", in: observation), let height = dimension("height", in: observation) else {
                        throw DebugNetworkRunAcceptance.Failure.invalidFrame
                    }
                    let points = try await DebugNetworkRunAcceptance.armInput(width: width, height: height, gesture: .stationary)
                    await MainActor.run {
                        report.value.swipeAttemptCount += 1
                        report.value.swipeDurationSeconds = 0.6
                        report.value.inputCommandStartedUptime = ProcessInfo.processInfo.systemUptime
                        report.event("stationary_swipe_requested")
                    }
                    let stationary: AgentToolResult
                    do {
                        stationary = try await call(.swipe, arguments: ["frameId": .string(id.uuidString),
                            "fromX": .number(points.fromX), "fromY": .number(points.fromY),
                            "toX": .number(points.toX), "toY": .number(points.toY), "duration": .number(0.6)],
                            request: request, consumed: &consumed, continuation: continuation)
                        await report.inputReturned(outcome: "succeeded", inflight: false, gesture: .stationary)
                    } catch {
                        let outcome = (error as? AgentToolError) == .outcomeUnknown ? "unknown" : (error is CancellationError ? "interrupted" : "failed")
                        await report.inputReturned(outcome: outcome, inflight: false, gesture: .stationary)
                        throw error
                    }
                    await MainActor.run {
                        report.value.recordSwipeReturn(initialFrameID: id, result: stationary,
                            startRowY: report.value.swipeStartRowYPoints, endRowY: Double(OwnedDeviceCheckState.shared.rowY), gesture: .stationary)
                        DebugNetworkRunAcceptance.captureCurrentReadiness(phase: "stationary_swipe_postaction_returned")
                        report.event("stationary_swipe_postaction_returned")
                    }
                    // Stationary contact is diagnostic only. The next action
                    // must consume its actual automatic observation's grant.
                    currentFrameID = try DebugNetworkRunAcceptance.postActionFrameID(initialFrameID: id, result: stationary)
                    currentObservation = stationary
                }
                guard let width = dimension("width", in: currentObservation), let height = dimension("height", in: currentObservation) else {
                    throw DebugNetworkRunAcceptance.Failure.invalidFrame
                }
                let actionFrameID = currentFrameID
                let points = try await DebugNetworkRunAcceptance.armInput(width: width, height: height)
                let inflight = plan.kind == .inflightStop
                let duration = inflight ? 2.0 : 0.6
                await MainActor.run {
                    report.value.swipeAttemptCount += 1
                    report.value.swipeDurationSeconds = duration
                    report.value.inputCommandStartedUptime = ProcessInfo.processInfo.systemUptime
                    report.event(inflight ? "inflight_swipe_requested" : "foreground_swipe_requested")
                }
                let returned: AgentToolResult
                do {
                    returned = try await call(.swipe, arguments: ["frameId": .string(actionFrameID.uuidString),
                        "fromX": .number(points.fromX), "fromY": .number(points.fromY),
                        "toX": .number(points.toX), "toY": .number(points.toY), "duration": .number(duration)],
                        request: request, consumed: &consumed, continuation: continuation)
                    await report.inputReturned(outcome: "succeeded", inflight: inflight)
                } catch {
                    let outcome = (error as? AgentToolError) == .outcomeUnknown ? "unknown" : (error is CancellationError ? "interrupted" : "failed")
                    await report.inputReturned(outcome: outcome, inflight: inflight)
                    throw error
                }
                if inflight { throw DebugNetworkRunAcceptance.Failure.inflightStopMissed }
                await MainActor.run {
                    report.value.recordSwipeReturn(initialFrameID: actionFrameID, result: returned,
                        startRowY: report.value.swipeStartRowYPoints, endRowY: Double(OwnedDeviceCheckState.shared.rowY))
                    DebugNetworkRunAcceptance.captureCurrentReadiness(phase: "foreground_swipe_postaction_returned")
                    report.event("foreground_swipe_postaction_returned")
                }
                // Check the action's own automatic observation; another capture
                // here would conceal a missing or stale post-action result.
                let movedDeadline = clock.now.advanced(by: .seconds(3))
                while await MainActor.run(body: {
                    guard let start = report.value.swipeStartRowYPoints else { return false }
                    return abs(Double(OwnedDeviceCheckState.shared.rowY) - start) <= 30
                }), clock.now < movedDeadline { try await Task.sleep(for: .milliseconds(50)) }
                let rows = await MainActor.run { (report.value.swipeStartRowYPoints, Double(OwnedDeviceCheckState.shared.rowY), UIApplication.shared.applicationState == .active) }
                await MainActor.run {
                    report.value.recordSwipeReturn(initialFrameID: actionFrameID, result: returned, startRowY: rows.0, endRowY: rows.1)
                    DebugNetworkRunAcceptance.captureCurrentReadiness(phase: "foreground_swipe_before_motion_check")
                    report.event("foreground_swipe_before_motion_check")
                }
                guard let startRowY = rows.0, rows.2 else { throw DebugNetworkRunAcceptance.Failure.inputTargetUnavailable }
                try await MainActor.run {
                    try report.value.verifyMovingSwipe(initialFrameID: actionFrameID, result: returned, startRowY: startRowY, endRowY: rows.1)
                    report.event(report.value.motionVerified == true ? "foreground_swipe_postaction_verified" : "foreground_swipe_motion_failed")
                }
            } else if plan.samplesBackground {
                if plan.kind == .background {
                    _ = try await call(.home, arguments: ["frameId": .string(id.uuidString)], request: request, consumed: &consumed, continuation: continuation)
                } else {
                    // No HID Home or launch tool: the user / external XCTest
                    // must background this live run after this report phase.
                    await report.event("awaiting_external_background")
                }
                try await DebugNetworkRunAcceptance.waitForBackground(timeoutSeconds: plan.backgroundWaitSeconds)
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
        try DebugNetworkRunAcceptance.frameID(in: result)
    }
    private func call(_ spec: DeviceToolSpec, arguments: AgentJSONValue, request: AgentRequest, consumed: inout Int,
                      continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws -> AgentToolResult {
        try Task.checkCancellation()
        guard let tool = tools.first(where: { $0.name == spec.rawValue }) else {
            await MainActor.run { report.value.missingToolName = spec.rawValue }
            throw DebugNetworkRunAcceptance.Failure.missingTool
        }
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
