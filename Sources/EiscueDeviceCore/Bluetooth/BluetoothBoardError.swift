import Foundation

/// Errors that occur before input, or explain why a sent command's delivery is unknown.
public enum BluetoothBoardError: String, Error, LocalizedError, Sendable, Equatable {
    case bluetoothUnavailable, bluetoothDenied, ambiguousBoard, connectionFailed
    case discoveryTimeout, missingService, missingCharacteristic, notificationFailed
    case disconnected, busy, commandTimeout, gattWriteRejected, malformedReply
    case invalidCommand, notEncrypted, boardBusy, hidNotSubscribed, hidSendFailed
    case counterStorageUnavailable, deliveryUnknown
    case authenticationFailed, authenticationKeyUnavailable, enrollmentClosed, enrollmentConflict
    case hardwareStopped

    public var errorDescription: String? {
        let key: String
        switch self {
        case .bluetoothUnavailable: key = "bluetooth.unavailable"
        case .bluetoothDenied: key = "bluetooth.denied"
        case .ambiguousBoard: key = "bluetooth.multiple-boards"
        case .discoveryTimeout: key = "bluetooth.not-found"
        case .missingService, .missingCharacteristic: key = "bluetooth.firmware-required"
        case .connectionFailed, .notificationFailed, .disconnected: key = "bluetooth.disconnected"
        case .busy, .boardBusy: key = "bluetooth.busy"
        case .commandTimeout: key = "bluetooth.timed-out"
        case .gattWriteRejected, .malformedReply, .hidSendFailed, .deliveryUnknown: key = "bluetooth.delivery-unknown"
        case .invalidCommand: key = "bluetooth.invalid-command"
        case .notEncrypted: key = "bluetooth.pairing-required"
        case .hidNotSubscribed: key = "bluetooth.input-unavailable"
        case .counterStorageUnavailable: key = "bluetooth.storage-unavailable"
        case .authenticationFailed: key = "bluetooth.authentication-failed"
        case .authenticationKeyUnavailable: key = "bluetooth.authentication-key-unavailable"
        case .enrollmentClosed: key = "bluetooth.enrollment-closed"
        case .enrollmentConflict: key = "bluetooth.enrollment-conflict"
        case .hardwareStopped: key = "bluetooth.hardware-stopped"
        }
        return NSLocalizedString(key, tableName: "BluetoothBoard", bundle: .module, comment: "Bluetooth board connection error")
    }
}

public extension BluetoothBoardError {
    var deviceControlError: DeviceControlError {
        switch self {
        case .disconnected, .connectionFailed, .bluetoothUnavailable, .bluetoothDenied, .authenticationFailed: .connectionLost
        case .busy, .boardBusy: .busy
        case .deliveryUnknown, .gattWriteRejected, .malformedReply, .hidSendFailed: .deliveryUnknown("")
        case .hidNotSubscribed, .hardwareStopped: .serviceUnavailable(.input)
        default: .serviceUnavailable(.bluetooth)
        }
    }
}
