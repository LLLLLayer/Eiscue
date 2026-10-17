#if DEBUG
import EiscueDeviceCore
import Foundation
import CoreBluetooth

/// The harmless UIKit fixture uses the same authenticated transport as normal
/// tasks. Receipts remain transport evidence, never proof of observed input.
@MainActor final class BLEBoardCheckClient {
    enum Failure: String, Error {
        case bluetoothUnavailable, bluetoothDenied, ambiguousBoard, connectionFailed
        case discoveryTimeout, missingService, missingCharacteristic, notificationFailed
        case disconnected, busy, commandTimeout, gattWriteRejected, malformedReply
        case invalidCommand, notEncrypted, boardBusy, hidNotSubscribed, hidSendFailed, cancelled
        case counterStorageUnavailable, deliveryUnknown
        case authenticationFailed, authenticationKeyUnavailable, enrollmentClosed
    }
    typealias Receipt = BluetoothBoardClient.Receipt
    static let serviceID = CBUUID(string: "74074E9A-41E8-4E84-951D-70E623643AB3")
    var onStage: ((String) -> Void)?
    private let client = BluetoothBoardClient()

    init() {
        client.onStateChange = { [weak self] state in
            let stage: String = switch state {
            case .idle: "idle"
            case .waitingForBluetooth: "waiting_for_bluetooth"
            case .scanning: "scanning"
            case .connecting: "connecting"
            case .discovering: "discovering_gatt"
            case .subscribing: "subscribing_response"
            case .authenticating: "authenticating"
            case .ready: "gatt_ready"
            case .disconnected: "disconnected"
            case .failed(let failure): "failed." + failure.rawValue
            }
            self?.onStage?(stage)
        }
    }

    func connect() async throws {
        do {
            try await client.connect()
            let info = try await client.command(opcode: 7, pairingHandshake: true)
            let usb = ProcessInfo.processInfo.arguments.contains("--ble-usb-input")
            if info.emittedReports & 0x80 != 0 {
                let output = try await client.command(opcode: 9)
                guard output.emittedReports & 0x0A == 0 || client.usesAuthenticatedCommands else { throw Failure.authenticationFailed }
                if usb {
                    guard output.emittedReports & 2 != 0 else { throw Failure.invalidCommand }
                }
                _ = try await client.command(opcode: 8, payload: [usb ? 1 : 0])
                if usb {
                    let deadline = Date().addingTimeInterval(15)
                    while true {
                        let ready = try await client.command(opcode: 7)
                        if ready.emittedReports & 3 == 3 { break }
                        guard Date() < deadline else { throw Failure.hidNotSubscribed }
                        try await Task.sleep(for: .milliseconds(300))
                    }
                }
            } else if usb { throw Failure.invalidCommand }
        } catch {
            client.disconnect()
            throw mapped(error)
        }
    }

    func command(_ opcode: UInt8, payload: [UInt8] = [], pairingHandshake: Bool = false) async throws -> Receipt {
        do { return try await client.command(opcode: opcode, payload: payload, pairingHandshake: pairingHandshake) }
        catch { throw mapped(error) }
    }
    func move(dx: Int16, dy: Int16) async throws -> Receipt {
        do { return try await client.move(dx: dx, dy: dy) }
        catch { throw mapped(error) }
    }
    func disconnect() { client.disconnect() }

    private func mapped(_ error: any Error) -> any Error {
        if error is CancellationError { return Failure.cancelled }
        if let error = error as? BluetoothBoardError { return Failure(rawValue: error.rawValue) ?? .connectionFailed }
        if let error = error as? DeviceControlError, error.isDeliveryUnknown { return Failure.deliveryUnknown }
        return error
    }
}
#endif
