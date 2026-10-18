import EiscueDeviceCore
#if !EISCUE_HID_ONLY
import EiscueDeviceKit
#endif
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

    func prepareDeviceForDictation(id: UUID) async throws { try await dictationSession.prepareDeviceForDictation(id: id) }
    func finishDeviceDictation(id: UUID, reconnect: Bool = true) async -> String? { await dictationSession.finishDeviceDictation(id: id, reconnect: reconnect) }
    func invalidateDictationDeviceRestoration() { dictationSession.invalidateDictationDeviceRestoration() }
    private func cancelDictationDeviceRestoration() async { await dictationSession.cancelDictationDeviceRestoration() }

    var supportsSystemPairing: Bool {
        DevicePairingSupport.supportsSystemPairing(on: deviceOperatingSystemVersion)
    }

    var canChangeDeviceControlBackend: Bool {
        !isRunning && !needsRecovery && pausedRun == nil && canChangeDeviceRoute
    }

    func startLocalTunnel() async {
        await cancelDictationDeviceRestoration()
        guard !isBusy, deviceConnectionMethod == .localVPN,
              let lease = try? deviceSession.acquire(.setup) else { return }
        defer { lease.release() }
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

    func stopLocalTunnel(borrowing parentLease: DeviceLease? = nil) async {
        await cancelDictationDeviceRestoration()
        guard !isDeviceRunActive, !isStoppingTunnel, !isRepairingDeviceConnection else { return }
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
        let lease: DeviceLease?
        if let parentLease {
            guard deviceSession.owner == parentLease.owner else { return }
            lease = nil
        } else {
            guard let acquired = try? deviceSession.acquire(.setup) else { return }
            lease = acquired
        }
        defer { lease?.release() }
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
        guard route != bluetoothInputRoute, deviceConnectionMethod == .bluetoothBoard, !isBusy,
              let lease = try? deviceSession.acquire(.setup) else { return }
        defer { lease.release() }
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
                await bluetoothController.refreshScreenState()
                handleBluetoothSessionChange()
                if deviceSession.owner == nil { _ = await deviceClient.probe() }
                await refreshDeviceStatus()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--bluetooth-setup-check") {
                    recordBluetoothSetupSnapshot()
                }
                #endif
                handleBluetoothSessionChange()
            }
        }
    }

    #if DEBUG
    func recordBluetoothSetupStage() {
        guard ProcessInfo.processInfo.arguments.contains("--bluetooth-setup-check") else { return }
        let stage: String
        if case .failed(let error) = bluetoothController.board.state { stage = "failed(\(error.rawValue))" }
        else { stage = String(describing: bluetoothController.board.state) }
        guard bluetoothSetupStages.last?.stage != stage else { return }
        bluetoothSetupStages.append((stage, Date().timeIntervalSince1970))
        if bluetoothSetupStages.count > 32 { bluetoothSetupStages.removeFirst(bluetoothSetupStages.count - 32) }
        recordBluetoothSetupSnapshot()
    }

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
            "connectionStages": bluetoothSetupStages.map { ["stage": $0.stage, "timestamp": $0.timestamp] },
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
        let identity = deviceSession.identity
        guard await deviceSession.refreshStatus(expected: identity, transportConnected: deviceConnectionMethod == .bluetoothBoard ? isBluetoothConnected : nil) else { return }
        do { hasPairingIdentity = deviceClient.networkSetup == nil ? false : try await deviceClient.hasPairingIdentity() }
        catch { deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription }
        if deviceConnectionMethod == .bluetoothBoard, !isConnecting {
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
        guard !isBusy, !deviceSession.isBusy, deviceConnectionTask == nil else { return }
        let method = deviceConnectionMethod, backend = deviceControlBackend
        guard method != .localVPN || localTunnel.isConnected else { connectionMessage = String(localized: "connection.startLocalFirst"); return }
        let operationID = UUID()
        deviceConnectionError = nil
        if method == .localVPN, backend.resolved(on: deviceOperatingSystemVersion) == .xcTest {
            connectionMessage = String(localized: "connection.automationAuthorization")
        } else {
            connectionMessage = switch method {
            case .bluetoothBoard: String(localized: "bluetooth.connecting", table: "Bluetooth")
            case .localVPN: String(localized: "connection.discovering")
            case .usbBoard: String(localized: "connection.boardDiscovering")
            }
        }
        let task = Task {
            _ = try await deviceSession.connect(method: method, backend: backend, id: operationID)
        }
        deviceConnectionTask = task
        defer { if deviceOperationID == operationID { deviceConnectionTask = nil } }
        do {
            try await task.value
            guard deviceOperationID == operationID else { return }
            deviceConnectionError = nil
            connectionMessage = isDeviceReady ? String(localized: "connection.ready") : {
                if case .unavailable(let reason) = deviceStatus { reason } else { "" }
            }()
        } catch is CancellationError {
            if deviceOperationID == operationID { connectionMessage = String(localized: "connection.disconnected", table: "Runtime") }
        } catch {
            if deviceOperationID == operationID { deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription }
        }
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
        guard DeviceBuildCapabilities.methods.contains(method), method != deviceConnectionMethod, canChangeDeviceRoute,
              let lease = try? deviceSession.acquire(.setup, cancellingConnection: true) else { return }
        defer { lease.release() }
        isChangingDeviceConnectionMethod = true
        defer { isChangingDeviceConnectionMethod = false }
        await disconnectDevice(stopChatRun: false, stopReason: String(localized: "connection.methodChanged"))
        // Stop only Eiscue's owned tunnel when leaving this method, making room
        // for another VPN. LocalTunnelManager never adopts another app's VPN.
        if deviceConnectionMethod == .localVPN, (localTunnel.isConnected || localTunnel.isTransitioning) {
            await stopLocalTunnel(borrowing: lease)
        }
        do { try await deviceSession.switchRoute(to: method, owner: .setup) }
        catch { deviceConnectionError = error.localizedDescription; return }
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
            do { try await deviceSession.selectBackend(backend) }
            catch { deviceConnectionError = error.localizedDescription; return }
            deviceControlBackend = backend
            return
        }
        guard let lease = try? deviceSession.acquire(.setup, cancellingConnection: true) else { return }
        defer { lease.release() }
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
        do { try await deviceSession.selectBackend(backend, owner: .setup) }
        catch { deviceConnectionError = error.localizedDescription; return }
        deviceControlBackend = backend
        deviceConnectionError = nil
        connectionMessage = String(localized: "device.backend.changed", table: "Connections")
    }

    func disconnectDevice(expectedPairingID: UUID? = nil, stopChatRun: Bool = true,
                          stopReason: String = String(localized: "connection.disconnected")) async {
        guard expectedPairingID == nil || expectedPairingID == pairingLeaseID else { return }
        await cancelDictationDeviceRestoration()
        let operationID = UUID()
        let oldLease = pairingLeaseID
        let oldDeviceLease = pairingDeviceLease
        pairingDeviceLease = nil
        let pendingPairing = pairingTask
        pairingLeaseID = nil
        pendingPairing?.cancel(); pairingTask = nil
        if let id = oldLease { background.end(taskID: id, success: false) }
        if let run = activeRun, stopChatRun || run.scope != .chat {
            await stop(expectedRunID: run.id, reason: stopReason)
            _ = await runCoordinator.stopAndWait(runID: run.id)
        }
        await releaseDeviceConnection(operationID: operationID)
        await pendingPairing?.value
        oldDeviceLease?.release()
        guard deviceOperationID == operationID else { return }
        isPairing = false; pairingCode = nil; screenshot = nil
    }

    /// Returns raw remote release confirmation. HID normally returns false;
    /// run cleanup applies the policy for the captured route separately.
    @discardableResult
    func releaseDeviceConnection(client captured: DeviceClient? = nil, operationID: UUID? = nil) async -> Bool {
        let target = captured ?? deviceClient
        if target.device !== deviceClient.device {
            return await target.disconnectAndConfirmRelease()
        }
        if captured == nil { await cancelDictationDeviceRestoration() }
        let pending = deviceConnectionTask
        deviceConnectionTask = nil; pending?.cancel()
        let confirmed: Bool
        do { confirmed = try await deviceSession.releaseConnection(owner: deviceSession.owner, id: operationID ?? UUID()) }
        catch {
            confirmed = await target.disconnectAndConfirmRelease()
            deviceConnectionError = error.localizedDescription
        }
        if let pending { _ = await pending.result }
        guard target.device === deviceClient.device else { return confirmed }
        screenshot = nil
        await refreshDeviceStatus()
        if case .unavailable(let reason) = deviceStatus { connectionMessage = reason }
        return confirmed
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
        guard let deviceLease = try? deviceSession.acquire(.setup) else { return }
        let id = UUID()
        guard let operation = try? deviceSession.beginSetup(owner: deviceLease.owner, id: id) else { deviceLease.release(); return }
        pairingDeviceLease = deviceLease
        deviceConnectionError = nil
        isPairing = true; pairingCode = nil
        connectionMessage = String(localized: "connection.preparingPairing")
        pairingLeaseID = id
        pairingTask = Task {
            defer {
                deviceSession.completeSetup(operation, transportConnected: false)
                if pairingDeviceLease?.id == deviceLease.id { deviceLease.release(); pairingDeviceLease = nil }
            }
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
        }
    }

    func importPairingIdentity(_ url: URL) async {
        await cancelDictationDeviceRestoration()
        guard !isBusy, let lease = try? deviceSession.acquire(.setup) else { return }
        defer { lease.release() }
        let operationID = UUID()
        guard let operation = try? deviceSession.beginSetup(owner: lease.owner, id: operationID) else { return }
        defer { deviceSession.completeSetup(operation, transportConnected: false) }
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
        guard !isBusy, let lease = try? deviceSession.acquire(.setup) else { return }
        defer { lease.release() }
        let operationID = UUID()
        await releaseDeviceConnection(operationID: operationID)
        guard deviceOperationID == operationID,
              let operation = try? deviceSession.beginSetup(owner: lease.owner, id: operationID) else { return }
        defer { deviceSession.completeSetup(operation, transportConnected: false) }
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
        guard !isBusy, isDeviceReady, let lease = try? deviceSession.acquire(.setup) else { return }
        defer { lease.release() }
        let operationID = UUID()
        guard let operation = try? deviceSession.beginSetup(owner: lease.owner, id: operationID) else { return }
        defer { deviceSession.completeSetup(operation) }
        do {
            let frame = try await deviceClient.captureScreenshot()
            guard deviceOperationID == operationID else { return }
            deviceConnectionError = nil
            screenshot = frame; connectionMessage = String(localized: "connection.previewCaptured")
        } catch { if deviceOperationID == operationID { screenshot = nil; deviceConnectionError = error.localizedDescription; connectionMessage = error.localizedDescription } }
    }
    #endif
}
