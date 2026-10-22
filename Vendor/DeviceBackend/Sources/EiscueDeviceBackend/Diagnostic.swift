// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum NCMError: String, Error, LocalizedError {
    case interfaceUnavailable, interfaceAmbiguous, interfaceInvalid, interfaceScopeUnsupported
    case busy, timeout, disconnected, network, malformedReply, unavailableBackend
    case pairingServiceUnavailable, staleDiscovery
    public var errorDescription: String? { rawValue }
}
public enum DiagnosticCommand: Equatable, Sendable {
    case status, discoverIPv4, discoverIPv6, lockdownQueryType, probe(generation: UInt32, index: UInt8)
    public var wire: String {
        switch self {
        case .status: return "STATUS\n"
        case .discoverIPv4: return "DISCOVER4\n"
        case .discoverIPv6: return "DISCOVER6\n"
        case .lockdownQueryType: return "LOCKDOWN\n"
        case let .probe(generation, index): return "PROBE \(generation) \(index)\n"
        }
    }
}
public struct DiagnosticReply: Decodable, Sendable {
    public struct Endpoint: Decodable, Identifiable, Sendable {
        public let index: UInt8
        public let service: String
        public let family: Int
        public let port: UInt16
        public var id: UInt8 { index }
    }
    public let layer: String
    public let result: String
    public let generation: UInt32?
    public let endpoints: [Endpoint]?
    public let osError: Int?
    public let tcpConnected: Bool?
    public let wireVersion: UInt32?
    public let authenticated: Bool
    public let screenCaptured: Bool?
    public let inputExecuted: Bool?
    private let protocolVersion: String
    enum CodingKeys: String, CodingKey {
        case layer, result, generation, endpoints, osError, tcpConnected, wireVersion, authenticated, screenCaptured, inputExecuted
        case protocolVersion = "protocol"
    }
    /// Only consumes diagnostic metadata. A diagnostic peer can never grant developer capabilities.
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw NCMError.malformedReply }
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        guard lines.count == 2, lines[1].isEmpty, !lines[0].isEmpty else { throw NCMError.malformedReply }
        do {
            let reply = try JSONDecoder().decode(Self.self, from: Data(lines[0]))
            try reply.validate()
            return reply
        } catch { throw NCMError.malformedReply }
    }
    private func validate() throws {
        let validLayers: Set<String> = ["ncm", "discovery", "tcp", "greeting", "lockdown-querytype", "command", "pairing", "authentication"]
        let validResults: Set<String> = ["diagnostic-only", "backend-not-implemented", "candidates", "no-candidates", "unsupported", "stale-candidate", "authorization-required", "ok", "argument", "io", "eof", "timeout", "limit", "format", "type", "not_found"]
        guard protocolVersion == "ND1", validLayers.contains(layer), validResults.contains(result),
              authenticated == false, screenCaptured != true, inputExecuted != true else { throw NCMError.malformedReply }
        guard let endpoints else { return }
        guard layer == "discovery", (generation ?? 0) > 0, endpoints.count <= 16 else { throw NCMError.malformedReply }
        var indexes = Set<UInt8>()
        for endpoint in endpoints {
            let knownService = Set(["remotepairing", "lockdown", "pairable-host"]).contains(endpoint.service)
            guard endpoint.index < 16, indexes.insert(endpoint.index).inserted, endpoint.port > 0,
                  endpoint.family == 4 || endpoint.family == 6, knownService else { throw NCMError.malformedReply }
        }
    }

}

/// Deliberately separate from diagnostic results. Implementations must own an
/// authenticated generation, negotiated IPv6/RSD endpoint, DDI checks, and media.
/// NativeDeveloperServices links the real backend; no device access happens until
/// explicitly connected with an authorized identity and permissions.
@MainActor public protocol DeveloperServices {
    func listServices() async throws -> [String]
    func capturePNG() async throws -> Data
    /// Must hold an authenticated DisplayService media session; never USB HID.
    /// A transport ACK alone must not be reported as visible input success.
    func tap(x: UInt16, y: UInt16) async throws
}
@MainActor public struct UnavailableDeveloperServices: DeveloperServices {
    public init() {}
    public func listServices() async throws -> [String] { throw NCMError.unavailableBackend }
    public func capturePNG() async throws -> Data { throw NCMError.unavailableBackend }
    public func tap(x: UInt16, y: UInt16) async throws { throw NCMError.unavailableBackend }
}
