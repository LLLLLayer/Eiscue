// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CEiscueDeviceBackend
import OSLog

private let pairingLogger = Logger(subsystem: "org.eiscue.device", category: "connection")

/// Versioned app-owned record. Never interpolated into logs or user messages.
public struct RemotePairRecord: Codable {
    public let version: Int
    public let seed: [UInt8]
    public let controllerID: String
    public let peerID: String
    public let peerPublicKey: [UInt8]
    public let alternateIRK: [UInt8]
    public let peerUDID: String
    public let peerModel: String
    public let committed: Bool
    public func identity() throws -> AuthorizedRemoteIdentity {
        guard version == 1 else { throw NativeBackendError.invalidIdentity }
        return try AuthorizedRemoteIdentity(signingSeed: Data(seed), controllerID: controllerID,
            peerID: peerID, peerPublicKey: Data(peerPublicKey), alternateIRK: Data(alternateIRK), peerUDID: peerUDID, peerModel: peerModel)
    }
}
public struct PairingAdvertisement: Decodable {
    public let port: UInt16
    public let identifier: String
    public let txt: [String: String]
}
public enum PairingUpdate {
    case listening(PairingAdvertisement), code(String), persisted(committed: Bool), completed
}
@MainActor public final class RemotePairingSession {
    private var handle: UInt64 = 0
    public init() {}
    deinit { if handle != 0 { ncm_backend_close(handle) } }
    public func close() { let old = handle; handle = 0; if old != 0 { ncm_backend_close(old) } }
    /// Storage is caller-owned. Persistence errors cancel before protocol acknowledgement.
    public func pair(authorized: Bool, persist: (RemotePairRecord) throws -> Void,
                     update: (PairingUpdate) throws -> Void) async throws {
        var diagnosticStage = 0, diagnosticFinished = false
        let diagnosticStart = ContinuousClock.now
        defer {
            if !diagnosticFinished {
                pairingLogger.error("pairing stage=7 previous=\(diagnosticStage, privacy: .public)")
                logStage(7)
            }
        }
        func logStage(_ stage: Int) {
            let previousStage = diagnosticStage
            diagnosticStage = stage
            pairingLogger.notice("pairing stage=\(stage, privacy: .public)")
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--pairing-diagnostics") {
                let elapsed = diagnosticStart.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let report: [String: Any] = ["stage": stage, "previousStage": previousStage, "elapsedSeconds": seconds]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    try? data.write(to: URL.cachesDirectory.appendingPathComponent("EiscuePairingDiagnostic.json"), options: [.atomic, .completeFileProtection])
                }
            }
            #endif
        }
        logStage(-1)
        guard authorized else { throw NativeBackendError.authorizationRequired }
        guard handle == 0 else { throw NativeBackendError.busy }
        try Task.checkCancellation()
        var token: UInt64 = 0
        let status = ncm_pairing_start(1, &token)
        guard status == 0, token != 0 else { throw NativeBackendError.transport(code: status) }
        handle = token; defer { if handle == token { close() } }
        let expires = ContinuousClock.now.advanced(by: .seconds(185))
        repeat {
            try Task.checkCancellation()
            guard token == handle else { throw NativeBackendError.closed }
            guard var message = try NativeEventReader.poll(limit: 32 * 1024, read: {
                ncm_backend_poll(token, $0, $1, $2)
            }) else {
                try await Task.sleep(for: .milliseconds(20))
                continue
            }
            defer { message.payload.resetBytes(in: 0..<message.payload.count) }
            try message.validate(request: 0)
            let kind = message.header.kind
            if kind == 3 { try message.checkFailure() }
            switch try Self.decodeUpdate(kind: kind, stage: message.header.stage, cause: message.header.cause, payload: message.payload) {
            case .update(let value, let stage):
                logStage(stage)
                try update(value)
            case .record(let record):
                // The caller's durable write is the acknowledgement boundary.
                try persist(record)
                let result = ncm_pairing_ack(token, record.committed ? 2 : 1)
                if result != 0 { throw NativeBackendError.transport(code: result) }
                logStage(record.committed ? 4 : 3)
                try update(.persisted(committed: record.committed))
            case .progress:
                logStage(1)
            case .complete:
                try update(.completed)
                diagnosticFinished = true
                logStage(5)
                return
            }
        } while .now < expires
        logStage(6); diagnosticFinished = true
        throw NCMError.timeout
    }
    private enum DecodedUpdate {
        case update(PairingUpdate, Int), record(RemotePairRecord), progress, complete
    }
    private static func decodeUpdate(kind: UInt32, stage: UInt32, cause: UInt32, payload: Data) throws -> DecodedUpdate {
        switch kind {
        case 5:
            let advertisement = try JSONDecoder().decode(PairingAdvertisement.self, from: payload)
            if advertisement.port == 0 || advertisement.identifier.isEmpty || advertisement.txt["identifier"] != advertisement.identifier {
                throw NativeBackendError.malformedEvent
            }
            return .update(.listening(advertisement), 0)
        case 6:
            guard let code = String(data: payload, encoding: .utf8), (1...12).contains(code.count),
                  code.allSatisfy({ $0 == "-" || $0.isNumber }) else { throw NativeBackendError.malformedEvent }
            return .update(.code(code), 2)
        case 7, 8:
            let record = try JSONDecoder().decode(RemotePairRecord.self, from: payload)
            guard (kind == 8) == record.committed else { throw NativeBackendError.malformedEvent }
            var validated = try record.identity()
            validated.clearSeed()
            return .record(record)
        case 9: return .complete
        case 10 where stage == 1 && cause == 0 && payload.isEmpty: return .progress
        default: throw NativeBackendError.malformedEvent
        }
    }

}
