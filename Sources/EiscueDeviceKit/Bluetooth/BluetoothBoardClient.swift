#if os(iOS)
import Foundation
@preconcurrency import CoreBluetooth

/// A single explicitly connected board. No input is replayed or restored after
/// App termination. Hosts can use `bluetooth-central` background mode for an
/// already established session; they must provide the Bluetooth privacy string.
@MainActor
public final class BluetoothBoardClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public enum State: Sendable, Equatable {
        case idle, waitingForBluetooth, scanning, connecting, discovering, subscribing
        /// The custom GATT channel is ready. This alone does not prove HID input readiness.
        case ready
        case disconnected
        case failed(BluetoothBoardError)
    }

    /// An input acknowledgement proves only that the board emitted HID reports.
    /// Observe the device screen to determine whether an action had its intended effect.
    public struct Receipt: Sendable, Equatable {
        public let opcode: UInt8
        public let requestID: UInt16
        /// Firmware's response byte 5. For INFO (opcode 7) this is a capability
        /// bitmask (absolute pointer: 1, keyboard: 2), not a report count.
        public let emittedReports: UInt8
        public let encrypted: Bool
    }

    public private(set) var state: State = .idle
    public var onStateChange: (@MainActor (State) -> Void)?
    public var connectedBoardID: UUID? { peripheral?.identifier }
    public var connectedBoardName: String? { peripheral?.name }

    private static let serviceID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB3")
    private static let commandID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB4")
    private static let responseID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB5")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var connectWaiter: CheckedContinuation<Void, any Error>?
    private var connectToken: UUID?
    private var commandWaiter: CheckedContinuation<Receipt, any Error>?
    private var commandToken: UUID?
    private var pendingID: UInt16 = 0
    private var pendingOpcode: UInt8 = 0
    // ATT write callbacks carry no request ID. Keep their submission order so a
    // delayed write error for a preempted command cannot fail a subsequent STOP.
    private var writeTokens: [UUID] = []
    private var connectionDeadline: Task<Void, Never>?
    private var commandDeadline: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var candidates: [UUID: CBPeripheral] = [:]
    private var releaseID: UInt16?
    private var releaseToken: UUID?
    private var releaseDeadline: Task<Void, Never>?
    private var closingState: State?
    private var inputMayBeHeld = false

    public override init() { super.init() }

    /// Discover one board and connect its custom GATT channel. A STOP command
    /// or INFO command with `pairingHandshake: true` can request encrypted pairing.
    /// Bluetooth permission is requested only when the host calls this method.
    public func connect() async throws {
        try Task.checkCancellation()
        if state == .ready { return }
        guard connectWaiter == nil, peripheral == nil else { throw BluetoothBoardError.busy }
        let token = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connectWaiter = continuation
                connectToken = token
                // A fresh manager excludes callbacks from a closed connection.
                // No restore identifier: reconnecting never authorizes new input.
                central = CBCentralManager(delegate: self, queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: true])
                connectionDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    guard let self, connectToken == token else { return }
                    failConnection(.discoveryTimeout)
                }
                advancePoweredState()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, connectToken == token else { return }
                closeSession(connectError: CancellationError(), finalState: .disconnected)
            }
        }
    }

    /// Exactly one outstanding command. After an input write, cancellation,
    /// timeout or loss of connection is `DeviceControlError.deliveryUnknown`,
    /// never a reason to retry. Read-only INFO failures are BluetoothBoardError.
    /// Firmware v1 opcodes: STOP 0, MOVE 1, CLICK 2, ASCII 3, KEY 4, ABS_POINT 5,
    /// KEY_COMBO 6, INFO 7. INFO reports capability bits only.
    public func command(opcode: UInt8, payload: [UInt8] = [], pairingHandshake: Bool = false) async throws -> Receipt {
        try Task.checkCancellation()
        guard commandWaiter == nil, closingState == nil else { throw BluetoothBoardError.busy }
        guard BluetoothBoardProtocol.payloadIsValid(opcode: opcode, payload: payload),
              !pairingHandshake || opcode == 0 || opcode == 7 else { throw BluetoothBoardError.invalidCommand }
        guard state == .ready, let peripheral, peripheral.state == .connected,
              let characteristic = commandCharacteristic,
              responseCharacteristic?.isNotifying == true else { throw BluetoothBoardError.disconnected }
        let requestID = try reserveRequestID(for: peripheral.identifier)
        let token = UUID()
        let frame = BluetoothBoardProtocol.frame(opcode: opcode, requestID: requestID, payload: payload)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                commandWaiter = continuation
                commandToken = token
                pendingID = requestID
                pendingOpcode = opcode
                if opcode != 0 && opcode != 7 { inputMayBeHeld = true }
                commandDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(pairingHandshake ? 90 : 5)) } catch { return }
                    guard let self, commandToken == token else { return }
                    failWrittenCommand(.commandTimeout)
                }
                writeTokens.append(token)
                peripheral.writeValue(frame, for: characteristic, type: .withResponse)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, commandToken == token else { return }
                failWrittenCommand(.deliveryUnknown)
            }
        }
    }

    public func move(dx: Int16, dy: Int16) async throws -> Receipt {
        guard abs(Int(dx)) <= 127, abs(Int(dy)) <= 127 else { throw BluetoothBoardError.invalidCommand }
        return try await command(opcode: 1, payload: [UInt8(truncatingIfNeeded: dx), UInt8(truncatingIfNeeded: dx >> 8),
            UInt8(truncatingIfNeeded: dy), UInt8(truncatingIfNeeded: dy >> 8), 0])
    }

    /// Release subscribed HID channels before disconnecting. May interrupt an
    /// outstanding action; that action receives deliveryUnknown. Zero emitted
    /// reports is valid when no HID channel has subscribed, not proof of readiness.
    public func stop() async throws -> Receipt {
        try Task.checkCancellation()
        if commandWaiter != nil {
            guard pendingOpcode != 0 else { throw BluetoothBoardError.busy }
            let error: any Error = pendingOpcode == 7 ? BluetoothBoardError.busy : unknownDelivery(.deliveryUnknown)
            finishCommand(.failure(error))
        }
        return try await command(opcode: 0)
    }

    /// Stop accepting input immediately. For confirmed release call `try await
    /// stop()` first, from a noncancelled cleanup task, then call this method even
    /// on failure. Otherwise a single best-effort STOP gets up to two seconds
    /// before GATT closes. The system may retain its separate HID connection.
    public func disconnect() {
        closeSession(connectError: CancellationError(), finalState: .disconnected)
    }

    private func updateState(_ value: State) {
        guard state != value else { return }
        state = value
        onStateChange?(value)
    }

    private func advancePoweredState() {
        guard connectWaiter != nil, let central else { return }
        switch central.state {
        case .poweredOn:
            guard peripheral == nil, !central.isScanning else { return }
            candidates = Dictionary(uniqueKeysWithValues: central.retrieveConnectedPeripherals(withServices: [Self.serviceID]).map { ($0.identifier, $0) })
            // System HID may already own the connection and suppress advertising.
            // Its name is only a discovery hint; custom GATT is verified below.
            for candidate in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812")])
                where candidate.name == "Eiscue BLE" {
                candidates[candidate.identifier] = candidate
            }
            central.scanForPeripherals(withServices: [Self.serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            if !candidates.isEmpty { scheduleSelection() }
            updateState(.scanning)
        case .unauthorized: failConnection(.bluetoothDenied)
        case .unsupported, .poweredOff: failConnection(.bluetoothUnavailable)
        case .unknown, .resetting: updateState(.waitingForBluetooth)
        @unknown default: failConnection(.bluetoothUnavailable)
        }
    }

    private func scheduleSelection() {
        guard selectionTask == nil else { return }
        let token = connectToken
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, connectToken == token, connectWaiter != nil, let central else { return }
            central.stopScan()
            guard candidates.count == 1, let candidate = candidates.values.first else {
                failConnection(.ambiguousBoard); return
            }
            peripheral = candidate
            candidate.delegate = self
            central.connect(candidate)
            updateState(.connecting)
        }
    }

    private func unknownDelivery(_ reason: BluetoothBoardError) -> DeviceControlError {
        .deliveryUnknown(reason.localizedDescription)
    }

    private func failWrittenCommand(_ reason: BluetoothBoardError) {
        if pendingOpcode == 7 {
            // INFO cannot emit input. Do not attribute an uncertain action to a
            // discovery request. Earlier input still uses the usual STOP cleanup.
            let failure: BluetoothBoardError
            switch reason {
            case .deliveryUnknown: failure = .disconnected
            case .gattWriteRejected, .malformedReply, .hidSendFailed: failure = .connectionFailed
            default: failure = reason
            }
            closeSession(connectError: failure, commandError: failure, finalState: .failed(failure))
        } else {
            closeSession(connectError: reason, commandError: unknownDelivery(reason), finalState: .failed(.deliveryUnknown))
        }
    }

    private func failConnection(_ error: BluetoothBoardError) {
        closeSession(connectError: error, finalState: .failed(error))
    }

    private func closeSession(connectError: any Error, commandError: (any Error)? = nil, finalState: State) {
        if closingState != nil {
            if central?.state != .poweredOn || peripheral?.state != .connected {
                tearDownSession(finalState: finalState)
            }
            return
        }
        connectionDeadline?.cancel(); connectionDeadline = nil
        selectionTask?.cancel(); selectionTask = nil
        central?.stopScan()
        let connectContinuation = connectWaiter
        connectWaiter = nil; connectToken = nil
        let interrupted: any Error = pendingOpcode == 7 ? BluetoothBoardError.disconnected : unknownDelivery(.disconnected)
        finishCommand(.failure(commandError ?? interrupted))
        connectContinuation?.resume(throwing: connectError)
        // Cancelling custom GATT does not necessarily close the system HID link.
        // Send only a release, never replay the uncertain action. Hold this GATT
        // connection briefly for its ACK so queued key/button releases can leave.
        if inputMayBeHeld, central?.state == .poweredOn,
           let peripheral, peripheral.state == .connected,
           let characteristic = commandCharacteristic, responseCharacteristic?.isNotifying == true,
           let id = try? reserveRequestID(for: peripheral.identifier) {
            let token = UUID()
            closingState = finalState; releaseID = id; releaseToken = token
            writeTokens.append(token)
            releaseDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, releaseID == id, let closingState else { return }
                tearDownSession(finalState: closingState)
            }
            peripheral.writeValue(BluetoothBoardProtocol.frame(opcode: 0, requestID: id, payload: []), for: characteristic, type: .withResponse)
            updateState(finalState)
            return
        }
        tearDownSession(finalState: finalState)
    }

    private func tearDownSession(finalState: State) {
        releaseDeadline?.cancel(); releaseDeadline = nil
        releaseID = nil; releaseToken = nil; closingState = nil
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.delegate = nil
        central = nil; peripheral = nil
        commandCharacteristic = nil; responseCharacteristic = nil
        candidates.removeAll(); writeTokens.removeAll()
        inputMayBeHeld = false
        updateState(finalState)
    }

    private func finishCommand(_ result: Result<Receipt, any Error>) {
        commandDeadline?.cancel(); commandDeadline = nil
        let waiter = commandWaiter
        commandWaiter = nil; commandToken = nil
        waiter?.resume(with: result)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        if connectWaiter != nil { advancePoweredState() }
        else if central.state != .poweredOn, peripheral != nil {
            failConnection(central.state == .unauthorized ? .bluetoothDenied : .bluetoothUnavailable)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                              advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, connectWaiter != nil, self.peripheral == nil else { return }
        candidates[peripheral.identifier] = peripheral
        scheduleSelection()
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral else { return }
        peripheral.discoverServices([Self.serviceID])
        updateState(.discovering)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        failConnection(.connectionFailed)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard central === self.central, peripheral === self.peripheral else { return }
        closeSession(connectError: BluetoothBoardError.disconnected, finalState: .disconnected)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            failConnection(.missingService); return
        }
        peripheral.discoverCharacteristics([Self.commandID, Self.responseID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard peripheral === self.peripheral, service.uuid == Self.serviceID else { return }
        guard error == nil,
              let command = service.characteristics?.first(where: { $0.uuid == Self.commandID }), command.properties.contains(.write),
              let response = service.characteristics?.first(where: { $0.uuid == Self.responseID }), response.properties.contains(.notify) else {
            failConnection(.missingCharacteristic); return
        }
        commandCharacteristic = command; responseCharacteristic = response
        peripheral.setNotifyValue(true, for: response)
        updateState(.subscribing)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral, characteristic === responseCharacteristic else { return }
        guard closingState == nil else { return }
        guard error == nil, characteristic.isNotifying else { failConnection(.notificationFailed); return }
        connectionDeadline?.cancel(); connectionDeadline = nil
        selectionTask?.cancel(); selectionTask = nil
        let waiter = connectWaiter
        connectWaiter = nil; connectToken = nil
        updateState(.ready)
        if state == .ready { waiter?.resume() }
        else { waiter?.resume(throwing: BluetoothBoardError.disconnected) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral, characteristic === commandCharacteristic, !writeTokens.isEmpty else { return }
        let token = writeTokens.removeFirst()
        if token == releaseToken, error != nil, let closingState {
            tearDownSession(finalState: closingState); return
        }
        guard token == commandToken, error != nil else { return }
        failWrittenCommand(.gattWriteRejected)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral, characteristic === responseCharacteristic else { return }
        if let releaseID, let closingState {
            if error != nil { tearDownSession(finalState: closingState); return }
            guard let data = characteristic.value, data.count == 8 else { return }
            let bytes = [UInt8](data)
            guard UInt16(bytes[2]) | UInt16(bytes[3]) << 8 == releaseID else { return }
            // This is best-effort cleanup; neither errors nor ACKs authorize input.
            tearDownSession(finalState: closingState)
            return
        }
        guard commandWaiter != nil else { return }
        guard error == nil, let data = characteristic.value, data.count == 8 else {
            failWrittenCommand(.malformedReply); return
        }
        let bytes = [UInt8](data), id = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        guard id == pendingID else { return } // A preempted or old command's ACK.
        guard bytes[0] == 1, bytes[1] == pendingOpcode, bytes[6] <= 1, bytes[7] == 0,
              bytes[4] <= 5 else { failWrittenCommand(.malformedReply); return }
        guard bytes[4] == 0 else {
            let failures: [BluetoothBoardError] = [.invalidCommand, .notEncrypted, .boardBusy, .hidNotSubscribed, .hidSendFailed]
            let failure = failures[Int(bytes[4]) - 1]
            // A failed release can follow an emitted key/button press.
            if bytes[5] > 0 || failure == .hidSendFailed { failWrittenCommand(failure) }
            else { finishCommand(.failure(failure)) }
            return
        }
        guard bytes[6] == 1 else {
            failWrittenCommand(.malformedReply); return
        }
        if pendingOpcode == 0 { inputMayBeHeld = false }
        finishCommand(.success(Receipt(opcode: bytes[1], requestID: id, emittedReports: bytes[5], encrypted: true)))
    }

    /// Shared with the Debug fixture: iOS can retain the board's physical HID
    /// connection across App restarts. MainActor serializes both writers. Persist
    /// before sending; corrupt or inaccessible storage must never reset the ID.
    private func reserveRequestID(for identifier: UUID) throws -> UInt16 {
        let files = FileManager.default
        let directory = URL.applicationSupportDirectory.appendingPathComponent("EiscueBLECheck", isDirectory: true)
        let destination = directory.appendingPathComponent("request-ids.json")
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
            var counters: [String: UInt16]
            do { counters = try JSONDecoder().decode([String: UInt16].self, from: Data(contentsOf: destination)) }
            catch CocoaError.fileReadNoSuchFile { counters = [:] }
            let previous = counters[identifier.uuidString] ?? 0
            let next: UInt16 = previous == .max ? 1 : previous + 1
            counters[identifier.uuidString] = next
            let data = try JSONEncoder().encode(counters)
            let temporary = directory.appendingPathComponent(".request-ids-\(UUID().uuidString).json")
            guard files.createFile(atPath: temporary.path, contents: data,
                attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? files.removeItem(at: temporary) }
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
            } else { try files.moveItem(at: temporary, to: destination) }
            return next
        } catch { throw BluetoothBoardError.counterStorageUnavailable }
    }
}
#endif
