import EiscueDeviceCore
import Foundation
import Observation
import SwiftUI

/// Gesture cancellation, capture and connection restoration share one identity.
/// Merely selecting voice mode never acquires or releases device control.
@MainActor
final class DictationDeviceRestoration {
    let id: UUID
    let operationID: UUID
    let method: DeviceConnectionMethod
    let preference: DeviceControlBackend
    let backend: DeviceControlBackend
    let client: DeviceClient
    var lease: DeviceLease?
    var releaseTask: Task<Void, Never>?
    var connectionTask: Task<Void, Error>?
    var finishTask: Task<String?, Never>?
    var releaseFinished = false
    var releaseConfirmed = false
    var isFinishing = false
    var isRestoring = false
    var isValid = true
    var foregroundWaiter: CheckedContinuation<Void, Never>?
    #if DEBUG
    var acceptanceDiagnostic: DictationRecoveryDiagnostic?
    #endif

    func resumeForegroundWait() {
        let waiter = foregroundWaiter
        foregroundWaiter = nil
        waiter?.resume()
    }

    init(id: UUID, operationID: UUID, method: DeviceConnectionMethod, preference: DeviceControlBackend,
         backend: DeviceControlBackend, client: DeviceClient) {
        self.id = id; self.operationID = operationID; self.method = method; self.preference = preference
        self.backend = backend; self.client = client
    }
}

@MainActor @Observable
final class DictationSession {
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let isLocalTunnelConnected: @MainActor (LocalTunnelManager) -> Bool
    var deviceRestoration: DictationDeviceRestoration?
    var preparationID: UUID?
    private var captureLease: DeviceLease?
    init(model: AppModel, isLocalTunnelConnected: @escaping @MainActor (LocalTunnelManager) -> Bool = { $0.isConnected }) {
        self.model = model; self.isLocalTunnelConnected = isLocalTunnelConnected
    }
    let speech = SpeechInputController()
    var isVoiceMode = false
    private(set) var recordingID: UUID?
    private(set) var restorationID: UUID?
    private(set) var cancellingRestorationID: UUID?
    private(set) var isPreparing = false
    var isChangingConnection: Bool { isPreparing || restorationID != nil }
    #if DEBUG
    var acceptanceAccessibilityStatus: String {
        deviceRestoration?.acceptanceDiagnostic?.accessibilityStatus ?? ""
    }
    #endif

    func prepare(model: AppModel) async throws {
        try Task.checkCancellation()
        guard isVoiceMode, recordingID == nil, !isChangingConnection,
              model.currentScenePhase == .active else { throw CancellationError() }
        let id = UUID(), composerID = model.composerSessionID
        recordingID = id; isPreparing = true
        defer { if recordingID == id { isPreparing = false } }
        try await prepareDeviceForDictation(id: id)
        if model.deviceSession.owner != .dictation(id) { captureLease = try model.deviceSession.acquire(.dictation(id)) }
        try Task.checkCancellation()
        guard recordingID == id, isVoiceMode, model.currentScenePhase == .active,
              model.composerSessionID == composerID else { throw CancellationError() }
    }

