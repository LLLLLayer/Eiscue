// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A short-lived candidate discovered on one explicitly selected board interface.
/// Discovery is diagnostic metadata; the native session must still verify the
/// saved identity and acquire screen/input authorization separately.
public struct NCMDiscoveredEndpoint: Sendable {
    public let transport: NCMBoardTransport
    let reply: DiagnosticReply
    let endpoint: DiagnosticReply.Endpoint
    let interface: NCMInterfaceBinding.Row
    let observedAt: ContinuousClock.Instant
    // Conservative local maximum. The relay also checks its own generation and
    // expiry. Every new connection performs discovery again.
    static let lifetime: Duration = .seconds(3)

    init(reply: DiagnosticReply, family: Int, interface: NCMInterfaceBinding.Row, transport: NCMBoardTransport = .usb,
         observedAt: ContinuousClock.Instant = .now) throws {
        guard reply.layer == "discovery", reply.result == "candidates",
              let generation = reply.generation, generation > 0,
              !reply.authenticated, reply.screenCaptured != true, reply.inputExecuted != true else {
            throw NativeBackendError.invalidCandidate
        }
        let candidates = reply.endpoints?.filter { $0.service == "remotepairing" && $0.family == family } ?? []
        guard candidates.count == 1, let endpoint = candidates.first, endpoint.port > 0 else {
            throw NCMError.pairingServiceUnavailable
        }
        self.reply = reply; self.endpoint = endpoint
        self.interface = interface; self.transport = transport; self.observedAt = observedAt
    }

    func validate(currentInterface: NCMInterfaceBinding.Row, transport: NCMBoardTransport = .usb,
                  now: ContinuousClock.Instant = .now) throws {
        let age = observedAt.duration(to: now)
        guard age >= .zero, age < Self.lifetime else { throw NCMError.staleDiscovery }
        // Interface names or indexes may be reused after replugging. Compare the
        // complete validated row and keep sockets scoped to that exact interface.
        guard currentInterface == interface, transport == self.transport else { throw NCMError.interfaceInvalid }
    }
}
