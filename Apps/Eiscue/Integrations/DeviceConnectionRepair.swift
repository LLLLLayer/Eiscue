import EiscueDeviceCore
import Foundation

enum DeviceConnectionRepairResult: Equatable, Sendable {
    case released, notConnected, unconfirmed, busy, cancelled
}

@MainActor
protocol DeviceConnectionRepairTunnel {
    var isConnected: Bool { get }
    func resumeExistingForRepair() async throws -> Bool
}

extension LocalTunnelManager: DeviceConnectionRepairTunnel {}

@MainActor
final class DeviceConnectionRepairSession {
    var lease: DeviceLease?
    var cleanupFinished = false
    var finishRequested = false
    let resumesBluetoothMonitor: Bool

    init(resumesBluetoothMonitor: Bool) { self.resumesBluetoothMonitor = resumesBluetoothMonitor }
}

extension AppModel {
    var canRepairDeviceConnection: Bool {
        currentScenePhase == .active && !isLoading && !isDeviceRunActive && deviceSession.owner == nil &&
        !isSaving && !isPairing && !isStopping && !isConnecting && !isRepairingDeviceConnection &&
        !isChangingDeviceConnectionMethod && !isManagingTunnel && !isStoppingTunnel && !isImportingAttachments &&
        deviceConnectionTask == nil && dictationPreparationID == nil &&
        (dictationDeviceRestoration == nil || (dictationDeviceRestoration?.isValid == false &&
            dictationDeviceRestoration?.releaseFinished == true && dictationDeviceRestoration?.isRestoring == false &&
            dictationDeviceRestoration?.finishTask == nil))
    }

    func repairDeviceConnection(tunnel suppliedTunnel: (any DeviceConnectionRepairTunnel)? = nil) async -> DeviceConnectionRepairResult {
        guard !Task.isCancelled, canRepairDeviceConnection else { return .busy }
        guard let lease = try? deviceSession.acquire(.repair) else { return .busy }
        let hadUnconfirmedRelease = deviceSession.hasUnconfirmedRelease
        let hadActiveConnection = activeDeviceConnectionMethod != nil || isDeviceReady
        guard let operation = try? deviceSession.beginRelease(owner: lease.owner) else { lease.release(); return .busy }
        let requiresLocalTunnel = hadUnconfirmedRelease && operation.method == .localVPN &&
            (operation.backend ?? deviceControlBackend.resolved(on: deviceOperatingSystemVersion)) == .coreDevice
        let tunnel = suppliedTunnel ?? localTunnel
        isRepairingDeviceConnection = true
        let session = DeviceConnectionRepairSession(resumesBluetoothMonitor: bluetoothMonitor != nil)
        session.lease = lease
        deviceConnectionRepair = session
        invalidateDictationDeviceRestoration()
        let monitor = bluetoothMonitor
        bluetoothMonitor = nil; monitor?.cancel()
        let client = operation.client
        let usesHID = operation.method == .bluetoothBoard
        // Route switching retains a separate network controller only for HID.
        // Its failed media release may outlive the selected connection.
        let retainedNetwork = usesHID ? networkDeviceClient : nil
        screenshot = nil

        // View cancellation must not interrupt the owned release or unlock
        // connection actions while cleanup is still settling.
        let cleanup = Task {
            await monitor?.value
            if requiresLocalTunnel, !tunnel.isConnected {
                // This restores transport only for the original cleanup receipt.
                // It never installs a VPN or opens a new device-control session.
                // The backend still owns release evidence if an earlier scoped
                // stop finishes even when this transport preparation fails.
                _ = try? await tunnel.resumeExistingForRepair()
            }
            var hadConnection = hadActiveConnection
            if case .ready = await client.status() { hadConnection = true }
            if let retainedNetwork, case .ready = await retainedNetwork.status() { hadConnection = true }
            let selectedRelease = await client.disconnectAndConfirmRelease()
            let status = await client.status()
            let stillReady: Bool = { if case .ready = status { true } else { false } }()
            let selectedConfirmed = selectedRelease && !stillReady
            var confirmed = (usesHID || selectedConfirmed) && !stillReady
            if let retainedNetwork {
                let released = await retainedNetwork.disconnectAndConfirmRelease()
                confirmed = confirmed && released
                if case .ready = await retainedNetwork.status() { confirmed = false }
            }
            _ = deviceSession.completeRelease(operation, confirmed: selectedConfirmed, status: status)
            syncBoardCompanion()
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
        session.lease?.release()
        deviceConnectionRepair = nil
        isRepairingDeviceConnection = false
        if session.resumesBluetoothMonitor { startBluetoothMonitor() }
    }
}