    /// SpeechInputController reaches idle only after capture has fully stopped.
    func finish(model: AppModel, reconnect: Bool, notice: @escaping (String) -> Void) {
        isVoiceMode = false; isPreparing = false
        guard let id = recordingID else { return }
        recordingID = nil; restorationID = id
        Task { @MainActor in
            let error = await finishDeviceDictation(id: id, reconnect: reconnect)
            captureLease?.release(); captureLease = nil
            guard restorationID == id else { return }
            restorationID = nil
            if let error, model.currentScenePhase == .active { notice(error) }
        }
    }
    func cancelRestoration(model: AppModel) {
        guard let id = restorationID, cancellingRestorationID == nil else { return }
        cancellingRestorationID = id
        Task { @MainActor in
            _ = await finishDeviceDictation(id: id, reconnect: false)
            if cancellingRestorationID == id { cancellingRestorationID = nil }
        }
    }
    func prepareDeviceForDictation(id: UUID) async throws {
        let previous = deviceRestoration
        invalidateDictationDeviceRestoration()
        preparationID = id
        await previous?.releaseTask?.value
        _ = await previous?.finishTask?.value
        try Task.checkCancellation()
        guard preparationID == id, model.currentScenePhase == .active else { throw CancellationError() }
        guard !model.isBusy else { throw DictationDevicePreparationError.busy }
        guard model.isDictationBlockedByDeviceConnection,
              let method = model.activeDeviceConnectionMethod, let backend = model.activeDeviceControlBackend else { return }
        guard !model.needsRecovery, model.pausedRun == nil else { throw DictationDevicePreparationError.busy }

        let lease = try model.deviceSession.acquire(.dictation(id))
        let operationID = UUID()
        let operation: DeviceSession.Operation
        do { operation = try model.deviceSession.beginRelease(owner: lease.owner, id: operationID) }
        catch { lease.release(); throw error }
        let restoration = DictationDeviceRestoration(id: id, operationID: operationID, method: method,
            preference: model.deviceControlBackend, backend: backend, client: lease.client)
        restoration.lease = lease
        #if DEBUG
        restoration.acceptanceDiagnostic = DictationRecoveryDiagnostic.makeIfEnabled()
        recordAcceptance(.preparationAccepted, restoration)
        #endif
        deviceRestoration = restoration
        model.screenshot = nil
        // The release belongs to the connection, so cancelling a gesture must
        // still wait for media teardown before restoring or starting a new one.
        restoration.releaseTask = Task { [model] in
            #if DEBUG
            // The real release is admitted and owned, but has NOT been sent.
            // Gesture cancellation still awaits this task and its real release.
            await restoration.acceptanceDiagnostic?.waitBeforeRelease()
            recordAcceptance(.releaseDispatched, restoration)
            #endif
            restoration.releaseConfirmed = await restoration.client.disconnectAndConfirmRelease()
            #if DEBUG
            recordAcceptance(.releaseReturned, restoration)
            #endif
            let status = await restoration.client.status()
            if model.deviceSession.completeRelease(operation, confirmed: restoration.releaseConfirmed, status: status) {
                if case .unavailable(let reason) = model.deviceStatus { model.connectionMessage = reason }
            }
            // Keep our pending release recognizable until the busy state settles,
            // so the UI does not cancel preparation before it receives this error.
            if !restoration.releaseConfirmed { restoration.isValid = false }
            restoration.releaseFinished = true
            #if DEBUG
            recordAcceptance(.releaseSettled, restoration)
            #endif
            if !restoration.isValid, restoration.finishTask == nil,
               deviceRestoration === restoration { restoration.lease?.release(); deviceRestoration = nil }
        }
        await restoration.releaseTask?.value
        try Task.checkCancellation()
        guard restoration.releaseConfirmed else { throw DictationDevicePreparationError.releaseUnconfirmed }
        guard preparationID == id, restoration.isValid, !restoration.isFinishing,
              deviceRestoration === restoration, model.deviceOperationID == operationID,
              model.currentScenePhase == .active else { throw CancellationError() }
    }

    func finishDeviceDictation(id: UUID, reconnect: Bool = true) async -> String? {
        if preparationID == id { preparationID = nil }
        guard let restoration = deviceRestoration, restoration.id == id else { return nil }
        restoration.isFinishing = true
        #if DEBUG
        recordAcceptance(reconnect ? .finishRequested : .cancelRestorationRequested, restoration)
        #endif
        if !reconnect {
            restoration.isValid = false
            restoration.connectionTask?.cancel()
            restoration.resumeForegroundWait()
        }
        if let task = restoration.finishTask { return await task.value }
        let task = Task { [model] in await model.dictationSession.restoreDeviceAfterDictation(restoration) }
        restoration.finishTask = task
        return await task.value
    }

