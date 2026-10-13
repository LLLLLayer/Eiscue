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
        guard !isStoppingTunnel else { return }
        isStoppingTunnel = true
        defer { isStoppingTunnel = false }
        // Stop is available while the system is still authorizing or starting.
        // Device media must be released before its network route is removed.
        if activeDeviceConnectionMethod == .localVPN || isPairing {
            await disconnectDevice(stopChatRun: false, stopReason: String(localized: "connection.localStopping"))
        }
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
            if isDeviceReady {
                deviceConnectionError = nil
                connectionMessage = String(localized: "connection.ready")
            } else if deviceConnectionError == nil, case .unavailable(let reason) = deviceStatus {
                connectionMessage = reason
            }
        }
    }

    func connectDevice() async {
        guard !isBusy, !isConnecting else { return }
        let method = deviceConnectionMethod
        guard method != .localVPN || localTunnel.isConnected else { connectionMessage = String(localized: "connection.startLocalFirst"); return }
        let operationID = UUID(); deviceOperationID = operationID
        isConnecting = true; activeDeviceConnectionMethod = method; deviceConnectionError = nil
        if method == .localVPN, ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 {
            connectionMessage = String(localized: "connection.automationAuthorization")
        } else {
            connectionMessage = switch method {
            case .bluetoothBoard: String(localized: "bluetooth.connecting", table: "Bluetooth")
            case .localVPN: String(localized: "connection.discovering")
            case .usbBoard: String(localized: "connection.boardDiscovering")
            case .wirelessBoard: String(localized: "connection.wirelessBoardDiscovering")
            }
        }
        let client = deviceClient
        let task = Task { try await client.connect(method: method, configuration: .defaults) }
        deviceConnectionTask = task
        defer {
            if deviceOperationID == operationID {
                isConnecting = false; deviceConnectionTask = nil
                if !isDeviceReady { activeDeviceConnectionMethod = nil }
                // Give the system authorization screen time to dismiss. An idle
                // connection must still be released if the app stays in background.
                scheduleIdleDeviceBackgroundRelease(operationID: operationID, delay: .milliseconds(200))
            }
        }
        do {
            try await task.value
            guard deviceOperationID == operationID, deviceConnectionMethod == method else { return }
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
        guard !isBusy, !isChangingDeviceConnectionMethod else { return }
        let method = deviceConnectionMethod
        if method == .localVPN, !localTunnel.isConnected {
            await startLocalTunnel()
        }
        guard deviceConnectionMethod == method else { return }
        await connectDevice()
    }

    func selectDeviceConnectionMethod(_ method: DeviceConnectionMethod) async {
        guard method != deviceConnectionMethod, !isChangingDeviceConnectionMethod,
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
        case .wirelessBoard: String(localized: "connection.wirelessBoardSelected")
        }
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
        activeDeviceConnectionMethod = nil
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
            if !isDeviceReady { activeDeviceConnectionMethod = nil }
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
