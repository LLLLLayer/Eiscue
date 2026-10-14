#if DEBUG
import Foundation
import Network

enum DebugLoopbackProbe {
    struct Result: Codable, Sendable {
        // Outcome: 0 echo verified, 1 timeout, 2 cancelled, 3 listener failure,
        // 4 outgoing connection failure, 5 incoming connection failure, 6 invalid echo.
        let outcome: Int
        // Stage: 0 starting, 1 listening, 2 connected, 3 accepted,
        // 4 request verified, 5 reply sent, 6 reply verified.
        let stage: Int
        let accepted: Int
        let echoMatched: Int
        let elapsedMilliseconds: Int
    }

    /// Probes only the existing VPN reflector, using its own temporary TCP listener.
    /// It does not start VPN, publish a service or touch the pairing listener.
    static func run() async -> Result {
        let probe = Probe()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                probe.queue.async { probe.start(continuation) }
            }
        } onCancel: {
            probe.queue.async { probe.finish(outcome: 2) }
        }
    }

    // All mutable state and Network callbacks belong to this private serial queue.
    private final class Probe: @unchecked Sendable {
        let queue = DispatchQueue(label: "org.eiscue.debug.loopback-probe")
        private let started = ContinuousClock.now
        private let nonce: Data = {
            var value = UUID().uuid
            return withUnsafeBytes(of: &value) { Data($0) }
        }()
        private var continuation: CheckedContinuation<Result, Never>?
        private var result: Result?
        private var listener: NWListener?
        private var outgoing: NWConnection?
        private var incoming: NWConnection?
        private var deadline: DispatchWorkItem?
        private var stage = 0
        private var accepted = false
        private var echoMatched = false
        private var replySent = false
        private var sentRequest = false

        func start(_ continuation: CheckedContinuation<Result, Never>) {
            dispatchPrecondition(condition: .onQueue(queue))
            if let result { continuation.resume(returning: result); return }
            self.continuation = continuation
            let deadline = DispatchWorkItem { [weak self] in self?.finish(outcome: 1) }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + 5, execute: deadline)
            do {
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, self.result == nil else { return }
                    switch state {
                    case .ready:
                        guard self.outgoing == nil, let port = listener.port else { return }
                        self.stage = max(self.stage, 1)
                        self.connect(port: port)
                    case .failed, .cancelled: self.finish(outcome: 3)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.result == nil, self.incoming == nil else {
                        connection.cancel(); return
                    }
                    self.incoming = connection
                    self.accepted = true
                    self.stage = max(self.stage, 3)
                    connection.stateUpdateHandler = { [weak self] state in
                        guard let self, self.result == nil else { return }
                        switch state {
                        case .failed, .cancelled: self.finish(outcome: 5)
                        default: break
                        }
                    }
                    connection.start(queue: self.queue)
                    self.receive(connection, reply: false, accumulated: Data())
                }
                listener.start(queue: queue)
            } catch { finish(outcome: 3) }
        }

        private func connect(port: NWEndpoint.Port) {
            // Fixed VPN peer only; no caller-supplied destination or packet data.
            let connection = NWConnection(host: "10.7.0.1", port: port, using: .tcp)
            outgoing = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.result == nil else { return }
                switch state {
                case .ready:
                    guard !self.sentRequest else { return }
                    self.sentRequest = true
                    self.stage = max(self.stage, 2)
                    connection.send(content: self.nonce, completion: .contentProcessed { [weak self] error in
                        guard let self, self.result == nil else { return }
                        if error != nil { self.finish(outcome: 4) }
                    })
                    self.receive(connection, reply: true, accumulated: Data())
                case .failed, .cancelled: self.finish(outcome: 4)
                default: break
                }
            }
            connection.start(queue: queue)
        }

        private func receive(_ connection: NWConnection, reply: Bool, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: nonce.count - accumulated.count) {
                [weak self] content, _, complete, error in
                guard let self, self.result == nil else { return }
                var bytes = accumulated
                if let content { bytes.append(content) }
                if bytes.count == self.nonce.count {
                    guard bytes == self.nonce else { self.finish(outcome: 6); return }
                    if reply {
                        self.echoMatched = true
                        self.stage = max(self.stage, 6)
                        if self.replySent { self.finish(outcome: 0) }
                    } else {
                        self.stage = max(self.stage, 4)
                        connection.send(content: self.nonce, completion: .contentProcessed { [weak self] error in
                            guard let self, self.result == nil else { return }
                            guard error == nil else { self.finish(outcome: 5); return }
                            self.replySent = true
                            self.stage = max(self.stage, 5)
                            if self.echoMatched { self.finish(outcome: 0) }
                        })
                    }
                } else if error != nil || complete {
                    self.finish(outcome: reply ? 4 : 5)
                } else {
                    self.receive(connection, reply: reply, accumulated: bytes)
                }
            }
        }

        func finish(outcome: Int) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard result == nil else { return }
            let elapsed = started.duration(to: .now).components
            let result = Result(outcome: outcome, stage: stage, accepted: accepted ? 1 : 0,
                                echoMatched: echoMatched ? 1 : 0,
                                elapsedMilliseconds: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000))
            self.result = result
            deadline?.cancel(); deadline = nil
            listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
            listener?.cancel(); listener = nil
            outgoing?.stateUpdateHandler = nil; outgoing?.cancel(); outgoing = nil
            incoming?.stateUpdateHandler = nil; incoming?.cancel(); incoming = nil
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(returning: result)
        }
    }
}
#endif
