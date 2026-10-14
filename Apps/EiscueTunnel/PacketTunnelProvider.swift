// Local tunnel approach based on LocalDevVPN by Stossy11 / SideStore Team.
// Copyright (c) 2025 SideStore Team. Used under the StosVPN License.
// Reference fork: https://github.com/jkcoxson/LocalDevVPN
// Revision: af3fd697803ada4ac2b8d518358f5ab0a534844c
// See the bundled third-party license and attribution for LocalDevVPN.

import Foundation
import NetworkExtension

/// All mutable state belongs to `queue`. NetworkExtension callbacks are always
/// enqueued, even if an implementation invokes them synchronously.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.eiscue.local-tunnel")
    private let reflector = PacketReflector()
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var state: State = .idle
    private var pendingStart: StartReply?
    private var outstandingRead: ReadRequest?
    #if DEBUG
    private var tcpDiagnostics = TCPDiagnostics()
    #endif

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let reply = StartReply(completionHandler)
        queue.async { [self] in
            guard state == .idle else {
                reply.call(TunnelError.alreadyStarted)
                return
            }
            // readPackets has no cancellation API and need not call back when
            // stopped. Do not report a new tunnel ready while an older read
            // could prevent its packet loop from ever starting.
            guard outstandingRead == nil else {
                reply.call(TunnelError.previousReadPending)
                return
            }
            let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            guard let version = configuration?[LocalTunnelConfiguration.schemaVersionKey] as? Int,
                  version == LocalTunnelConfiguration.schemaVersion else {
                reply.call(TunnelError.incompatibleConfiguration)
                return
            }

            generation &+= 1
            let startingGeneration = generation
            #if DEBUG
            tcpDiagnostics = TCPDiagnostics(generation: startingGeneration)
            #endif
            activeGeneration = startingGeneration
            state = .starting
            pendingStart = reply

            let ipv4 = NEIPv4Settings(
                addresses: [LocalTunnelConfiguration.interfaceAddress],
                subnetMasks: [LocalTunnelConfiguration.interfaceSubnetMask]
            )
            ipv4.includedRoutes = [NEIPv4Route(
                destinationAddress: LocalTunnelConfiguration.peerAddress,
                subnetMask: LocalTunnelConfiguration.peerSubnetMask
            )]
            ipv4.excludedRoutes = [.default()]
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: LocalTunnelConfiguration.peerAddress)
            settings.ipv4Settings = ipv4
            // No default included route, DNS, proxy or IPv6 configuration.
            setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard self.activeGeneration == startingGeneration, self.state == .starting else { return }
                    if let error {
                        self.invalidate(startError: error)
                        return
                    }
                    self.state = .running
                    #if DEBUG
                    self.tcpDiagnostics.running = 1
                    #endif
                    self.finishStart(error: nil)
                    self.enqueueRead()
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let reply = StopReply(completionHandler)
        queue.async { [self] in
            invalidate(startError: TunnelError.stoppedBeforeReady)
            // NetworkExtension removes the settings when the provider stops.
            // Keep any outstanding read token until its callback returns. A new
            // start on this instance fails closed while that read is pending.
            reply.call()
        }
    }

    #if DEBUG
    // Single-byte query; the response contains only aggregate numeric counters.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler else { return }
        let reply = MessageReply(completionHandler)
        queue.async { [self] in
            guard messageData == Data([1]) else { reply.call(nil); return }
            reply.call(try? JSONEncoder().encode(tcpDiagnostics))
        }
    }
    #endif

    private func enqueueRead() {
        queue.async { [weak self] in self?.beginReadIfNeeded() }
    }

    private func beginReadIfNeeded() {
        guard state == .running, let activeGeneration, outstandingRead == nil else { return }
        let request = ReadRequest(id: UUID(), generation: activeGeneration)
        outstandingRead = request
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async { self.consume(packets, protocols: protocols, request: request) }
        }
    }

    private func consume(_ packets: [Data], protocols: [NSNumber], request: ReadRequest) {
        guard outstandingRead?.id == request.id else { return }
        outstandingRead = nil
        guard state == .running, activeGeneration == request.generation else {
            // An older read may complete after a newer generation has started.
            // Discard its packets, and only schedule work for the current state.
            enqueueRead()
            return
        }
        guard packets.count == protocols.count else {
            enqueueRead()
            return
        }

        var reflected: [Data] = []
        #if DEBUG
        var reflectedKinds: [TCPKind] = []
        #endif
        for index in packets.indices {
            #if DEBUG
            let kind = Self.tcpKind(packets[index], protocolFamily: protocols[index].int32Value)
            if let kind { tcpDiagnostics.received.record(kind) }
            #endif
            guard protocols[index] == NSNumber(value: AF_INET),
                  let packet = reflector.reflect(packets[index], protocolFamily: AF_INET) else { continue }
            reflected.append(packet)
            #if DEBUG
            if let kind { tcpDiagnostics.matched.record(kind); reflectedKinds.append(kind) }
            #endif
        }
        if !reflected.isEmpty,
           !packetFlow.writePackets(reflected, withProtocols: Array(repeating: NSNumber(value: AF_INET), count: reflected.count)) {
            invalidate(startError: TunnelError.packetWriteFailed)
            cancelTunnelWithError(TunnelError.packetWriteFailed)
            return
        }
        #if DEBUG
        // Successful submission to packetFlow is not proof of TCP delivery.
        for kind in reflectedKinds { tcpDiagnostics.injected.record(kind) }
        #endif
        enqueueRead()
    }

    private func finishStart(error: Error?) {
        let reply = pendingStart
        pendingStart = nil
        reply?.call(error)
    }

    private func invalidate(startError: Error) {
        generation &+= 1
        activeGeneration = nil
        state = .idle
        #if DEBUG
        tcpDiagnostics.running = 0
        #endif
        finishStart(error: startError)
    }

    #if DEBUG
    private enum TCPKind { case syn, synAck, ack }

    private struct TCPCounts: Encodable {
        var syn: UInt64 = 0
        var synAck: UInt64 = 0
        var ack: UInt64 = 0
        mutating func record(_ kind: TCPKind) {
            switch kind {
            case .syn: syn &+= 1
            case .synAck: synAck &+= 1
            case .ack: ack &+= 1
            }
        }
    }

    private struct TCPDiagnostics: Encodable {
        let version: UInt8 = 1
        var generation: UInt64 = 0
        var running: UInt8 = 0
        var received = TCPCounts()
        var matched = TCPCounts()
        var injected = TCPCounts()
    }

    private static func tcpKind(_ packet: Data, protocolFamily: Int32) -> TCPKind? {
        guard protocolFamily == AF_INET, packet.count >= 40 else { return nil }
        return packet.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> TCPKind? in
            guard bytes[0] >> 4 == 4, bytes[9] == 6 else { return nil }
            let ipLength = Int(bytes[0] & 0x0F) * 4
            let totalLength = Int(bytes[2]) * 256 + Int(bytes[3])
            let fragmentOffset = (Int(bytes[6]) * 256 + Int(bytes[7])) & 0x1FFF
            guard ipLength >= 20, totalLength == bytes.count, ipLength + 20 <= totalLength,
                  fragmentOffset == 0 else { return nil }
            let tcpLength = Int(bytes[ipLength + 12] >> 4) * 4
            guard tcpLength >= 20, ipLength + tcpLength <= totalLength else { return nil }
            let flags = bytes[ipLength + 13]
            if flags & 0x02 != 0 { return flags & 0x10 != 0 ? .synAck : .syn }
            // This includes ACKs carrying data; it does not assert handshake completion.
            return flags & 0x10 != 0 ? .ack : nil
        }
    }

    private final class MessageReply: @unchecked Sendable {
        private let handler: (Data?) -> Void
        init(_ handler: @escaping (Data?) -> Void) { self.handler = handler }
        func call(_ data: Data?) { handler(data) }
    }
    #endif

    private enum State { case idle, starting, running }

    private struct ReadRequest: Sendable {
        let id: UUID
        let generation: UInt64
    }

    // The SDK completion closures are not declared Sendable. These wrappers
    // transfer them once to the serial queue; they never run concurrently.
    private final class StartReply: @unchecked Sendable {
        private let handler: (Error?) -> Void
        init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
        func call(_ error: Error?) { handler(error) }
    }

    private final class StopReply: @unchecked Sendable {
        private let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        func call() { handler() }
    }

    private enum TunnelError: LocalizedError {
        case alreadyStarted, previousReadPending, incompatibleConfiguration, stoppedBeforeReady, packetWriteFailed

        var errorDescription: String? {
            switch self {
            case .alreadyStarted: String(localized: "tunnel.error.already-started", defaultValue: "Local VPN is already starting or on.")
            case .previousReadPending: String(localized: "tunnel.error.previous-read-pending", defaultValue: "Local VPN is still closing. Try connecting shortly.")
            case .incompatibleConfiguration: String(localized: "tunnel.error.incompatible-configuration", defaultValue: "VPN settings are incompatible. Set up the local VPN again in Eiscue.")
            case .stoppedBeforeReady: String(localized: "tunnel.error.stopped-before-ready", defaultValue: "Local VPN stopped during startup. Try connecting again.")
            case .packetWriteFailed: String(localized: "tunnel.error.packet-write-failed", defaultValue: "Local VPN couldn't send data and has disconnected.")
            }
        }
    }
}