    func invalidateDictationDeviceRestoration() {
        preparationID = nil
        guard let restoration = deviceRestoration else { return }
        restoration.isValid = false
        #if DEBUG
        recordAcceptance(.restorationInvalidated, restoration)
        #endif
        // External events advance DeviceSession's operation identity before
        // invalidating us. Cancel only the task owned by this restoration.
        restoration.connectionTask?.cancel()
        restoration.resumeForegroundWait()
        if restoration.releaseFinished, restoration.finishTask == nil { restoration.lease?.release(); deviceRestoration = nil }
    }

    func cancelDictationDeviceRestoration() async {
        let restoration = deviceRestoration
        invalidateDictationDeviceRestoration()
        await restoration?.releaseTask?.value
        _ = await restoration?.finishTask?.value
    }

    func resumeRestorationAfterForegrounding() {
        guard model.currentScenePhase == .active,
              deviceRestoration?.method != .localVPN || !model.isReconcilingForegroundTunnel else { return }
        deviceRestoration?.resumeForegroundWait()
    }

    private func isCurrentRestoration(_ restoration: DictationDeviceRestoration) -> Bool {
        restoration.isValid && deviceRestoration === restoration &&
        model.deviceOperationID == restoration.operationID &&
        model.deviceConnectionMethod == restoration.method && model.deviceControlBackend == restoration.preference &&
        !model.isRunning && !model.isRepairingDeviceConnection && !model.needsRecovery && model.pausedRun == nil
    }

    private func canRestoreDeviceAfterDictation(_ restoration: DictationDeviceRestoration) -> Bool {
        isCurrentRestoration(restoration) && model.currentScenePhase == .active
            && (restoration.method != .localVPN || !model.isReconcilingForegroundTunnel)
    }

