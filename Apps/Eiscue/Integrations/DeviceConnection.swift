import EiscueDeviceKit
import Foundation

enum DevicePairingSupport {
    static func supportsSystemPairing(on version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 27
    }
}

enum DeviceMicrophonePolicy {
    static func blocksDictation(method: DeviceConnectionMethod?, backend: DeviceControlBackend?, isConnected: Bool,
                                on version: OperatingSystemVersion) -> Bool {
        guard isConnected, version.majorVersion >= 27, backend == .coreDevice else { return false }
        switch method {
        case .localVPN, .usbBoard:
            // CoreDevice uses DisplayService on either network route.
            // Remote-muted input was observed on the local-VPN test phone;
            // the USB network relay shares that backend, but is not mic-tested.
            return true
        case .bluetoothBoard, nil:
            // Both BLE and USB HID use this route with ReplayKit. USB HID is
            // not usbBoard (the network relay); neither uses DisplayService.
            return false
        }
    }
}

@MainActor
final class DictationDeviceRestoration {
    let id: UUID
    let operationID: UUID
    let method: DeviceConnectionMethod
    let preference: DeviceControlBackend
    let backend: DeviceControlBackend
    let client: DeviceClient
    var releaseTask: Task<Void, Never>?
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

enum DictationDevicePreparationError: LocalizedError {
    case busy, releaseUnconfirmed
    var errorDescription: String? {
        switch self {
        case .busy: String(localized: "speech.devicePreparationBusy", table: "Speech")
        case .releaseUnconfirmed: String(localized: "speech.deviceReleaseFailed", table: "Speech")
        }
    }
}

extension AppModel {
    var isDictationBlockedByDeviceConnection: Bool {
        DeviceMicrophonePolicy.blocksDictation(method: activeDeviceConnectionMethod, backend: activeDeviceControlBackend,
                                               isConnected: isDeviceReady,
                                               on: deviceOperatingSystemVersion)
    }

    func prepareDeviceForDictation(id: UUID) async throws {
        let previous = dictationDeviceRestoration
        invalidateDictationDeviceRestoration()
        dictationPreparationID = id
        await previous?.releaseTask?.value
        _ = await previous?.finishTask?.value
        try Task.checkCancellation()
        guard dictationPreparationID == id, currentScenePhase == .active else { throw CancellationError() }
        guard !isBusy else { throw DictationDevicePreparationError.busy }
        guard isDictationBlockedByDeviceConnection,
              let method = activeDeviceConnectionMethod, let backend = activeDeviceControlBackend else { return }
        guard !needsRecovery, pausedRun == nil else { throw DictationDevicePreparationError.busy }

        let operationID = UUID(); deviceOperationID = operationID
        let restoration = DictationDeviceRestoration(id: id, operationID: operationID, method: method,
            preference: deviceControlBackend, backend: backend, client: deviceClient)
        dictationDeviceRestoration = restoration
        isConnecting = true
        activeDeviceConnectionMethod = nil; activeDeviceControlBackend = nil; screenshot = nil
        deviceStatus = .unavailable(reason: String(localized: "connection.disconnected"))
        // The release belongs to the connection, so cancelling a gesture must
        // still wait for media teardown before restoring or starting a new one.
        restoration.releaseTask = Task {
            restoration.releaseConfirmed = await restoration.client.disconnectAndConfirmRelease()
            let status = await restoration.client.status()
            if deviceOperationID == operationID {
                deviceStatus = status; isConnecting = false
                if case .unavailable(let reason) = status { connectionMessage = reason }
            }
            // Keep our pending release recognizable until the busy state settles,
            // so the UI does not cancel preparation before it receives this error.
            if !restoration.releaseConfirmed { restoration.isValid = false }
            restoration.releaseFinished = true
            if !restoration.isValid, restoration.finishTask == nil,
               dictationDeviceRestoration === restoration { dictationDeviceRestoration = nil }
        }
        await restoration.releaseTask?.value
        try Task.checkCancellation()
        guard restoration.releaseConfirmed else { throw DictationDevicePreparationError.releaseUnconfirmed }
        guard dictationPreparationID == id, restoration.isValid, !restoration.isFinishing,
              dictationDeviceRestoration === restoration, deviceOperationID == operationID,
              currentScenePhase == .active else { throw CancellationError() }
    }

