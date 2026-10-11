// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

/// Short, bounded connections to board diagnostics, never to the phone's own
/// RemotePairing address. One command at a time; no authentication or input replay.
@MainActor public final class NCMProbeClient {
    private struct Pending {
        let id: UUID
        let connection: NWConnection
        let continuation: CheckedContinuation<DiagnosticReply, Error>
        var bytes = Data()
        var sent = false
    }
    private var pending: Pending?
    private var timer: Task<Void, Never>?
    public let transport: NCMBoardTransport
    public init(transport: NCMBoardTransport = .usb) { self.transport = transport }

    /// Refresh candidates on the board, keeping discovery on the selected interface.
    /// The multicast query family does not determine a returned endpoint's family.
    /// Repeat the two-query discovery round at most once for missing services only.
    public func discoverRemotePairing() async throws -> NCMDiscoveredEndpoint {
        guard pending == nil else { throw NCMError.busy }
        try Task.checkCancellation()
        let binding = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory(), transport: transport)
        for attempt in 0..<2 {
            var missingPairingService = false
            for command in [DiagnosticCommand.discoverIPv6, .discoverIPv4] {
                try Task.checkCancellation()
                try binding.validateCurrent()
                let connection = NWConnection(host: .ipv4(binding.remoteAddress), port: 28767, using: binding.parameters())
                let reply = try await exchange(command, connection: connection)
                try Task.checkCancellation()
                // A changed interface never causes discovery to move onto another
                // transport, a corporate VPN, or another attached board.
                try binding.validateCurrent()
                guard reply.layer == "discovery", ["candidates", "no-candidates", "unsupported", "not_found"].contains(reply.result) else {
                    throw NCMError.malformedReply
                }
                if reply.result == "candidates" {
                    for family in [6, 4] where reply.endpoints?.contains(where: { $0.service == "remotepairing" && $0.family == family }) == true {
                        // Initialization still rejects multiple candidates in the
                        // preferred family. Such ambiguity never triggers a retry
                        // or fallback to another family.
                        return try NCMDiscoveredEndpoint(reply: reply, family: family, interface: binding.row, transport: transport)
                    }
                    missingPairingService = true
                } else if reply.result == "no-candidates" || reply.result == "not_found" {
                    missingPairingService = true
                }
            }
            guard attempt == 0, missingPairingService else { break }
        }
        throw NCMError.pairingServiceUnavailable
    }

    public func request(_ command: DiagnosticCommand) async throws -> DiagnosticReply {
        guard pending == nil else { throw NCMError.busy }
        try Task.checkCancellation()
        let binding = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory(), transport: transport)
        let connection = NWConnection(host: .ipv4(binding.remoteAddress), port: 28767, using: binding.parameters())
        let reply = try await exchange(command, connection: connection)
        try Task.checkCancellation()
        try binding.validateCurrent()
        return reply
    }
    // Internal test seam: the public path always resolves and binds the selected board link.
    func exchange(_ command: DiagnosticCommand, connection: NWConnection, timeout: Duration = .seconds(7)) async throws -> DiagnosticReply {
        guard pending == nil else { throw NCMError.busy }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, connection: connection, continuation: continuation)
                connection.stateUpdateHandler = { [weak self] state in
                    // Network callbacks execute on the explicitly selected main queue.
                    Task { @MainActor [weak self] in
                        guard let self, self.pending?.id == id else { return }
                        switch state {
                        case .ready:
                            guard self.pending?.sent == false else { return }
                            self.pending?.sent = true
                            connection.send(content: Data(command.wire.utf8), completion: .contentProcessed { [weak self] error in
                                Task { @MainActor [weak self] in
                                    if error != nil { self?.finish(id, .failure(NCMError.network)) }
                                    else { self?.receive(id) }
                                }
                            })
                        case .failed: self.finish(id, .failure(NCMError.network))
                        case .cancelled: self.finish(id, .failure(NCMError.disconnected))
                        default: break
                        }
                    }
                }
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, .failure(NCMError.timeout))
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }
    public func cancel() {
        if let id = pending?.id { finish(id, .failure(CancellationError())) }
    }
    private func receive(_ id: UUID) {
        guard let current = pending, current.id == id else { return }
        current.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.pending?.id == id else { return }
                if let data { self.pending?.bytes.append(data) }
                guard let bytes = self.pending?.bytes, bytes.count <= 4096 else {
                    self.finish(id, .failure(NCMError.malformedReply)); return
                }
                if error != nil { self.finish(id, .failure(NCMError.network)) }
                else if complete { self.finish(id, Result { try DiagnosticReply.decode(bytes) }) }
                else { self.receive(id) }
            }
        }
    }
    private func finish(_ id: UUID, _ result: Result<DiagnosticReply, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        timer?.cancel(); timer = nil
        current.connection.stateUpdateHandler = nil
        current.connection.cancel()
        current.continuation.resume(with: result)
    }
}
