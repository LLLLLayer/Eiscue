import CryptoKit
import Foundation
import Security

/// Per-connection authentication. Root keys never leave the Keychain except for
/// first enrollment on an unconfigured board in its physical setup window.
struct BluetoothBoardChallenge: Sendable {
    let hasKey: Bool
    let allowsEnrollment: Bool
    let boardID: Data
    let nonce: Data

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count == 34, bytes[0] == 2, bytes[1] & 0xFC == 0 else { throw BluetoothBoardError.authenticationFailed }
        hasKey = bytes[1] & 1 != 0; allowsEnrollment = bytes[1] & 2 != 0
        boardID = Data(bytes[2..<18]); nonce = Data(bytes[18..<34])
    }
}

struct BluetoothBoardHandshake: Sendable {
    let request: Data
    private let operation: UInt8
    private let key: Data
    private let context: Data
    private let keyStore: BluetoothBoardKeyStore

    fileprivate init(challenge: BluetoothBoardChallenge, key: Data, clientNonce: Data, keyStore: BluetoothBoardKeyStore) throws {
        guard key.count == 32, clientNonce.count == 16 else { throw BluetoothBoardError.authenticationFailed }
        guard challenge.hasKey || challenge.allowsEnrollment else { throw BluetoothBoardError.enrollmentClosed }
        self.key = key; self.keyStore = keyStore; context = challenge.boardID + challenge.nonce + clientNonce
        operation = challenge.hasKey ? 2 : 1
        let payload = challenge.hasKey ? Self.mac(key, "EiscueBLE/v2/client", context) : key
        request = Data([2, operation]) + clientNonce + payload
    }

    func accept(_ response: Data) throws -> BluetoothBoardSession {
        let bytes = [UInt8](response)
        guard bytes.count == 35, bytes[0] == 2, bytes[1] == operation,
              Self.validMAC(key, "EiscueBLE/v2/server", context + Data(bytes[0..<3]), Data(bytes[3..<35])),
              bytes[2] == 0 else { throw BluetoothBoardError.authenticationFailed }
        try keyStore.confirm(key)
        return BluetoothBoardSession(key: Self.mac(key, "EiscueBLE/v2/session", context))
    }

    fileprivate static func mac(_ key: Data, _ domain: String, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(domain.utf8) + data, using: SymmetricKey(data: key)))
    }
    fileprivate static func validMAC(_ key: Data, _ domain: String, _ data: Data, _ tag: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: Data(domain.utf8) + data, using: SymmetricKey(data: key))
    }
}

struct BluetoothBoardSession: Sendable {
    private let key: Data
    private var sequence: UInt32 = 0
    init(key: Data) { self.key = key }

    mutating func command(_ frame: Data) throws -> (data: Data, sequence: UInt32) {
        guard frame.count == 16, frame.first == 1, sequence < .max else { throw BluetoothBoardError.authenticationFailed }
        sequence += 1
        var bytes = [UInt8](frame); bytes[0] = 2
        let body = Data(bytes) + Self.littleEndian(sequence)
        return (body + BluetoothBoardHandshake.mac(key, "EiscueBLE/v2/cmd", body), sequence)
    }
    func reply(_ data: Data, sequence: UInt32) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count == 44, bytes[0] == 2,
              Data(bytes[8..<12]) == Self.littleEndian(sequence),
              BluetoothBoardHandshake.validMAC(key, "EiscueBLE/v2/reply", Data(bytes[0..<12]), Data(bytes[12..<44])) else {
            throw BluetoothBoardError.authenticationFailed
        }
        var reply = Array(bytes[0..<8]); reply[0] = 1
        return Data(reply)
    }
    private static func littleEndian(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}

struct BluetoothBoardKeyStore: Sendable {
    private enum State: String, Codable { case candidate, enrollmentAttempted, confirmed }
    private struct Record: Codable {
        let version: Int
        var state: State
        let key: Data
        init(state: State, key: Data) { version = 1; self.state = state; self.key = key }
    }
    private let store: any PairingIdentityStore
    private let randomBytes: @Sendable (Int) throws -> Data
    init(boardID: Data) {
        self.init(store: KeychainPairingIdentityStore(service: "org.eiscue.device.board-auth",
            account: boardID.map { String(format: "%02x", $0) }.joined()))
    }
    init(store: any PairingIdentityStore, randomBytes: @escaping @Sendable (Int) throws -> Data = Self.random) {
        self.store = store; self.randomBytes = randomBytes
    }

    func handshake(for challenge: BluetoothBoardChallenge, clientNonce: Data) throws -> BluetoothBoardHandshake {
        guard clientNonce.count == 16 else { throw BluetoothBoardError.authenticationFailed }
        do {
            var record: Record
            if let existing = try load() {
                record = existing
            } else {
                guard !challenge.hasKey else { throw BluetoothBoardError.authenticationKeyUnavailable }
                guard challenge.allowsEnrollment else { throw BluetoothBoardError.enrollmentClosed }
                let key = try randomBytes(32)
                guard key.count == 32 else { throw BluetoothBoardError.authenticationFailed }
                record = Record(state: .candidate, key: key)
                try save(record)
            }
            if !challenge.hasKey {
                // A lost proof can mean the board already saved the key. Its
                // unauthenticated "unclaimed" flag must never disclose it again.
                guard record.state == .candidate else { throw BluetoothBoardError.enrollmentConflict }
                guard challenge.allowsEnrollment else { throw BluetoothBoardError.enrollmentClosed }
                record.state = .enrollmentAttempted
                try save(record)
            }
            return try BluetoothBoardHandshake(challenge: challenge, key: record.key, clientNonce: clientNonce, keyStore: self)
        } catch let error as BluetoothBoardError { throw error }
        catch { throw BluetoothBoardError.counterStorageUnavailable }
    }

    fileprivate func confirm(_ key: Data) throws {
        do {
            guard var record = try load(), record.key == key else { throw BluetoothBoardError.authenticationKeyUnavailable }
            if record.state != .confirmed { record.state = .confirmed; try save(record) }
        } catch let error as BluetoothBoardError { throw error }
        catch { throw BluetoothBoardError.counterStorageUnavailable }
    }

    private func load() throws -> Record? {
        guard let data = try store.load() else { return nil }
        if data.count == 32 {
            // Legacy storage did not distinguish attempted and completed setup.
            // Treat every old key as established, including lost-proof cases.
            let record = Record(state: .confirmed, key: data)
            try save(record)
            return record
        }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.key.count == 32 else { throw BluetoothBoardError.authenticationKeyUnavailable }
        return record
    }

    private func save(_ record: Record) throws { try store.save(JSONEncoder().encode(record)) }

    static func random(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BluetoothBoardError.authenticationFailed }
        return Data(bytes)
    }
}