    func finishDeviceDictation(id: UUID, reconnect: Bool = true) async -> String? {
        if dictationPreparationID == id { dictationPreparationID = nil }
        guard let restoration = dictationDeviceRestoration, restoration.id == id else { return nil }
        restoration.isFinishing = true
        if !reconnect {
            restoration.isValid = false
            if restoration.isRestoring, deviceOperationID == restoration.operationID { deviceConnectionTask?.cancel() }
        }
        if let task = restoration.finishTask { return await task.value }
        let task = Task { await restoreDeviceAfterDictation(restoration) }
        restoration.finishTask = task
        return await task.value
    }

    func invalidateDictationDeviceRestoration() {
        dictationPreparationID = nil
        guard let restoration = dictationDeviceRestoration else { return }
        restoration.isValid = false
        if restoration.isRestoring, deviceOperationID == restoration.operationID { deviceConnectionTask?.cancel() }
        if restoration.releaseFinished, restoration.finishTask == nil { dictationDeviceRestoration = nil }
    }

    private func cancelDictationDeviceRestoration() async {
        let restoration = dictationDeviceRestoration
        invalidateDictationDeviceRestoration()
        await restoration?.releaseTask?.value
        _ = await restoration?.finishTask?.value
    }

    private func canRestoreDeviceAfterDictation(_ restoration: DictationDeviceRestoration) -> Bool {
        restoration.isValid && dictationDeviceRestoration === restoration &&
        deviceOperationID == restoration.operationID && currentScenePhase == .active &&
        deviceConnectionMethod == restoration.method && deviceControlBackend == restoration.preference &&
        !isRunning && !isRepairingDeviceConnection && !needsRecovery && pausedRun == nil
    }

    private func restoreDeviceAfterDictation(_ restoration: DictationDeviceRestoration) async -> String? {
        await restoration.releaseTask?.value
        defer {
            if dictationDeviceRestoration === restoration { dictationDeviceRestoration = nil }
            if deviceOperationID == restoration.operationID {
                isConnecting = false; deviceConnectionTask = nil
                if !isDeviceReady { activeDeviceConnectionMethod = nil; activeDeviceControlBackend = nil }
            }
        }
        guard canRestoreDeviceAfterDictation(restoration) else { return nil }
        let failure = String(localized: "speech.deviceReconnectFailed", table: "Speech")
        guard restoration.method != .localVPN || localTunnel.isConnected else {
            deviceConnectionError = failure; connectionMessage = failure
            return failure
        }
        restoration.isRestoring = true
        isConnecting = true
        activeDeviceConnectionMethod = restoration.method; activeDeviceControlBackend = restoration.backend
        let task = Task {
            try await restoration.client.connect(method: restoration.method, configuration: .defaults, backend: restoration.backend)
            try Task.checkCancellation()
        }
        deviceConnectionTask = task
        do {
            try await task.value
            let status = await restoration.client.status()
            if canRestoreDeviceAfterDictation(restoration), case .ready = status {
                deviceStatus = status; deviceConnectionError = nil
                connectionMessage = String(localized: "connection.ready")
                return nil
            }
        } catch { /* Release partial or cancelled media before another command can proceed. */ }
        await restoration.client.disconnect()
        if deviceOperationID == restoration.operationID {
            deviceStatus = await restoration.client.status()
            activeDeviceConnectionMethod = nil; activeDeviceControlBackend = nil; screenshot = nil
        }
        guard canRestoreDeviceAfterDictation(restoration) else { return nil }
        deviceConnectionError = failure; connectionMessage = failure
        return failure
    }

    var supportsSystemPairing: Bool {
        DevicePairingSupport.supportsSystemPairing(on: deviceOperatingSystemVersion)
    }

    var canChangeDeviceControlBackend: Bool {
        !isRunning && !isRepairingDeviceConnection && !needsRecovery && pausedRun == nil && !isChangingDeviceConnectionMethod &&
        !isSaving && !isStopping && !isPairing && !isManagingTunnel && !isStoppingTunnel &&
        !isImportingAttachments && (!isConnecting || deviceConnectionTask != nil)
    }

