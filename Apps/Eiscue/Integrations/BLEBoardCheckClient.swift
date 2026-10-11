#if DEBUG
import Foundation
@preconcurrency import CoreBluetooth

/// Original, deliberately small implementation of the BLE board protocol v1.
/// It has no dependency on the network/CoreDevice/XCTest control backends.
@MainActor final class BLEBoardCheckClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum Failure: String, Error {
        case bluetoothUnavailable, bluetoothDenied, ambiguousBoard, connectionFailed
        case discoveryTimeout, missingService, missingCharacteristic, notificationFailed
        case disconnected, busy, commandTimeout, gattWriteRejected, malformedReply
        case invalidCommand, notEncrypted, boardBusy, hidNotSubscribed, hidSendFailed, cancelled
        case counterStorageUnavailable
    }
    struct Receipt {
        let opcode: UInt8
        let requestID: UInt16
        let emittedReports: UInt8
        let encrypted: Bool
    }
    static let serviceID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB3")
    private static let commandID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB4")
    private static let responseID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB5")
    var onStage: ((String) -> Void)?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var commandWaiter: CheckedContinuation<Receipt, Error>?
    private var pendingID: UInt16 = 0
    private var pendingOpcode: UInt8 = 0
    private var connectionDeadline: Task<Void, Never>?
    private var commandDeadline: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var candidates: [UUID: CBPeripheral] = [:]

    override init() {
        super.init()
        // No restoration or background mode: this fixture must remain visible.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func connect() async throws {
        guard connectWaiter == nil, peripheral == nil else { throw Failure.busy }
        try await withCheckedThrowingContinuation { continuation in
            connectWaiter = continuation
            connectionDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(90)) } catch { return }
                self?.failConnection(.discoveryTimeout)
            }
            advancePoweredState()
        }
    }

    /// ACK means that the board emitted reports, never that UIKit received input.
    func command(_ opcode: UInt8, payload: [UInt8] = [], pairingHandshake: Bool = false) async throws -> Receipt {
        try Task.checkCancellation()
        guard commandWaiter == nil else { throw Failure.busy }
        guard payload.count <= 12, opcode <= 4 else { throw Failure.invalidCommand }
        guard let peripheral, peripheral.state == .connected,
              let characteristic = commandCharacteristic,
              responseCharacteristic?.isNotifying == true else { throw Failure.disconnected }
        // System HID can keep the physical link alive after this App disconnects
        // or restarts. Reserve durably before writing; never restart its sequence.
        pendingID = try reserveRequestID(for: peripheral.identifier)
        pendingOpcode = opcode
        var bytes: [UInt8] = [1, opcode, UInt8(truncatingIfNeeded: pendingID), UInt8(pendingID >> 8)]
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: repeatElement(0, count: 16 - bytes.count))
        return try await withCheckedThrowingContinuation { continuation in
            commandWaiter = continuation
            commandDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(pairingHandshake ? 90 : 5)) } catch { return }
                self?.finishCommand(.failure(Failure.commandTimeout))
            }
            peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
        }
    }

    func move(dx: Int16, dy: Int16) async throws -> Receipt {
        guard abs(Int(dx)) <= 127, abs(Int(dy)) <= 127 else { throw Failure.invalidCommand }
        return try await command(1, payload: [UInt8(truncatingIfNeeded: dx), UInt8(truncatingIfNeeded: dx >> 8),
                                             UInt8(truncatingIfNeeded: dy), UInt8(truncatingIfNeeded: dy >> 8), 0])
    }

    /// MainActor serialization covers concurrent fixture windows. The file holds
    /// only opaque CoreBluetooth identifiers and counters, never commands/keys.
    /// A failed/corrupt/protected store refuses input rather than resetting IDs.
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
            // Skipping zero at wrap advances by two, inside the firmware's
            // accepted half-range; first requests on a new physical link accept
            // any value, so reconnects need no special reset.
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
        } catch { throw Failure.counterStorageUnavailable }
    }

    func disconnect() {
        connectionDeadline?.cancel(); selectionTask?.cancel(); central.stopScan()
        let waiter = connectWaiter; connectWaiter = nil
        waiter?.resume(throwing: Failure.cancelled)
        finishCommand(.failure(Failure.cancelled))
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil; commandCharacteristic = nil; responseCharacteristic = nil
    }

    private func advancePoweredState() {
        guard connectWaiter != nil else { return }
        switch central.state {
        case .poweredOn:
            guard peripheral == nil, !central.isScanning else { return }
            onStage?("scanning")
            candidates = Dictionary(uniqueKeysWithValues: central.retrieveConnectedPeripherals(withServices: [Self.serviceID]).map { ($0.identifier, $0) })
            // iOS may have already connected HID through Settings and stopped
            // advertising. Only this board's exact name is eligible from 1812;
            // its custom service still has to pass discovery before any command.
            for candidate in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812")])
                where candidate.name == "Eiscue BLE" {
                candidates[candidate.identifier] = candidate
            }
            central.scanForPeripherals(withServices: [Self.serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            if !candidates.isEmpty { scheduleSelection() }
        case .unauthorized: failConnection(.bluetoothDenied)
        case .unsupported, .poweredOff: failConnection(.bluetoothUnavailable)
        case .unknown, .resetting: onStage?("waiting_for_bluetooth")
        @unknown default: failConnection(.bluetoothUnavailable)
        }
    }

    private func scheduleSelection() {
        guard selectionTask == nil else { return }
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self, connectWaiter != nil else { return }
            central.stopScan()
            guard candidates.count == 1, let candidate = candidates.values.first else {
                failConnection(.ambiguousBoard); return
            }
            peripheral = candidate; candidate.delegate = self
            onStage?("connecting")
            central.connect(candidate)
        }
    }

    private func failConnection(_ error: Failure) {
        connectionDeadline?.cancel(); selectionTask?.cancel(); central.stopScan()
        let waiter = connectWaiter; connectWaiter = nil
        waiter?.resume(throwing: error)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
    }

    private func finishCommand(_ result: Result<Receipt, Error>) {
        commandDeadline?.cancel()
        let waiter = commandWaiter; commandWaiter = nil
        waiter?.resume(with: result)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { advancePoweredState() }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connectWaiter != nil, self.peripheral == nil else { return }
        candidates[peripheral.identifier] = peripheral
        scheduleSelection()
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        onStage?("discovering_gatt")
        peripheral.discoverServices([Self.serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        failConnection(.connectionFailed)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        self.peripheral = nil; commandCharacteristic = nil; responseCharacteristic = nil
        if connectWaiter != nil { failConnection(.disconnected) }
        finishCommand(.failure(Failure.disconnected))
        onStage?("disconnected")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            failConnection(.missingService); return
        }
        peripheral.discoverCharacteristics([Self.commandID, Self.responseID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil,
              let command = service.characteristics?.first(where: { $0.uuid == Self.commandID }), command.properties.contains(.write),
              let response = service.characteristics?.first(where: { $0.uuid == Self.responseID }), response.properties.contains(.notify) else {
            failConnection(.missingCharacteristic); return
        }
        commandCharacteristic = command; responseCharacteristic = response
        onStage?("subscribing_response")
        peripheral.setNotifyValue(true, for: response)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.responseID else { return }
        guard error == nil, characteristic.isNotifying else { failConnection(.notificationFailed); return }
        connectionDeadline?.cancel()
        let waiter = connectWaiter; connectWaiter = nil
        onStage?("gatt_ready")
        waiter?.resume()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.commandID, error != nil else { return }
        finishCommand(.failure(Failure.gattWriteRejected))
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.responseID, commandWaiter != nil else { return }
        guard error == nil, let data = characteristic.value, data.count == 8 else {
            finishCommand(.failure(Failure.malformedReply)); return
        }
        let b = [UInt8](data), id = UInt16(b[2]) | UInt16(b[3]) << 8
        // Ignore an old report rather than attributing it to the next command.
        guard id == pendingID else { return }
        guard b[0] == 1, b[1] == pendingOpcode, b[6] <= 1, b[7] == 0, b[4] <= 5 else {
            finishCommand(.failure(Failure.malformedReply)); return
        }
        let failures: [Failure] = [.invalidCommand, .notEncrypted, .boardBusy, .hidNotSubscribed, .hidSendFailed]
        guard b[4] == 0 else { finishCommand(.failure(failures[Int(b[4]) - 1])); return }
        guard b[6] == 1 else { finishCommand(.failure(Failure.notEncrypted)); return }
        finishCommand(.success(Receipt(opcode: b[1], requestID: id, emittedReports: b[5], encrypted: true)))
    }
}
#endif
