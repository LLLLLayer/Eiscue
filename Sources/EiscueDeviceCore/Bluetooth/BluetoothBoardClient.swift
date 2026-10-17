#if os(iOS)
import Foundation
@preconcurrency import CoreBluetooth

/// A single explicitly connected board. No input is replayed or restored after
/// App termination. Hosts can use `bluetooth-central` background mode for an
/// already established session; they must provide the Bluetooth privacy string.
@MainActor
public final class BluetoothBoardClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    public enum State: Sendable, Equatable {
        case idle, waitingForBluetooth, scanning, connecting, discovering, subscribing, authenticating
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
    public var usesAuthenticatedCommands: Bool { authenticatedSession != nil }
    public var supportsCompanionDisplay: Bool { companionCharacteristic != nil && hardwareStopCharacteristic != nil }
    public var isHardwareStopLatched: Bool { supportsCompanionDisplay && companionStop.isLatched }
    public var onHardwareStop: (@MainActor (BluetoothHardwareStopEvent) -> Void)?

    private static let serviceID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB3")
    private static let commandID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB4")
    private static let responseID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB5")
    private static let challengeID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB6")
    private static let proofID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB7")
    private static let companionID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB8")
    private static let hardwareStopID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB9")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var challengeCharacteristic: CBCharacteristic?
    private var proofCharacteristic: CBCharacteristic?
    private var companionCharacteristic: CBCharacteristic?
    private var hardwareStopCharacteristic: CBCharacteristic?
    private var companionStop = BluetoothCompanionStopState()
    private var companionStopPolling = BluetoothCompanionStopPolling()
    private var companionReadDeadline: Task<Void, Never>?
    private var companionUpdates = BluetoothCompanionUpdateQueue()
    private var companionTask: Task<Void, Never>?
    private var companionWriteDeadline: Task<Void, Never>?
    private var companionWriteToken: UUID?
    private var companionWritesDisabled = false
    private var requiresAuthentication = false
    private var challengeRequested = false
    private var handshake: BluetoothBoardHandshake?
    private var authenticatedSession: BluetoothBoardSession?
    private var pendingSequence: UInt32?
    private var releaseSequence: UInt32?
    private struct SentCommand { let requestID: UInt16; let opcode: UInt8 }
    private var authenticatedCommands: [UInt32: SentCommand] = [:]
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