    func startLocalTunnel() async {
        await cancelDictationDeviceRestoration()
        guard !isBusy, deviceConnectionMethod == .localVPN else { return }
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
        await cancelDictationDeviceRestoration()
        guard !isStoppingTunnel, !isRepairingDeviceConnection else { return }
        isStoppingTunnel = true
        defer { isStoppingTunnel = false }
        // Stop is available while the system is still authorizing or starting.
        // Device media must be released before its network route is removed.
        if activeDeviceConnectionMethod == .localVPN || isPairing {
            await disconnectDevice(stopChatRun: false, stopReason: String(localized: "connection.localStopping"))
        }
        #if DEBUG
        // This fixture has an in-memory control session and no system VPN.
        if DebugDevicePageFixture.isEnabled { return }
        #endif
        do { try await localTunnel.stop() }
        catch { errorMessage = error.localizedDescription }
    }

    var isBluetoothConnected: Bool { _ = bluetoothRevision; return bluetoothController.isConnected }
    var isBluetoothScreenShared: Bool { _ = bluetoothRevision; return bluetoothController.screenState?.isActive == true }
    var isBluetoothPointerVerified: Bool { _ = bluetoothRevision; return bluetoothController.isPointerVerified }
    var bluetoothInputRoute: BluetoothBoardInputRoute { _ = bluetoothRevision; return bluetoothController.inputRoute }
    var hasBoardCompanionDisplay: Bool { _ = bluetoothRevision; return bluetoothController.supportsCompanionDisplay }
    var isBoardHardwareStopped: Bool { _ = bluetoothRevision; return bluetoothController.isHardwareStopLatched }

    func selectBluetoothInputRoute(_ route: BluetoothBoardInputRoute) async {
        await cancelDictationDeviceRestoration()
        guard route != bluetoothInputRoute, deviceConnectionMethod == .bluetoothBoard, !isBusy else { return }
        isChangingDeviceConnectionMethod = true
        defer { isChangingDeviceConnectionMethod = false }
        await disconnectDevice(stopChatRun: false, stopReason: String(localized: "bluetooth.outputChanged", table: "Bluetooth"))
        do {
            try bluetoothController.selectInputRoute(route)
            preferences.set(route.rawValue, forKey: "bluetoothInputRoute")
            deviceConnectionError = nil
            connectionMessage = String(localized: route == .usb ? "bluetooth.usbPowerDetail" : "bluetooth.powerDetail", table: "Bluetooth")
            await refreshDeviceStatus()
        } catch { deviceConnectionError = error.localizedDescription }
    }

