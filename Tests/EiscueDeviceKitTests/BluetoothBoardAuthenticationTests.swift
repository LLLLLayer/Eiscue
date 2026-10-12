import Foundation
import Testing
@testable import EiscueDeviceKit

@Suite struct BluetoothBoardAuthenticationTests {
    private let root = Data(0..<32)
    private let nonce = Data(64..<80)
    private func hex(_ value: String) -> Data {
        Data(stride(from: 0, to: value.count, by: 2).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    private func handshake(flags: UInt8 = 1) throws -> BluetoothBoardHandshake {
        try BluetoothBoardHandshake(challenge: BluetoothBoardChallenge(Data([2, flags]) + Data(32..<64)), key: root, clientNonce: nonce)
    }

    @Test func swiftAndFirmwareShareAuthenticationAndCommandVectors() throws {
        let proof = try handshake()
        #expect(proof.request == Data([2, 2]) + nonce + hex("874fadbd6da150c89a5b73eb32b44458e195acde1218d7c0901b307e9cda9e12"))
        var session = try proof.accept(Data([2, 2, 0]) + hex("ac5635eb36ef08626577c576f294a63987ff3240eb9900f339a96306aab79e93"))
        let command = try session.command(BluetoothBoardProtocol.frame(opcode: 7, requestID: 1, payload: []))
        #expect(command.sequence == 1)
        #expect(command.data.suffix(32) == hex("47769a48f7da2b455345bb77d5aeced911ae91aad6f9ca1cde95053c562f09c0"))
        let reply = Data([2, 7, 1, 0, 0, 3, 1, 0, 1, 0, 0, 0]) + hex("a2a11a5e295d712e43cb4628a86b8645e820fc4fdfb85dc69f75e042ec5c7251")
        #expect(try session.reply(reply, sequence: 1) == Data([1, 7, 1, 0, 0, 3, 1, 0]))
        #expect(throws: BluetoothBoardError.authenticationFailed) { try session.reply(reply, sequence: 2) }
        var tampered = reply; tampered[5] ^= 1
        #expect(throws: BluetoothBoardError.authenticationFailed) { try session.reply(tampered, sequence: 1) }
    }

    @Test func serverProofCannotAuthorizeAnotherConnectionOrUnsignedReply() throws {
        let proof = try handshake(), reply = Data([2, 2, 0]) + hex("ac5635eb36ef08626577c576f294a63987ff3240eb9900f339a96306aab79e93")
        let session = try proof.accept(reply)
        #expect(throws: BluetoothBoardError.authenticationFailed) { try session.reply(Data([1, 7, 1, 0, 0, 3, 1, 0]), sequence: 1) }
        let changed = try BluetoothBoardHandshake(challenge: BluetoothBoardChallenge(Data([2, 1]) + Data(32..<48) + Data(48..<63) + Data([0])), key: root, clientNonce: nonce)
        #expect(throws: BluetoothBoardError.authenticationFailed) { try changed.accept(reply) }
        var tampered = reply; tampered[34] ^= 1
        #expect(throws: BluetoothBoardError.authenticationFailed) { try proof.accept(tampered) }
    }

    @Test func enrollmentRequiresPhysicalWindowAndVerifiableServerProof() throws {
        #expect(throws: BluetoothBoardError.enrollmentClosed) { try handshake(flags: 0) }
        let enrollment = try handshake(flags: 2)
        #expect(enrollment.request == Data([2, 1]) + nonce + root)
        _ = try enrollment.accept(Data([2, 1, 0]) + hex("b265f10b6f27da2f22f62382d67a3e7b7db3d4c9d9c1087d4c7bb075add0afc6"))
        #expect(throws: BluetoothBoardError.authenticationFailed) { try BluetoothBoardChallenge(Data([2, 4]) + Data(32..<64)) }
    }
}
