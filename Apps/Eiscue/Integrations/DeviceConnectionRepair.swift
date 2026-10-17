import EiscueDeviceCore
import Foundation

enum DeviceConnectionRepairResult: Equatable, Sendable {
    case released, notConnected, unconfirmed, busy, cancelled
}

@MainActor
final class DeviceConnectionRepairSession {
    var cleanupFinished = false
    var finishRequested = false
    let resumesBluetoothMonitor: Bool

    init(resumesBluetoothMonitor: Bool) { self.resumesBluetoothMonitor = resumesBluetoothMonitor }
}

extension AppModel {
    var canRepairDeviceConnection: Bool {
        currentScenePhase == .active && !isLoading && !isBusy &&
        deviceConnectionTask == nil && dictationPreparationID == nil &&
        (dictationDeviceRestoration == nil || (dictationDeviceRestoration?.isValid == false &&
            dictationDeviceRestoration?.releaseFinished == true && dictationDeviceRestoration?.isRestoring == false &&
            dictationDeviceRestoration?.finishTask == nil))
    }

    func repairDeviceConnection() async -> DeviceConnectionRepairResult {
        guard !Task.isCancelled, canRepairDeviceConnection else { return .busy }
        isRepairingDeviceConnection = true
        let session = DeviceConnectionRepairSession(resumesBluetoothMonitor: bluetoothMonitor != nil)
        deviceConnectionRepair = session
        invalidateDictationDeviceRestoration()
        let monitor = bluetoothMonitor
        bluetoothMonitor = nil; monitor?.cancel()
        let client = deviceClient
        let usesHID = deviceConnectionMethod == .bluetoothBoard
        // Route switching retains a separate network controller only for HID.
        // Its failed media release may outlive the selected connection.
        let retainedNetwork = usesHID ? networkDeviceClient : nil
        let hadActiveConnection = activeDeviceConnectionMethod != nil || isDeviceReady
        deviceOperationID = UUID()
        activeDeviceConnectionMethod = nil; activeDeviceControlBackend = nil; screenshot = nil

        // View cancellation must not interrupt the owned release or unlock
        // connection actions while cleanup is still settling.
        let cleanup = Task {
            await monitor?.value
            var hadConnection = hadActiveConnection
            if case .ready = await client.status() { hadConnection = true }
            if let retainedNetwork, case .ready = await retainedNetwork.status() { hadConnection = true }
            var confirmed = true
            if usesHID { await client.disconnect() }
            else { confirmed = await client.disconnectAndConfirmRelease() }
            if let retainedNetwork {
                let released = await retainedNetwork.disconnectAndConfirmRelease()
                confirmed = confirmed && released
                if case .ready = await retainedNetwork.status() { confirmed = false }
            }
            await refreshDeviceStatus()
            if isDeviceReady { confirmed = false }
            activeDeviceConnectionMethod = nil; activeDeviceControlBackend = nil; screenshot = nil
            if case .unavailable(let reason) = deviceStatus { connectionMessage = reason }
            if confirmed { deviceConnectionError = nil }
            session.cleanupFinished = true
            if session.finishRequested { finishDeviceConnectionRepair() }
            return confirmed ? (hadConnection ? DeviceConnectionRepairResult.released : .notConnected) : .unconfirmed
        }
        let result = await cleanup.value
        return Task.isCancelled || currentScenePhase != .active ? .cancelled : result
    }

    /// The caller finishes only after its microphone check has fully stopped.
    func finishDeviceConnectionRepair() {
        guard let session = deviceConnectionRepair else { return }
        session.finishRequested = true
        guard session.cleanupFinished else { return }
        deviceConnectionRepair = nil
        isRepairingDeviceConnection = false
        if session.resumesBluetoothMonitor { startBluetoothMonitor() }
    }
}