    func startBluetoothMonitor() {
        guard bluetoothMonitor == nil else { return }
        bluetoothMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                guard deviceConnectionMethod == .bluetoothBoard else { continue }
                bluetoothRevision += 1
                let wasReady = isDeviceReady
                await refreshDeviceStatus()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--bluetooth-setup-check") {
                    recordBluetoothSetupSnapshot()
                }
                #endif
                if wasReady && !isDeviceReady, let run = activeRun, run.scope != .chat {
                    await stop(expectedRunID: run.id, reason: String(localized: "bluetooth.stopped", table: "Bluetooth"))
                }
            }
        }
    }

    #if DEBUG
    private func recordBluetoothSetupSnapshot() {
        let state = bluetoothController.screenState
        let report: [String: Any] = [
            "connected": isBluetoothConnected, "sharing": isBluetoothScreenShared,
            "pointerVerified": isBluetoothPointerVerified, "ready": isDeviceReady,
            "inputRoute": bluetoothController.inputRoute.rawValue,
            "s3": bluetoothController.outputInfo?.isS3 ?? false,
            "supportsUSB": bluetoothController.outputInfo?.supportsUSB ?? false,
            "usbConnected": bluetoothController.outputInfo?.isUSBConnected ?? false,
            "authenticated": bluetoothController.board.usesAuthenticatedCommands,
            "companionDisplay": bluetoothController.supportsCompanionDisplay,
            "hardwareStopped": bluetoothController.isHardwareStopLatched,
            "companionPhase": companionLastStatus?.phase.rawValue ?? 0,
            "companionSteps": companionLastStatus?.completedActions ?? 0,
            "connecting": isConnecting, "stage": String(describing: bluetoothController.board.state),
            "screenPhase": state.map { String(describing: $0.phase) } ?? "unavailable",
            "screenWidth": state?.width ?? 0, "screenHeight": state?.height ?? 0,
            "message": connectionMessage, "error": deviceConnectionError ?? "",
            "timestamp": Date().timeIntervalSince1970
        ]
        let directory = URL.applicationSupportDirectory.appendingPathComponent("EiscueBluetoothSetup")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
            try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
                .write(to: directory.appendingPathComponent("status.json"), options: [.atomic, .completeFileProtection])
        } catch { /* Explicit diagnostics never determine connection state. */ }
    }
    #endif

    func refreshDeviceStatus() async {
        defer { syncBoardCompanion() }
        deviceStatus = await deviceClient.status()
        do { hasPairingIdentity = try await deviceClient.hasPairingIdentity() }
        catch { deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription }
        if deviceConnectionMethod == .bluetoothBoard, !isConnecting {
            activeDeviceConnectionMethod = isBluetoothConnected ? .bluetoothBoard : nil
            activeDeviceControlBackend = nil
            if isBluetoothConnected, !isBoardHardwareStopped { boardHardwareStopPending = false }
            if isDeviceReady {
                deviceConnectionError = nil
                connectionMessage = String(localized: "connection.ready")
            } else if deviceConnectionError == nil, case .unavailable(let reason) = deviceStatus {
                connectionMessage = reason
            }
        }
    }

    func connectDevice() async {
        await cancelDictationDeviceRestoration()
        guard !isBusy, !isConnecting else { return }
        let method = deviceConnectionMethod
        let backend = deviceControlBackend
        guard method != .localVPN || localTunnel.isConnected else { connectionMessage = String(localized: "connection.startLocalFirst"); return }
        let operationID = UUID(); deviceOperationID = operationID
        isConnecting = true; activeDeviceConnectionMethod = method; deviceConnectionError = nil
        activeDeviceControlBackend = method == .bluetoothBoard ? nil : backend.resolved(on: deviceOperatingSystemVersion)
        if method == .localVPN, activeDeviceControlBackend == .xcTest {
            connectionMessage = String(localized: "connection.automationAuthorization")
        } else {
            connectionMessage = switch method {
            case .bluetoothBoard: String(localized: "bluetooth.connecting", table: "Bluetooth")
            case .localVPN: String(localized: "connection.discovering")
            case .usbBoard: String(localized: "connection.boardDiscovering")
            }
        }
        let client = deviceClient
        let task = Task { try await client.connect(method: method, configuration: .defaults, backend: backend) }
        deviceConnectionTask = task
        defer {
            if deviceOperationID == operationID {
                isConnecting = false; deviceConnectionTask = nil
                if !isDeviceReady { activeDeviceConnectionMethod = nil; activeDeviceControlBackend = nil }
            }
        }
        do {
            try await task.value
            guard deviceOperationID == operationID, deviceConnectionMethod == method,
                  deviceControlBackend.resolved(on: deviceOperatingSystemVersion) == backend.resolved(on: deviceOperatingSystemVersion) else { return }
            deviceConnectionError = nil
            await refreshDeviceStatus()
            // Completing discovery/diagnostics is not a control capability.
            if isDeviceReady { connectionMessage = String(localized: "connection.ready") }
            else if case .unavailable(let reason) = deviceStatus { connectionMessage = reason }
        } catch is CancellationError {
            if deviceOperationID == operationID { connectionMessage = String(localized: "connection.disconnected") }
        } catch { if deviceOperationID == operationID { deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription } }
        guard deviceOperationID == operationID else { return }
        await refreshDeviceStatus()
    }

    /// The primary button starts only the selected connection method. Boards never
    /// start a tunnel, change VPN preferences, or fall back onto local VPN.
    func enableDeviceControl() async {
        await cancelDictationDeviceRestoration()
        guard !isBusy, !isChangingDeviceConnectionMethod else { return }
        let method = deviceConnectionMethod
        let backend = deviceControlBackend
        if method == .localVPN, !localTunnel.isConnected {
            await startLocalTunnel()
        }
        guard deviceConnectionMethod == method, deviceControlBackend == backend else { return }
        await connectDevice()
    }

    func selectDeviceConnectionMethod(_ method: DeviceConnectionMethod) async {
        await cancelDictationDeviceRestoration()
        guard method != deviceConnectionMethod, !isChangingDeviceConnectionMethod, !isRepairingDeviceConnection,
              !isSaving, !isStopping, !isManagingTunnel, !isStoppingTunnel, !isImportingAttachments else { return }
        isChangingDeviceConnectionMethod = true
        defer { isChangingDeviceConnectionMethod = false }
        await disconnectDevice(stopChatRun: false, stopReason: String(localized: "connection.methodChanged"))
        // Stop only Eiscue's owned tunnel when leaving this method, making room
        // for another VPN. LocalTunnelManager never adopts another app's VPN.
        if deviceConnectionMethod == .localVPN, (localTunnel.isConnected || localTunnel.isTransitioning) {
            await stopLocalTunnel()
        }
        if method == .bluetoothBoard {
            networkDeviceClient = deviceClient
            deviceClient = DeviceClient(controller: bluetoothController)
        } else if deviceConnectionMethod == .bluetoothBoard {
            deviceClient = networkDeviceClient ?? DeviceClient()
            networkDeviceClient = nil
        }
        deviceConnectionMethod = method
        await refreshDeviceStatus()
        deviceConnectionError = nil
        connectionMessage = switch method {
        case .bluetoothBoard: String(localized: "bluetooth.powerDetail", table: "Bluetooth")
        case .localVPN: String(localized: "connection.vpnSelected")
        case .usbBoard: String(localized: "connection.boardSelected")
        }
    }

    func selectDeviceControlBackend(_ backend: DeviceControlBackend) async {
        await cancelDictationDeviceRestoration()
        guard backend != deviceControlBackend, canChangeDeviceControlBackend else { return }
        guard backend.isAvailable(on: deviceOperatingSystemVersion) else {
            deviceConnectionError = DeviceControlError.backendUnavailable(backend).localizedDescription
            return
        }
        let currentBackend = activeDeviceControlBackend ?? deviceControlBackend.resolved(on: deviceOperatingSystemVersion)
        if deviceConnectionMethod == .bluetoothBoard || backend.resolved(on: deviceOperatingSystemVersion) == currentBackend {
            deviceControlBackend = backend
            return
        }
        isChangingDeviceConnectionMethod = true
        defer { isChangingDeviceConnectionMethod = false }
        let hasSession = activeDeviceConnectionMethod != nil || activeDeviceControlBackend != nil ||
            deviceConnectionTask != nil || isConnecting || isDeviceReady
        if hasSession {
            await disconnectDevice(stopChatRun: false, stopReason: String(localized: "device.backend.changed", table: "Connections"))
        } else {
            // Unavailable clients may still hold partial sessions. Release them
            // without presenting a disconnected preference change as connecting.
            await releaseDeviceConnection()
        }
        deviceControlBackend = backend
        deviceConnectionError = nil
        connectionMessage = String(localized: "device.backend.changed", table: "Connections")
    }

    func disconnectDevice(expectedPairingID: UUID? = nil, stopChatRun: Bool = true,
                          stopReason: String = String(localized: "connection.disconnected")) async {
        guard expectedPairingID == nil || expectedPairingID == pairingLeaseID else { return }
        await cancelDictationDeviceRestoration()
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
        await cancelDictationDeviceRestoration()
        activeDeviceConnectionMethod = nil
        activeDeviceControlBackend = nil
        let pending = deviceConnectionTask
        deviceConnectionTask = nil
        pending?.cancel()
        await deviceClient.disconnect()
        if let pending { _ = await pending.result }
        screenshot = nil
        await refreshDeviceStatus()
        if case .unavailable(let reason) = deviceStatus { connectionMessage = reason }
    }

    func startPairing() {
        invalidateDictationDeviceRestoration()
        guard !isBusy, !isConnecting else { return }
        // iOS 26 has no device-initiated PairableHost Settings flow. Reject
        // before acquiring a background task or changing pairing state.
        guard supportsSystemPairing else {
            connectionMessage = String(localized: "connection.requiresUSBPairing")
            return
        }
        guard deviceConnectionMethod == .localVPN else {
            connectionMessage = String(localized: "connection.boardPairingImport")
            return
        }
        guard localTunnel.isConnected else { connectionMessage = String(localized: "connection.startLocalBeforePairing"); return }
        deviceConnectionError = nil
        isPairing = true; pairingCode = nil
        activeDeviceConnectionMethod = .localVPN
        activeDeviceControlBackend = nil
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
                for try await event in await deviceClient.beginPairing(configuration: .defaults) {
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
            if !isDeviceReady { activeDeviceConnectionMethod = nil }
        }
    }

    func importPairingIdentity(_ url: URL) async {
        await cancelDictationDeviceRestoration()
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
        await cancelDictationDeviceRestoration()
        guard !isBusy else { return }
        let operationID = UUID(); deviceOperationID = operationID
        isConnecting = true
        defer { if deviceOperationID == operationID { isConnecting = false } }
        await releaseDeviceConnection()
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

    #if DEBUG
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
    #endif
}
