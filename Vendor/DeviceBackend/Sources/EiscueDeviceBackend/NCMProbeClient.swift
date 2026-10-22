// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

/// Exchanges bounded diagnostic lines only on the explicitly selected board.
@MainActor public final class NCMProbeClient {
    private final class Transaction {
        enum Phase { case connecting, sending, receiving }
        let id: UUID
        let socket: NWConnection
        let command: Data
        let reply: CheckedContinuation<DiagnosticReply, Error>
        var phase = Phase.connecting
        var bytes = Data()
        var timer: Task<Void, Never>?
        init(id: UUID, socket: NWConnection, command: DiagnosticCommand, reply: CheckedContinuation<DiagnosticReply, Error>) {
            self.id = id; self.socket = socket; self.command = Data(command.wire.utf8); self.reply = reply
        }
    }
    private enum Event {
        case state(NWConnection.State), sent(Bool), received(Data?, Bool, Bool), ended(Error)
    }
    private var current: Transaction?
    private var discoveryID: UUID?
    public let transport: NCMBoardTransport
    public init(transport: NCMBoardTransport = .usb) { self.transport = transport }

    public func discoverRemotePairing() async throws -> NCMDiscoveredEndpoint {
        guard current == nil, discoveryID == nil else { throw NCMError.busy }
        try Task.checkCancellation()
        let id = UUID()
        discoveryID = id
        defer { if discoveryID == id { discoveryID = nil } }
        let selected = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory(), transport: transport)
        for round in 0...1 {
            var missing = false
            for query in [DiagnosticCommand.discoverIPv6, .discoverIPv4] {
                guard discoveryID == id else { throw CancellationError() }
                let response = try await onBoard(query, binding: selected)
                guard discoveryID == id else { throw CancellationError() }
                guard response.layer == "discovery" else { throw NCMError.malformedReply }
                switch response.result {
                case "candidates":
                    for family in [6, 4] {
                        guard response.endpoints?.contains(where: { $0.family == family && $0.service == "remotepairing" }) == true else { continue }
                        return try NCMDiscoveredEndpoint(reply: response, family: family, interface: selected.row, transport: transport)
                    }
                    missing = true
                case "no-candidates", "not_found": missing = true
                case "unsupported": break
                default: throw NCMError.malformedReply
                }
            }
            if round == 1 || !missing { break }
        }
        throw NCMError.pairingServiceUnavailable
    }
    public func request(_ command: DiagnosticCommand) async throws -> DiagnosticReply {
        guard current == nil, discoveryID == nil else { throw NCMError.busy }
        let selected = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory(), transport: transport)
        return try await onBoard(command, binding: selected)
    }
    private func onBoard(_ command: DiagnosticCommand, binding: NCMInterfaceBinding) async throws -> DiagnosticReply {
        try Task.checkCancellation()
        try binding.validateCurrent()
        let socket = NWConnection(host: .ipv4(binding.remoteAddress), port: 28767, using: binding.parameters())
        let response = try await exchange(command, connection: socket)
        try Task.checkCancellation()
        try binding.validateCurrent()
        return response
    }
    func exchange(_ command: DiagnosticCommand, connection: NWConnection, timeout: Duration = .seconds(7)) async throws -> DiagnosticReply {
        guard current == nil else { throw NCMError.busy }
        try Task.checkCancellation()
        let transactionID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                let transaction = Transaction(id: transactionID, socket: connection, command: command, reply: reply)
                current = transaction
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.handle(.state(state), id: transaction.id) }
                }
                transaction.timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.handle(.ended(NCMError.timeout), id: transaction.id)
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.handle(.ended(CancellationError()), id: transactionID) }
        }
    }
    public func cancel() {
        discoveryID = nil
        guard let transaction = current else { return }
        complete(transaction, .failure(CancellationError()))
    }
    private func handle(_ event: Event, id: UUID) {
        guard let transaction = current, transaction.id == id else { return }
        switch event {
        case .ended(let error): complete(transaction, .failure(error))
        case .state(.failed): complete(transaction, .failure(NCMError.network))
        case .state(.cancelled): complete(transaction, .failure(NCMError.disconnected))
        case .state(.ready):
            guard transaction.phase == .connecting else { return }
            transaction.phase = .sending
            transaction.socket.send(content: transaction.command, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in self?.handle(.sent(error == nil), id: id) }
            })
        case .state: break
        case .sent(false): complete(transaction, .failure(NCMError.network))
        case .sent(true):
            guard transaction.phase == .sending else { return }
            transaction.phase = .receiving
            read(transaction)
        case let .received(bytes, eof, success):
            guard transaction.phase == .receiving else { return }
            if let bytes { transaction.bytes.append(bytes) }
            if transaction.bytes.count > 4096 { complete(transaction, .failure(NCMError.malformedReply)) }
            else if !success { complete(transaction, .failure(NCMError.network)) }
            else if eof { complete(transaction, Result { try DiagnosticReply.decode(transaction.bytes) }) }
            else { read(transaction) }
        }
    }
    private func read(_ transaction: Transaction) {
        let id = transaction.id
        transaction.socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, eof, error in
            Task { @MainActor in self?.handle(.received(bytes, eof, error == nil), id: id) }
        }
    }
    private func complete(_ transaction: Transaction, _ result: Result<DiagnosticReply, Error>) {
        guard current === transaction else { return }
        current = nil
        transaction.timer?.cancel(); transaction.timer = nil
        transaction.socket.stateUpdateHandler = nil
        transaction.socket.cancel()
        transaction.reply.resume(with: result)
    }
}
