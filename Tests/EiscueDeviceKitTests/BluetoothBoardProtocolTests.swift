import Foundation
import Testing
@testable import EiscueDeviceKit

@Suite struct BluetoothBoardProtocolTests {
    @Test func outputSelectionIsRestrictedAndCannotSmuggleInput() {
        #expect(BluetoothBoardProtocol.payloadIsValid(opcode: 8, payload: [0]))
        #expect(BluetoothBoardProtocol.payloadIsValid(opcode: 8, payload: [1]))
        #expect(!BluetoothBoardProtocol.payloadIsValid(opcode: 8, payload: [2]))
        #expect(!BluetoothBoardProtocol.payloadIsValid(opcode: 8, payload: [1, 1]))
        #expect(BluetoothBoardProtocol.payloadIsValid(opcode: 9, payload: []))
        #expect(!BluetoothBoardProtocol.payloadIsValid(opcode: 9, payload: [1]))
    }

    @Test func keyboardNavigationDoesNotExposeArbitraryCombinations() {
        for key: UInt8 in [0x0B, 0x19, 0x2C] {
            #expect(BluetoothBoardProtocol.payloadIsValid(opcode: 6, payload: [0x08, key]))
        }
        #expect(!BluetoothBoardProtocol.payloadIsValid(opcode: 6, payload: [0x01, 0x2C]))
        #expect(!BluetoothBoardProtocol.payloadIsValid(opcode: 6, payload: [0x08, 0x2B]))
        #expect(!BluetoothBoardProtocol.payloadIsValid(opcode: 6, payload: [0x08, 0x2C, 1]))
    }

    @Test func outputMetadataRejectsUnsupportedUSBAndReservedFlags() throws {
        let usb = try BluetoothBoardOutputInfo(bits: 0x1F)
        #expect(usb.selectedRoute == .usb && usb.supportsUSB && usb.isUSBConnected && usb.isS3 && usb.supportsNavigation)
        let c3 = try BluetoothBoardOutputInfo(bits: 0x10)
        #expect(c3.selectedRoute == .bluetooth && !c3.supportsUSB && !c3.isS3 && c3.supportsNavigation)
        for bits: UInt8 in [1, 4, 0x20, 0x80] {
            #expect(throws: BluetoothBoardError.malformedReply) { try BluetoothBoardOutputInfo(bits: bits) }
        }
    }
}