    /// Optional display updates are coalesced and never queued as HID commands.
    /// Legacy C3 and authenticated S3 connections silently ignore this API.
    public func updateCompanionStatus(_ status: BluetoothCompanionStatus) {
        guard supportsCompanionDisplay, state == .ready, !companionWritesDisabled else { return }
        companionUpdates.update(status)
    }

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
    /// never a reason to retry. Read-only INFO/QUERY failures are BluetoothBoardError.
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
        if (1...6).contains(opcode) || opcode == 8 {
            guard !supportsCompanionDisplay || companionStop.isKnown else { throw BluetoothBoardError.boardBusy }
            guard !isHardwareStopLatched else { throw BluetoothBoardError.hardwareStopped }
        }
        let requestID = try reserveRequestID(for: peripheral.identifier)
        let token = UUID()
        let encoded = try encodeCommand(opcode: opcode, requestID: requestID, payload: payload)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                commandWaiter = continuation
                commandToken = token
                pendingID = requestID
                pendingOpcode = opcode
                pendingSequence = encoded.sequence
                if (1...6).contains(opcode) { inputMayBeHeld = true }
                commandDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(pairingHandshake ? 90 : 5)) } catch { return }
                    guard let self, commandToken == token else { return }
                    failWrittenCommand(.commandTimeout)
                }
                writeTokens.append(token)
                peripheral.writeValue(encoded.data, for: characteristic, type: .withResponse)
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
            let error: any Error = isReadOnly(pendingOpcode) ? BluetoothBoardError.busy : unknownDelivery(.deliveryUnknown)
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
                where candidate.name == "Eiscue BLE" || candidate.name == "Eiscue S3" {
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
        if isReadOnly(pendingOpcode) {
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

    private func isReadOnly(_ opcode: UInt8) -> Bool { opcode == 7 || opcode == 9 }

    private func encodeCommand(opcode: UInt8, requestID: UInt16, payload: [UInt8]) throws -> (data: Data, sequence: UInt32?) {
        let frame = BluetoothBoardProtocol.frame(opcode: opcode, requestID: requestID, payload: payload)
        guard requiresAuthentication else { return (frame, nil) }
        guard authenticatedSession != nil else { throw BluetoothBoardError.authenticationFailed }
        let signed = try authenticatedSession!.command(frame)
        authenticatedCommands[signed.sequence] = SentCommand(requestID: requestID, opcode: opcode)
        if authenticatedCommands.count > 32, let first = authenticatedCommands.keys.min() { authenticatedCommands.removeValue(forKey: first) }
        return (signed.data, signed.sequence)
    }

    private func decodeReply(_ data: Data) throws -> (bytes: [UInt8], sequence: UInt32?) {
        guard requiresAuthentication else {
            guard data.count == 8 else { throw BluetoothBoardError.malformedReply }
            return ([UInt8](data), nil)
        }
        let raw = [UInt8](data)
        guard raw.count == 44, let authenticatedSession else { throw BluetoothBoardError.authenticationFailed }
        let sequence = (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[8 + $1]) << ($1 * 8) }
        // Verify the MAC using its own sequence before matching an outstanding
        // request: a preempted command can legally acknowledge before STOP.
        let bytes = [UInt8](try authenticatedSession.reply(data, sequence: sequence))
        guard let sent = authenticatedCommands[sequence],
              sent.requestID == (UInt16(bytes[2]) | UInt16(bytes[3]) << 8),
              sent.opcode == bytes[1] else { throw BluetoothBoardError.authenticationFailed }
        return (bytes, sequence)
    }

    private func closeSession(connectError: any Error, commandError: (any Error)? = nil, finalState: State) {
        stopCompanionUpdates()
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
        let interrupted: any Error = isReadOnly(pendingOpcode) ? BluetoothBoardError.disconnected : unknownDelivery(.disconnected)
        finishCommand(.failure(commandError ?? interrupted))
        connectContinuation?.resume(throwing: connectError)
        // Cancelling custom GATT does not necessarily close the system HID link.
        // Send only a release, never replay the uncertain action. Hold this GATT
        // connection briefly for its ACK so queued key/button releases can leave.
        if inputMayBeHeld, central?.state == .poweredOn,
           let peripheral, peripheral.state == .connected,
           let characteristic = commandCharacteristic, responseCharacteristic?.isNotifying == true,
           let id = try? reserveRequestID(for: peripheral.identifier),
           let encoded = try? encodeCommand(opcode: 0, requestID: id, payload: []) {
            let token = UUID()
            closingState = finalState; releaseID = id; releaseToken = token; releaseSequence = encoded.sequence
            writeTokens.append(token)
            releaseDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, releaseID == id, let closingState else { return }
                tearDownSession(finalState: closingState)
            }
            peripheral.writeValue(encoded.data, for: characteristic, type: .withResponse)
            updateState(finalState)
            return
        }
        tearDownSession(finalState: finalState)
    }

    private func tearDownSession(finalState: State) {
        stopCompanionUpdates()
        releaseDeadline?.cancel(); releaseDeadline = nil
        releaseID = nil; releaseToken = nil; closingState = nil
        releaseSequence = nil; pendingSequence = nil
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.delegate = nil
        central = nil; peripheral = nil
        commandCharacteristic = nil; responseCharacteristic = nil; challengeCharacteristic = nil; proofCharacteristic = nil
        companionCharacteristic = nil; hardwareStopCharacteristic = nil; companionStop.beginConnection()
        companionWritesDisabled = false
        requiresAuthentication = false; challengeRequested = false; handshake = nil; authenticatedSession = nil
        authenticatedCommands.removeAll()
        candidates.removeAll(); writeTokens.removeAll()
        inputMayBeHeld = false
        updateState(finalState)
    }

    private func finishCommand(_ result: Result<Receipt, any Error>) {
        commandDeadline?.cancel(); commandDeadline = nil
        let waiter = commandWaiter
        commandWaiter = nil; commandToken = nil
        pendingSequence = nil
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
        peripheral.discoverCharacteristics([Self.commandID, Self.responseID, Self.challengeID, Self.proofID,
            Self.companionID, Self.hardwareStopID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard peripheral === self.peripheral, service.uuid == Self.serviceID else { return }
        guard error == nil,
              let command = service.characteristics?.first(where: { $0.uuid == Self.commandID }), command.properties.contains(.write),
              let response = service.characteristics?.first(where: { $0.uuid == Self.responseID }), response.properties.contains(.notify) else {
            failConnection(.missingCharacteristic); return
        }
        commandCharacteristic = command; responseCharacteristic = response
        let challenge = service.characteristics?.first { $0.uuid == Self.challengeID }
        let proof = service.characteristics?.first { $0.uuid == Self.proofID }
        guard (challenge == nil) == (proof == nil) else { failConnection(.authenticationFailed); return }
        if let challenge, let proof {
            guard challenge.properties.contains(.read), proof.properties.contains(.write), proof.properties.contains(.notify),
                  peripheral.maximumWriteValueLength(for: .withResponse) >= 52 else { failConnection(.authenticationFailed); return }
            requiresAuthentication = true; challengeCharacteristic = challenge; proofCharacteristic = proof
            peripheral.setNotifyValue(true, for: proof)
        } else {
            // This optional encrypted channel belongs to C3 only. Never add an
            // unauthenticated side channel to the S3 HMAC command connection.
            let companion = service.characteristics?.first { $0.uuid == Self.companionID }
            let stop = service.characteristics?.first { $0.uuid == Self.hardwareStopID }
            if companion != nil || stop != nil {
                guard let companion, let stop, companion.properties.contains(.write),
                      stop.properties.contains(.read), stop.properties.contains(.notify) else {
                    failConnection(.missingCharacteristic); return
                }
                companionCharacteristic = companion; hardwareStopCharacteristic = stop
                companionStop.beginConnection()
                peripheral.setNotifyValue(true, for: stop)
            }
        }
        peripheral.setNotifyValue(true, for: response)
        updateState(.subscribing)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        if peripheral === self.peripheral, characteristic === hardwareStopCharacteristic {
            guard closingState == nil else { return }
            guard error == nil, characteristic.isNotifying else { failConnection(.notificationFailed); return }
            readCompanionStopIfDue()
            return
        }
        guard peripheral === self.peripheral,
              characteristic === responseCharacteristic || characteristic === proofCharacteristic else { return }
        guard closingState == nil else { return }
        guard error == nil, characteristic.isNotifying else { failConnection(.notificationFailed); return }
        guard responseCharacteristic?.isNotifying == true else { return }
        if requiresAuthentication {
            guard proofCharacteristic?.isNotifying == true, let challengeCharacteristic else { return }
            guard !challengeRequested else { return }
            challengeRequested = true
            updateState(.authenticating)
            peripheral.readValue(for: challengeCharacteristic)
            return
        }
        finishConnection()
    }

    private func finishConnection() {
        guard connectWaiter != nil, responseCharacteristic?.isNotifying == true else { return }
        guard !supportsCompanionDisplay || companionStop.isKnown && hardwareStopCharacteristic?.isNotifying == true else { return }
        connectionDeadline?.cancel(); connectionDeadline = nil
        selectionTask?.cancel(); selectionTask = nil
        let waiter = connectWaiter
        connectWaiter = nil; connectToken = nil
        updateState(.ready)
        if state == .ready, supportsCompanionDisplay { startCompanionUpdates() }
        if state == .ready { waiter?.resume() }
        else { waiter?.resume(throwing: BluetoothBoardError.disconnected) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if peripheral === self.peripheral, characteristic === companionCharacteristic {
            guard companionWriteToken != nil else { return }
            companionWriteDeadline?.cancel(); companionWriteDeadline = nil; companionWriteToken = nil
            companionUpdates.acknowledge()
            if error != nil { companionWritesDisabled = true }
            return
        }
        if peripheral === self.peripheral, characteristic === proofCharacteristic {
            if error != nil, connectWaiter != nil { failConnection(.authenticationFailed) }
            return
        }
        guard peripheral === self.peripheral, characteristic === commandCharacteristic, !writeTokens.isEmpty else { return }
        let token = writeTokens.removeFirst()
        if token == releaseToken, error != nil, let closingState {
            tearDownSession(finalState: closingState); return
        }
        guard token == commandToken, error != nil else { return }
        failWrittenCommand(.gattWriteRejected)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        if characteristic === hardwareStopCharacteristic {
            guard closingState == nil else { return }
            guard error == nil, let data = characteristic.value else { failConnection(.malformedReply); return }
            do {
                let event = try companionStop.receive(data, boardID: peripheral.identifier)
                companionStopPolling.received()
                companionReadDeadline?.cancel(); companionReadDeadline = nil
                if companionStop.isLatched, commandWaiter != nil, !isReadOnly(pendingOpcode), pendingOpcode != 0 {
                    finishCommand(.failure(unknownDelivery(.hardwareStopped)))
                }
                if let event { onHardwareStop?(event) }
                finishConnection()
            } catch { failConnection(.malformedReply) }
            return
        }
        if characteristic === challengeCharacteristic {
            guard connectWaiter != nil, handshake == nil else { return }
            guard error == nil, let data = characteristic.value, let proofCharacteristic else { failConnection(.authenticationFailed); return }
            do {
                let challenge = try BluetoothBoardChallenge(data)
                let nonce = try BluetoothBoardKeyStore.random(count: 16)
                let proof = try BluetoothBoardKeyStore(boardID: challenge.boardID).handshake(for: challenge, clientNonce: nonce)
                handshake = proof
                peripheral.writeValue(proof.request, for: proofCharacteristic, type: .withResponse)
            } catch let failure as BluetoothBoardError { failConnection(failure) }
            catch { failConnection(.authenticationFailed) }
            return
        }
        if characteristic === proofCharacteristic {
            guard connectWaiter != nil, let handshake else { return }
            guard error == nil, let data = characteristic.value else { failConnection(.authenticationFailed); return }
            do {
                authenticatedSession = try handshake.accept(data)
                self.handshake = nil
                finishConnection()
            } catch let failure as BluetoothBoardError { failConnection(failure) }
            catch { failConnection(.authenticationFailed) }
            return
        }
        guard characteristic === responseCharacteristic else { return }
        guard error == nil, let data = characteristic.value else {
            if let closingState { tearDownSession(finalState: closingState) }
            else if commandWaiter != nil { failWrittenCommand(.malformedReply) }
            else { failConnection(.malformedReply) }
            return
        }
        let reply: (bytes: [UInt8], sequence: UInt32?)
        do { reply = try decodeReply(data) }
        catch let failure as BluetoothBoardError {
            if let closingState { tearDownSession(finalState: closingState) }
            else if commandWaiter != nil { failWrittenCommand(failure) }
            else { failConnection(failure) }
            return
        } catch { failConnection(.authenticationFailed); return }
        let bytes = reply.bytes, id = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        if let releaseID, let closingState {
            guard id == releaseID, reply.sequence == releaseSequence else { return }
            // This is best-effort cleanup; neither errors nor ACKs authorize input.
            tearDownSession(finalState: closingState)
            return
        }
        guard commandWaiter != nil else { return }
        guard id == pendingID, reply.sequence == pendingSequence else { return }
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

    private func startCompanionUpdates() {
        companionTask?.cancel()
        companionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled else { return }
                if let self {
                    readCompanionStopIfDue()
                    sendCompanionUpdateIfReady()
                } else { return }
            }
        }
    }

    private func sendCompanionUpdateIfReady() {
        guard state == .ready, closingState == nil, !companionWritesDisabled,
              let peripheral, peripheral.state == .connected, let companionCharacteristic,
              let packet = companionUpdates.takePacket(now: ProcessInfo.processInfo.systemUptime,
                  inputBusy: commandWaiter != nil || releaseToken != nil || connectWaiter != nil || companionStopPolling.pending != nil) else { return }
        let token = UUID(); companionWriteToken = token
        companionWriteDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, companionWriteToken == token else { return }
            // A late callback cannot be matched to a later write: no more
            // display writes are submitted until this connection is replaced.
            companionWriteToken = nil; companionWritesDisabled = true
        }
        peripheral.writeValue(packet, for: companionCharacteristic, type: .withResponse)
    }

    private func readCompanionStopIfDue() {
        guard closingState == nil, state == .ready || connectWaiter != nil,
              let peripheral, peripheral.state == .connected, let hardwareStopCharacteristic,
              hardwareStopCharacteristic.isNotifying,
              let read = companionStopPolling.begin(now: ProcessInfo.processInfo.systemUptime,
                  inputBusy: commandWaiter != nil || releaseToken != nil) else { return }
        companionReadDeadline?.cancel()
        companionReadDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, companionStopPolling.isExpired(read, now: ProcessInfo.processInfo.systemUptime) else { return }
            // Without fresh stop state the connection cannot remain usable.
            // closeSession marks any written input unknown and releases it.
            failConnection(.connectionFailed)
        }
        peripheral.readValue(for: hardwareStopCharacteristic)
    }

    private func stopCompanionUpdates() {
        companionTask?.cancel(); companionTask = nil
        companionReadDeadline?.cancel(); companionReadDeadline = nil; companionStopPolling.reset()
        companionWriteDeadline?.cancel(); companionWriteDeadline = nil; companionWriteToken = nil
        companionUpdates.reset()
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