    private func waitForActiveRestoration(_ restoration: DictationDeviceRestoration) async -> Bool {
        // Retain the borrow through transient inactivity and the current
        // foreground VPN read, including a connect that returned in between.
        // Every wake rechecks the captured connection identity.
        while !Task.isCancelled, isCurrentRestoration(restoration),
              model.currentScenePhase == .inactive || (restoration.method == .localVPN && model.isReconcilingForegroundTunnel) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { restoration.foregroundWaiter = continuation }
                }
            } onCancel: {
                Task { @MainActor in restoration.resumeForegroundWait() }
            }
        }
        return !Task.isCancelled && canRestoreDeviceAfterDictation(restoration)
    }

    private func restoreDeviceAfterDictation(_ restoration: DictationDeviceRestoration) async -> String? {
        await restoration.releaseTask?.value
        #if DEBUG
        recordAcceptance(.restorationStarted, restoration)
        #endif
        defer {
            restoration.connectionTask = nil
            restoration.lease?.release()
            if deviceRestoration === restoration {
                model.deviceConnectionTask = nil
                deviceRestoration = nil
            }
            #if DEBUG
            recordAcceptance(.restorationFinished, restoration)
            #endif
        }
        guard await waitForActiveRestoration(restoration) else { return nil }
        let failure = String(localized: "speech.deviceReconnectFailed", table: "Speech")
        guard restoration.method != .localVPN || isLocalTunnelConnected(model.localTunnel) else {
            #if DEBUG
            recordAcceptance(.vpnUnavailableBeforeConnect, restoration)
            #endif
            model.deviceConnectionError = failure; model.connectionMessage = failure
            return failure
        }
        restoration.isRestoring = true
        let operation: DeviceSession.Operation
        do {
            operation = try model.deviceSession.beginConnection(method: restoration.method, backend: restoration.preference,
                owner: .dictation(restoration.id), id: restoration.operationID)
        } catch {
            guard canRestoreDeviceAfterDictation(restoration) else { return nil }
            model.deviceConnectionError = failure; model.connectionMessage = failure
            return failure
        }
        let task = Task {
            #if DEBUG
            recordAcceptance(.connectDispatched, restoration)
            #endif
            try await restoration.client.connect(method: restoration.method, configuration: .defaults, backend: restoration.backend)
            #if DEBUG
            recordAcceptance(.connectReturned, restoration)
            // Actual connect has returned. Keep the existing cancellation check
            // and partial-media cleanup authoritative before publishing Ready.
            try await restoration.acceptanceDiagnostic?.waitBeforePublish()
            #endif
            try Task.checkCancellation()
        }
        restoration.connectionTask = task
        model.deviceConnectionTask = task
        do {
            try await task.value
            let status = await restoration.client.status()
            if case .ready = status, await waitForActiveRestoration(restoration),
               model.deviceSession.completeConnection(operation, status: status) {
                model.deviceConnectionError = nil
                model.connectionMessage = String(localized: "connection.ready")
                #if DEBUG
                recordAcceptance(.readyPublished, restoration)
                #endif
                return nil
            }
        } catch { /* Release partial or cancelled media before another command can proceed. */ }
        #if DEBUG
        recordAcceptance(.connectNotPublished, restoration)
        #endif
        _ = model.deviceSession.completeConnection(operation, status: .unavailable(reason: failure), connected: false)
        // Media teardown remains owned by this captured borrower even after its
        // restoration was invalidated. A failed close must gate later borrowers.
        let cleanup = try? model.deviceSession.beginRelease(owner: .dictation(restoration.id), id: model.deviceOperationID)
        #if DEBUG
        recordAcceptance(.cleanupDispatched, restoration)
        #endif
        let confirmed = await restoration.client.disconnectAndConfirmRelease()
        #if DEBUG
        recordAcceptance(.cleanupReturned, restoration, cleanupConfirmed: confirmed)
        #endif
        let status = await restoration.client.status()
        if let cleanup { _ = model.deviceSession.completeRelease(cleanup, confirmed: confirmed, status: status) }
        model.screenshot = nil
        guard canRestoreDeviceAfterDictation(restoration) else { return nil }
        let message = confirmed ? failure : String(localized: "speech.deviceReconnectReleaseFailed", table: "Speech")
        model.deviceConnectionError = message; model.connectionMessage = message
        return message
    }

    #if DEBUG
    private func recordAcceptance(_ phase: DictationRecoveryDiagnostic.Phase,
                                  _ restoration: DictationDeviceRestoration, cleanupConfirmed: Bool? = nil) {
        restoration.acceptanceDiagnostic?.record(phase, snapshot: .init(
            foreground: model.currentScenePhase == .active,
            background: model.currentScenePhase == .background,
            vpnConnected: model.localTunnel.isConnected,
            valid: restoration.isValid, releaseFinished: restoration.releaseFinished,
            releaseConfirmed: restoration.releaseConfirmed, captureBusy: speech.isBusy,
            ready: model.isDeviceReady, cleanupConfirmed: cleanupConfirmed))
    }
    #endif

}

