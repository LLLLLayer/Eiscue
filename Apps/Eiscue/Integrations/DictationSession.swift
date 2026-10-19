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

    init(id: UUID, operationID: UUID, method: DeviceConnectionMethod, preference: DeviceControlBackend,
         backend: DeviceControlBackend, client: DeviceClient) {
        self.id = id; self.operationID = operationID; self.method = method; self.preference = preference
        self.backend = backend; self.client = client
    }
}

@MainActor @Observable
final class DictationSession {
    @ObservationIgnored private unowned let model: AppModel
    var deviceRestoration: DictationDeviceRestoration?
    var preparationID: UUID?
    private var captureLease: DeviceLease?
    init(model: AppModel) { self.model = model }
    let speech = SpeechInputController()
    var isVoiceMode = false
    private(set) var recordingID: UUID?
    private(set) var restorationID: UUID?
    private(set) var cancellingRestorationID: UUID?
    private(set) var isPreparing = false
    var isChangingConnection: Bool { isPreparing || restorationID != nil }

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
        deviceRestoration = restoration
        model.screenshot = nil
        // The release belongs to the connection, so cancelling a gesture must
        // still wait for media teardown before restoring or starting a new one.
        restoration.releaseTask = Task { [model] in
            restoration.releaseConfirmed = await restoration.client.disconnectAndConfirmRelease()
            let status = await restoration.client.status()
            if model.deviceSession.completeRelease(operation, confirmed: restoration.releaseConfirmed, status: status) {
                if case .unavailable(let reason) = model.deviceStatus { model.connectionMessage = reason }
            }
            // Keep our pending release recognizable until the busy state settles,
            // so the UI does not cancel preparation before it receives this error.
            if !restoration.releaseConfirmed { restoration.isValid = false }
            restoration.releaseFinished = true
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
        if !reconnect {
            restoration.isValid = false
            restoration.connectionTask?.cancel()
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
        // External events advance DeviceSession's operation identity before
        // invalidating us. Cancel only the task owned by this restoration.
        restoration.connectionTask?.cancel()
        if restoration.releaseFinished, restoration.finishTask == nil { restoration.lease?.release(); deviceRestoration = nil }
    }

    func cancelDictationDeviceRestoration() async {
        let restoration = deviceRestoration
        invalidateDictationDeviceRestoration()
        await restoration?.releaseTask?.value
        _ = await restoration?.finishTask?.value
    }

    private func canRestoreDeviceAfterDictation(_ restoration: DictationDeviceRestoration) -> Bool {
        restoration.isValid && deviceRestoration === restoration &&
        model.deviceOperationID == restoration.operationID && model.currentScenePhase == .active &&
        model.deviceConnectionMethod == restoration.method && model.deviceControlBackend == restoration.preference &&
        !model.isRunning && !model.isRepairingDeviceConnection && !model.needsRecovery && model.pausedRun == nil
    }

    private func restoreDeviceAfterDictation(_ restoration: DictationDeviceRestoration) async -> String? {
        await restoration.releaseTask?.value
        defer {
            restoration.connectionTask = nil
            restoration.lease?.release()
            if deviceRestoration === restoration {
                model.deviceConnectionTask = nil
                deviceRestoration = nil
            }
        }
        guard canRestoreDeviceAfterDictation(restoration) else { return nil }
        let failure = String(localized: "speech.deviceReconnectFailed", table: "Speech")
        guard restoration.method != .localVPN || model.localTunnel.isConnected else {
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
            try await restoration.client.connect(method: restoration.method, configuration: .defaults, backend: restoration.backend)
            try Task.checkCancellation()
        }
        restoration.connectionTask = task
        model.deviceConnectionTask = task
        do {
            try await task.value
            let status = await restoration.client.status()
            if canRestoreDeviceAfterDictation(restoration), case .ready = status,
               model.deviceSession.completeConnection(operation, status: status) {
                model.deviceConnectionError = nil
                model.connectionMessage = String(localized: "connection.ready")
                return nil
            }
        } catch { /* Release partial or cancelled media before another command can proceed. */ }
        _ = model.deviceSession.completeConnection(operation, status: .unavailable(reason: failure), connected: false)
        // Media teardown remains owned by this captured borrower even after its
        // restoration was invalidated. A failed close must gate later borrowers.
        let cleanup = try? model.deviceSession.beginRelease(owner: .dictation(restoration.id), id: model.deviceOperationID)
        let confirmed = await restoration.client.disconnectAndConfirmRelease()
        let status = await restoration.client.status()
        if let cleanup { _ = model.deviceSession.completeRelease(cleanup, confirmed: confirmed, status: status) }
        model.screenshot = nil
        guard canRestoreDeviceAfterDictation(restoration) else { return nil }
        let message = confirmed ? failure : String(localized: "speech.deviceReconnectReleaseFailed", table: "Speech")
        model.deviceConnectionError = message; model.connectionMessage = message
        return message
    }

}
