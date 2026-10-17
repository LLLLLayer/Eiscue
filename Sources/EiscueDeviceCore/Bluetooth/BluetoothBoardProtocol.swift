import Foundation

/// Both routes use Bluetooth commands and ReplayKit observation. USB changes
/// only the board's HID output; it does not use the developer-service USB route.
public enum BluetoothBoardInputRoute: String, Codable, Sendable, CaseIterable {
    case bluetooth
    case usb

    var commandValue: UInt8 { self == .usb ? 1 : 0 }
}

public struct BluetoothBoardOutputInfo: Sendable, Equatable {
    public let selectedRoute: BluetoothBoardInputRoute
    public let supportsUSB: Bool
    public let isUSBConnected: Bool
    public let isS3: Bool
    public let supportsNavigation: Bool

    init(bits: UInt8) throws {
        guard bits & 0xE0 == 0 else { throw BluetoothBoardError.malformedReply }
        selectedRoute = bits & 1 != 0 ? .usb : .bluetooth
        supportsUSB = bits & 2 != 0
        isUSBConnected = bits & 4 != 0
        isS3 = bits & 8 != 0
        supportsNavigation = bits & 16 != 0
        guard selectedRoute != .usb || supportsUSB,
              !isUSBConnected || supportsUSB else { throw BluetoothBoardError.malformedReply }
    }
}

/// Firmware protocol v1. Validate before reserving an ID or writing any bytes.
enum BluetoothBoardProtocol {
    static let outputSelectionFlag: UInt8 = 0x80

    static func payloadIsValid(opcode: UInt8, payload: [UInt8]) -> Bool {
        guard payload.count <= 12 else { return false }
        let bytes = payload + Array(repeating: 0, count: 12 - payload.count)
        func zeroTail(_ first: Int) -> Bool { bytes[first...].allSatisfy { $0 == 0 } }
        switch opcode {
        case 0: return zeroTail(0)
        case 1:
            let dx = Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
            let dy = Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
            return abs(Int(dx)) <= 127 && abs(Int(dy)) <= 127 && bytes[4] != 128 && zeroTail(5)
        case 2: return [1, 2, 4].contains(bytes[0]) && bytes[1] == 1 && zeroTail(2)
        case 3: return ((32...126).contains(bytes[0]) || [9, 10, 13].contains(bytes[0])) && zeroTail(1)
        case 4: return (1...6).contains(bytes[0]) && zeroTail(1)
        case 5:
            let x = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
            let y = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
            return x <= 32767 && y <= 32767 && bytes[4] <= 1 && zeroTail(5)
        case 6: return bytes[0] == 0x08 && [0x0B, 0x19, 0x2C].contains(bytes[1]) && zeroTail(2)
        case 7, 9: return zeroTail(0)
        case 8: return bytes[0] <= 1 && zeroTail(1)
        default: return false
        }
    }

    static func frame(opcode: UInt8, requestID: UInt16, payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [1, opcode, UInt8(truncatingIfNeeded: requestID), UInt8(requestID >> 8)]
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: repeatElement(0, count: 16 - bytes.count))
        return Data(bytes)
    }
}