#if DEBUG
/// Opt-in timing evidence for the normal App. Fixed phases, times and booleans
/// only; no session IDs, draft, transcript, audio, peer or arbitrary error text.
/// A new admitted release replaces this bounded report. Export it before the
/// next recording. Waits do not simulate permissions, transport or RPC results.
@MainActor @Observable
final class DictationRecoveryDiagnostic {
    struct Configuration: Equatable {
        let beforeRelease: Bool
        let beforePublish: Bool
        init?(arguments: [String]) {
            guard arguments.contains("--speech-diagnostics") else { return nil }
            beforeRelease = arguments.contains("--dictation-wait-before-release")
            beforePublish = arguments.contains("--dictation-wait-before-publish")
            guard beforeRelease || beforePublish else { return nil }
        }
    }
    enum Phase: String, Codable {
        case preparationAccepted = "preparation-accepted"
        case releaseWaitEntered = "release-before-dispatch-wait-entered"
        case releaseWaitFinished = "release-before-dispatch-wait-finished"
        case releaseDispatched = "release-dispatched"
        case releaseReturned = "release-returned"
        case releaseSettled = "release-settled"
        case finishRequested = "finish-requested"
        case cancelRestorationRequested = "cancel-restoration-requested"
        case restorationInvalidated = "restoration-invalidated"
        case restorationStarted = "restoration-started"
        case vpnUnavailableBeforeConnect = "vpn-unavailable-before-connect"
        case connectDispatched = "connect-dispatched"
        case connectReturned = "connect-returned"
        case publishWaitEntered = "connect-returned-before-publish-wait-entered"
        case publishWaitFinished = "connect-returned-before-publish-wait-finished"
        case publishWaitCancelled = "connect-returned-before-publish-wait-cancelled"
        case readyPublished = "ready-published"
        case connectNotPublished = "connect-not-published"
        case cleanupDispatched = "cleanup-dispatched"
        case cleanupReturned = "cleanup-returned"
        case restorationFinished = "restoration-finished"
    }
    struct Snapshot: Codable {
        let foreground: Bool
        let background: Bool
        let vpnConnected: Bool
        let valid: Bool
        let releaseFinished: Bool
        let releaseConfirmed: Bool
        let captureBusy: Bool
        let ready: Bool
        let cleanupConfirmed: Bool?
    }
    struct Event: Codable {
        let phase: Phase
        let time: TimeInterval
        let snapshot: Snapshot?
    }
    struct Report: Encodable {
        let schemaVersion = 1
        let releaseBeforeDispatchWaitSeconds: Int
        let connectReturnedBeforePublishWaitSeconds: Int
        let events: [Event]
    }
    private static weak var current: DictationRecoveryDiagnostic?
    let configuration: Configuration
    private(set) var phase: Phase = .preparationAccepted
    private(set) var waiting = false
    @ObservationIgnored private(set) var events: [Event] = []
    @ObservationIgnored private let outputURL: URL
    var accessibilityStatus: String { "phase=\(phase.rawValue) waiting=\(waiting)" }

    static func makeIfEnabled() -> DictationRecoveryDiagnostic? {
        guard let configuration = Configuration(arguments: ProcessInfo.processInfo.arguments) else { return nil }
        return DictationRecoveryDiagnostic(configuration: configuration,
            outputURL: URL.documentsDirectory.appendingPathComponent("DictationRecoveryDiagnostic.json"))
    }
    init(configuration: Configuration, outputURL: URL) {
        self.configuration = configuration
        self.outputURL = outputURL
        Self.current = self
    }
    func record(_ phase: Phase, snapshot: Snapshot? = nil) {
        self.phase = phase
        events.append(Event(phase: phase, time: Date().timeIntervalSince1970, snapshot: snapshot))
        if events.count > 64 { events.removeFirst(events.count - 64) }
        // A late callback can update its own in-memory evidence, but must not
        // replace the report belonging to a later admitted recording.
        guard Self.current === self else { return }
        let report = Report(releaseBeforeDispatchWaitSeconds: configuration.beforeRelease ? 8 : 0,
            connectReturnedBeforePublishWaitSeconds: configuration.beforePublish ? 12 : 0, events: events)
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: outputURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
    }
    func waitBeforeRelease() async {
        guard configuration.beforeRelease else { return }
        waiting = true
        record(.releaseWaitEntered)
        // This owned release task is independent of gesture cancellation.
        try? await Task.sleep(for: .seconds(8))
        waiting = false
        record(.releaseWaitFinished)
    }
    func waitBeforePublish() async throws {
        guard configuration.beforePublish else { return }
        waiting = true
        record(.publishWaitEntered)
        do {
            try await Task.sleep(for: .seconds(12))
            waiting = false
            record(.publishWaitFinished)
        } catch {
            waiting = false
            record(.publishWaitCancelled)
            throw error
        }
    }
}
#endif
