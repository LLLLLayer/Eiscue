import EiscueDeviceKit
import Foundation

enum DevicePairingSupport {
    static func supportsSystemPairing(on version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 27
    }
}

extension AppModel {
    var supportsSystemPairing: Bool {
        DevicePairingSupport.supportsSystemPairing(on: ProcessInfo.processInfo.operatingSystemVersion)
    }

    func startLocalTunnel() async {
        guard !isBusy else { return }
        isManagingTunnel = true
        deviceConnectionError = nil
        defer { isManagingTunnel = false }
        do {
            try await localTunnel.start()
            connectionMessage = String(localized: "connection.localReady")
        } catch is CancellationError {
            connectionMessage = String(localized: "connection.localCancelled")
        } catch { deviceConnectionError = error.localizedDescription; errorMessage = error.localizedDescription }
    }

    func stopLocalTunnel() async {
        guard !isStoppingTunnel else { return }
        isStoppingTunnel = true
        defer { isStoppingTunnel = false }
        // Stop is available while the system is still authorizing or starting.
        // Device media must be released before its network route is removed.
        await disconnectDevice(stopChatRun: false, stopReason: String(localized: "connection.localStopping"))
        do { try await localTunnel.stop() }
        catch { errorMessage = error.localizedDescription }
    }

    func refreshDeviceStatus() async {
        deviceStatus = await deviceClient.status()
        do { hasPairingIdentity = try await deviceClient.hasPairingIdentity() }
        catch { deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription }
    }

    func connectDevice() async {
        guard !isBusy, !isConnecting else { return }
        guard localTunnel.isConnected else { connectionMessage = String(localized: "connection.startLocalFirst"); return }
        let operationID = UUID(); deviceOperationID = operationID
        isConnecting = true; deviceConnectionError = nil; connectionMessage = String(localized: "connection.discovering")
        defer { if deviceOperationID == operationID { isConnecting = false } }
        do {
            try await deviceClient.connectLocalVPN(configuration: .defaults)
            guard deviceOperationID == operationID else { return }
            deviceConnectionError = nil
            connectionMessage = String(localized: "connection.ready")
        } catch { if deviceOperationID == operationID { deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription } }
        guard deviceOperationID == operationID else { return }
        await refreshDeviceStatus()
    }

    func disconnectDevice(expectedPairingID: UUID? = nil, stopChatRun: Bool = true,
                          stopReason: String = String(localized: "connection.disconnected")) async {
        guard expectedPairingID == nil || expectedPairingID == pairingLeaseID else { return }
        let operationID = UUID(); deviceOperationID = operationID
        isConnecting = true
        defer { if deviceOperationID == operationID { isConnecting = false } }
        let oldLease = pairingLeaseID
        pairingLeaseID = nil
        pairingTask?.cancel(); pairingTask = nil
        if let id = oldLease { background.end(taskID: id, success: false) }
        if let run = activeRun, stopChatRun || run.scope != .chat { await stop(expectedRunID: run.id, reason: stopReason) }
        await releaseDeviceConnection()
        guard deviceOperationID == operationID else { return }
        isPairing = false; pairingCode = nil; screenshot = nil
    }

    func releaseDeviceConnection() async {
        await deviceClient.disconnect()
        screenshot = nil
        await refreshDeviceStatus()
        if case .unavailable(let reason) = deviceStatus { connectionMessage = reason }
    }

    func startPairing() {
        guard !isBusy, !isConnecting else { return }
        // iOS 26 has no device-initiated PairableHost Settings flow. Reject
        // before acquiring a background task or changing pairing state.
        guard supportsSystemPairing else {
            connectionMessage = String(localized: "connection.requiresUSBPairing")
            return
        }
        guard localTunnel.isConnected else { connectionMessage = String(localized: "connection.startLocalBeforePairing"); return }
        deviceConnectionError = nil
        isPairing = true; pairingCode = nil
        connectionMessage = String(localized: "connection.preparingPairing")
        let id = UUID(); pairingLeaseID = id; deviceOperationID = id
        pairingTask = Task {
            do {
                try await background.begin(taskID: id, title: String(localized: "connection.pairingTitle"),
                                           subtitle: PairingStatusPresentation.preparing.subtitle,
                                           totalUnitCount: PairingStatusPresentation.totalWorkUnits, onExpiration: { [weak self] in
                    Task { await self?.disconnectDevice(expectedPairingID: id) }
                })
                guard pairingLeaseID == id else { return }
                for try await event in await deviceClient.beginPairing() {
                    try Task.checkCancellation()
                    guard pairingLeaseID == id else { return }
                    let phase: PairingStatusPresentation
                    switch event {
                    case .waitingForDevice:
                        connectionMessage = String(localized: "connection.openPairingSettings")
                        phase = .waitingForDevice
                    case .code(let code):
                        pairingCode = code; connectionMessage = String(localized: "connection.enterPairingCode")
                        phase = .confirming
                    case .identitySaved:
                        connectionMessage = String(localized: "connection.identitySaved")
                        phase = .identitySaved
                    case .completed:
                        connectionMessage = String(localized: "connection.pairingComplete")
                        phase = .completed
                    }
                    background.update(taskID: id, completedUnitCount: phase.completedWorkUnits,
                                      totalUnitCount: PairingStatusPresentation.totalWorkUnits,
                                      subtitle: phase.subtitle)
                }
                background.end(taskID: id, success: true)
            } catch {
                background.end(taskID: id, success: false)
                if !Task.isCancelled, pairingLeaseID == id { deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription }
            }
            guard pairingLeaseID == id else { return }
            isPairing = false; pairingCode = nil; pairingLeaseID = nil
            await refreshDeviceStatus()
        }
    }

    func importPairingIdentity(_ url: URL) async {
        guard !isBusy else { return }
        let operationID = UUID(); deviceOperationID = operationID
        isConnecting = true
        defer { if deviceOperationID == operationID { isConnecting = false } }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
            guard size <= 1_048_576 else { throw SkillError.tooLarge }
            try await deviceClient.importPairingIdentity(Data(contentsOf: url))
            guard deviceOperationID == operationID else { return }
            deviceConnectionError = nil
            connectionMessage = String(localized: "connection.identityImported")
            await refreshDeviceStatus()
        } catch { if deviceOperationID == operationID { deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription } }
    }

    func forgetPairingIdentity() async {
        guard !isBusy else { return }
        let operationID = UUID(); deviceOperationID = operationID
        isConnecting = true
        defer { if deviceOperationID == operationID { isConnecting = false } }
        await deviceClient.disconnect()
        guard deviceOperationID == operationID else { return }
        do {
            try await deviceClient.removePairingIdentity()
            guard deviceOperationID == operationID else { return }
            deviceConnectionError = nil
            connectionMessage = String(localized: "connection.identityRemoved")
        } catch { if deviceOperationID == operationID { deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription } }
        guard deviceOperationID == operationID else { return }
        await refreshDeviceStatus()
    }

    func previewScreenshot() async {
        guard !isBusy, isDeviceReady else { return }
        let operationID = UUID(); deviceOperationID = operationID
        isConnecting = true
        defer { if deviceOperationID == operationID { isConnecting = false } }
        do {
            let frame = try await deviceClient.captureScreenshot()
            guard deviceOperationID == operationID else { return }
            deviceConnectionError = nil
            screenshot = frame; connectionMessage = String(localized: "connection.previewCaptured")
        } catch { if deviceOperationID == operationID { screenshot = nil; deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription } }
    }
}
