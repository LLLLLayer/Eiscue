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
    private func challenge(flags: UInt8 = 1) throws -> BluetoothBoardChallenge {
        try BluetoothBoardChallenge(Data([2, flags]) + Data(32..<64))
    }
    private func keyStore(_ store: BoardAuthMemoryStore) -> BluetoothBoardKeyStore {
        BluetoothBoardKeyStore(store: store, randomBytes: { [root] _ in root })
    }
    private func handshake(flags: UInt8 = 1) throws -> BluetoothBoardHandshake {
        try keyStore(BoardAuthMemoryStore(data: flags & 1 != 0 ? root : nil))
            .handshake(for: challenge(flags: flags), clientNonce: nonce)
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
        let changed = try keyStore(BoardAuthMemoryStore(data: root)).handshake(for:
            BluetoothBoardChallenge(Data([2, 1]) + Data(32..<48) + Data(48..<63) + Data([0])), clientNonce: nonce)
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

    @Test func legacyKeysAreMigratedAsConfirmedAndNeverReenrolled() throws {
        let memory = BoardAuthMemoryStore(data: root), store = keyStore(memory)
        #expect(throws: BluetoothBoardError.enrollmentConflict) {
            try store.handshake(for: challenge(flags: 2), clientNonce: nonce)
        }
        #expect(try memory.recordState() == "confirmed")
        let proof = try store.handshake(for: challenge(), clientNonce: nonce)
        #expect(proof.request[1] == 2)
        #expect(proof.request.suffix(32) != root)
        _ = try proof.accept(Data([2, 2, 0]) + hex("ac5635eb36ef08626577c576f294a63987ff3240eb9900f339a96306aab79e93"))
    }

    @Test func enrollmentIsSavedBeforeDisclosureAndConfirmedOnlyByServerProof() throws {
        let memory = BoardAuthMemoryStore(), store = keyStore(memory)
        let proof = try store.handshake(for: challenge(flags: 2), clientNonce: nonce)
        #expect(proof.request == Data([2, 1]) + nonce + root)
        #expect(try memory.recordState() == "enrollmentAttempted")
        #expect(throws: BluetoothBoardError.authenticationFailed) { try proof.accept(Data(repeating: 0, count: 35)) }
        #expect(try memory.recordState() == "enrollmentAttempted")
        #expect(throws: BluetoothBoardError.enrollmentConflict) {
            try keyStore(memory).handshake(for: challenge(flags: 2), clientNonce: nonce)
        }
        _ = try proof.accept(Data([2, 1, 0]) + hex("b265f10b6f27da2f22f62382d67a3e7b7db3d4c9d9c1087d4c7bb075add0afc6"))
        #expect(try memory.recordState() == "confirmed")
        #expect(throws: BluetoothBoardError.enrollmentConflict) {
            try keyStore(memory).handshake(for: challenge(flags: 2), clientNonce: nonce)
        }
    }

    @Test func lostEnrollmentReplyRecoversWithProofWithoutResendingRoot() throws {
        let memory = BoardAuthMemoryStore()
        _ = try keyStore(memory).handshake(for: challenge(flags: 2), clientNonce: nonce)
        // A new store instance models a process exit after the board saved the key.
        let resumed = try keyStore(memory).handshake(for: challenge(), clientNonce: nonce)
        #expect(resumed.request[1] == 2)
        #expect(resumed.request.suffix(32) != root)
        _ = try resumed.accept(Data([2, 2, 0]) + hex("ac5635eb36ef08626577c576f294a63987ff3240eb9900f339a96306aab79e93"))
        #expect(try memory.recordState() == "confirmed")
    }

    @Test func failedEnrollmentPersistenceNeverReturnsAnOutboundRequest() throws {
        let missing = BoardAuthMemoryStore(failWrites: [1])
        #expect(throws: BluetoothBoardError.counterStorageUnavailable) {
            try keyStore(missing).handshake(for: challenge(flags: 2), clientNonce: nonce)
        }
        #expect(try missing.load() == nil)
        let pending = BoardAuthMemoryStore(failWrites: [2])
        #expect(throws: BluetoothBoardError.counterStorageUnavailable) {
            try keyStore(pending).handshake(for: challenge(flags: 2), clientNonce: nonce)
        }
        #expect(try pending.recordState() == "candidate")
        let retry = try keyStore(pending).handshake(for: challenge(flags: 2), clientNonce: nonce)
        #expect(retry.request.suffix(32) == root)
        #expect(try pending.recordState() == "enrollmentAttempted")
    }

    @Test func failedConfirmationPersistenceDoesNotOpenSessionAndCanRecover() throws {
        let memory = BoardAuthMemoryStore(failWrites: [3])
        let proof = try keyStore(memory).handshake(for: challenge(flags: 2), clientNonce: nonce)
        #expect(throws: BluetoothBoardError.counterStorageUnavailable) {
            try proof.accept(Data([2, 1, 0]) + hex("b265f10b6f27da2f22f62382d67a3e7b7db3d4c9d9c1087d4c7bb075add0afc6"))
        }
        #expect(try memory.recordState() == "enrollmentAttempted")
        let resumed = try keyStore(memory).handshake(for: challenge(), clientNonce: nonce)
        _ = try resumed.accept(Data([2, 2, 0]) + hex("ac5635eb36ef08626577c576f294a63987ff3240eb9900f339a96306aab79e93"))
        #expect(try memory.recordState() == "confirmed")
    }

    @Test func missingOrInvalidStoredIdentityIsNeverSilentlyReplaced() throws {
        let missing = BoardAuthMemoryStore()
        #expect(throws: BluetoothBoardError.authenticationKeyUnavailable) {
            try keyStore(missing).handshake(for: challenge(), clientNonce: nonce)
        }
        #expect(try missing.load() == nil)
        let invalid = Data("{\"version\":2,\"state\":\"candidate\",\"key\":\"invalid\"}".utf8)
        let corrupted = BoardAuthMemoryStore(data: invalid)
        #expect(throws: BluetoothBoardError.authenticationKeyUnavailable) {
            try keyStore(corrupted).handshake(for: challenge(flags: 2), clientNonce: nonce)
        }
        #expect(try corrupted.load() == invalid)
        let replaced = BoardAuthMemoryStore()
        let proof = try keyStore(replaced).handshake(for: challenge(flags: 2), clientNonce: nonce)
        try replaced.save(Data(repeating: 99, count: 32))
        #expect(throws: BluetoothBoardError.authenticationKeyUnavailable) {
            try proof.accept(Data([2, 1, 0]) + hex("b265f10b6f27da2f22f62382d67a3e7b7db3d4c9d9c1087d4c7bb075add0afc6"))
        }
    }
}

private final class BoardAuthMemoryStore: PairingIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var writes = 0
    private let failWrites: Set<Int>
    init(data: Data? = nil, failWrites: Set<Int> = []) { self.data = data; self.failWrites = failWrites }
    func load() throws -> Data? { lock.withLock { data } }
    func save(_ data: Data) throws {
        try lock.withLock {
            writes += 1
            if failWrites.contains(writes) { throw DeviceControlError.keychain(-1) }
            self.data = data
        }
    }
    func remove() throws { lock.withLock { data = nil } }
    func recordState() throws -> String? {
        guard let data = try load() else { return nil }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["state"] as? String
    }
}
