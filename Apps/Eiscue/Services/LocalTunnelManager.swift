import Foundation
import NetworkExtension
import Observation

/// Owns only this App's packet-tunnel configuration. Reading status never
/// creates a VPN configuration; `start()` is an explicit, user-initiated action.
@MainActor
@Observable
final class LocalTunnelManager {
    private(set) var statusTitle = String(localized: "tunnel.status.unconfigured", table: "Connections")
    private(set) var isConnected = false
    private(set) var isTransitioning = false
    private(set) var lastError: String?

    /// Delivered independently of SwiftUI, including while the App is backgrounded.
    @ObservationIgnored var onDisconnect: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var statusObservation: TunnelStatusObservation?
    @ObservationIgnored private var observationID = UUID()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operation: Operation?
    // System authorization can outlive cancellation. Do not create a second
    // configuration while the first save still has a pending completion.
    @ObservationIgnored private var preferenceSavePending = false
    #if DEBUG
    @ObservationIgnored private var pairingDiagnosticSequence: UInt64 = 0
    #endif

    private enum Operation {
        case starting, stopping
    }

    enum Failure: Error, LocalizedError {
        case simulatorUnsupported
        case missingBundleIdentifier
        case busy
        case duplicateConfigurations
        case connectionTimedOut
        case disconnectedDuringStart
        case disconnectionTimedOut
        case system(String)

        var errorDescription: String? {
            switch self {
            case .simulatorUnsupported:
                String(localized: "tunnel.error.simulator_unsupported", table: "Connections")
            case .missingBundleIdentifier:
                String(localized: "tunnel.error.missing_bundle_id", table: "Connections")
            case .busy:
                String(localized: "tunnel.error.busy", table: "Connections")
            case .duplicateConfigurations:
                String(localized: "tunnel.error.duplicate_configurations", table: "Connections")
            case .connectionTimedOut:
                String(localized: "tunnel.error.connection_timeout", table: "Connections")
            case .disconnectedDuringStart:
                String(localized: "tunnel.error.disconnected_during_start", table: "Connections")
            case .disconnectionTimedOut:
                String(localized: "tunnel.error.disconnection_timeout", table: "Connections")
            case .system(let message):
                message
            }
        }
    }

    /// Read-only: no permission prompt, creation, save, enable, or start.
    func refresh() async throws {
        #if targetEnvironment(simulator)
        statusTitle = String(localized: "tunnel.status.simulator_unsupported", table: "Connections")
        return
        #else
        guard operation == nil, !preferenceSavePending else { return }
        let token = generation
        do {
            let providerID = try providerBundleIdentifier()
            let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
            guard token == generation, operation == nil else { return }
            adopt(try Self.ownedConfiguration(in: configurations, providerID: providerID))
            lastError = nil
        } catch {
            guard token == generation, operation == nil else { return }
            let failure = Self.presentable(error)
            lastError = failure.localizedDescription
            throw failure
        }
        #endif
    }

    /// Call only from the user's start action. Saving may display iOS's VPN
    /// authorization dialog; connection starts only after saving and reloading.
    func start() async throws {
        #if targetEnvironment(simulator)
        lastError = Failure.simulatorUnsupported.localizedDescription
        throw Failure.simulatorUnsupported
        #else
        guard operation == nil, !preferenceSavePending, !isTransitioning else {
            throw Failure.busy
        }
        try Task.checkCancellation()
        let token = UUID()
        generation = token
        operation = .starting
        lastError = nil
        updateStatus()

        try await withTaskCancellationHandler {
            var submittedManager: NETunnelProviderManager?
            do {
                let providerID = try providerBundleIdentifier()
                let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
                try checkCurrent(token)
                let owned = try Self.ownedConfiguration(in: configurations, providerID: providerID)
                if let owned, owned.connection.status == .connected {
                    adopt(owned)
                    finish(token)
                    return
                }
                let selected = owned ?? NETunnelProviderManager()
                Self.configure(selected, providerID: providerID)
                adopt(selected)

                preferenceSavePending = true
                do {
                    try await selected.saveToPreferences()
                    preferenceSavePending = false
                } catch {
                    preferenceSavePending = false
                    updateStatus()
                    throw error
                }
                updateStatus()
                try checkCurrent(token)
                try await selected.loadFromPreferences()
                try checkCurrent(token)
                // Reload can change the connection instance. Rebind the observer
                // and validate ownership before controlling that connection.
                guard Self.isOwned(selected, providerID: providerID) else {
                    throw Failure.system(String(localized: "tunnel.error.unowned_reloaded_configuration", table: "Connections"))
                }
                adopt(selected)
                submittedManager = selected
                try selected.connection.startVPNTunnel()
                try await waitForConnection(selected, token: token)
                finish(token)
            } catch {
                let failure = Self.presentable(error)
                if generation == token {
                    if let submittedManager {
                        // A cancelled calling Task must not skip cleanup sleeps.
                        // This independent Task still checks the generation, so a
                        // later stop/start cannot be affected by stale cleanup.
                        await Task { @MainActor in
                            await self.cleanUpFailedStart(submittedManager, token: token)
                        }.value
                    }
                    if generation == token {
                        if !(failure is CancellationError) {
                            lastError = failure.localizedDescription
                        }
                        finish(token)
                    }
                }
                throw failure
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token,
                      self.operation == .starting else { return }
                try? await self.stop()
            }
        }
        #endif
    }

    #if DEBUG
    /// Explicit numeric-only debug query; it never starts or changes the tunnel.
    func requestPairingDiagnostics(shouldSave: @escaping @MainActor @Sendable () -> Bool = { true }) {
        guard ProcessInfo.processInfo.arguments.contains("--pairing-diagnostics") else { return }
        pairingDiagnosticSequence &+= 1
        let sample = pairingDiagnosticSequence
        let requestedAt = UInt64(Date().timeIntervalSince1970 * 1000)
        let token = generation, observation = observationID
        let request = PairingDiagnosticRequest { [weak self] response in
            guard let self, self.generation == token, self.observationID == observation, shouldSave() else { return }
            var report: [String: UInt64] = ["status": response.status, "sample": sample, "requestedAtMilliseconds": requestedAt]
            if case .snapshot(let snapshot) = response {
                report["version"] = UInt64(snapshot.version)
                report["generation"] = snapshot.generation
                report["running"] = UInt64(snapshot.running)
                for (prefix, counts) in [("received", snapshot.received), ("matched", snapshot.matched), ("injected", snapshot.injected)] {
                    report[prefix + "Syn"] = counts.syn
                    report[prefix + "SynAck"] = counts.synAck
                    report[prefix + "Ack"] = counts.ack
                }
            }
            guard let data = try? JSONEncoder().encode(report) else { return }
            try? data.write(to: URL.cachesDirectory.appendingPathComponent("EiscueTunnelDiagnostic.json"), options: [.atomic, .completeFileProtection])
        }
        guard operation == nil, let manager,
              let providerID = try? providerBundleIdentifier(), Self.isOwned(manager, providerID: providerID),
              manager.connection.status == .connected,
              let session = manager.connection as? NETunnelProviderSession else {
            request.finish(.unavailable); return
        }
        request.startTimeout()
        do { try session.sendProviderMessage(Data([1]), responseHandler: PairingDiagnosticRequest.handler(for: request)) }
        catch { request.finish(.sendError) }
    }

    /// Explicit developer recovery after replacing the extension during install.
    /// Only restarts an enabled, previously authorized, owned configuration.
    /// Never creates/saves/enables a configuration or requests new permission.
    func resumeExistingForDiagnostics() async throws {
        guard operation == nil, !preferenceSavePending, !isTransitioning else { throw Failure.busy }
        let token = UUID()
        generation = token; operation = .starting
        var submitted: NETunnelProviderManager?
        defer { if generation == token { finish(token) } }
        do {
            let providerID = try providerBundleIdentifier()
            let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
            try checkCurrent(token)
            guard let selected = try Self.ownedConfiguration(in: configurations, providerID: providerID),
                  selected.isEnabled else { throw Failure.system("debug_existing_tunnel_required") }
            adopt(selected)
            if selected.connection.status == .connected { return }
            submitted = selected
            try selected.connection.startVPNTunnel()
            try await waitForConnection(selected, token: token)
        } catch {
            if let submitted, generation == token {
                await Task { @MainActor in await self.cleanUpFailedStart(submitted, token: token) }.value
            }
            throw error
        }
    }
    #endif

    /// Can interrupt `start()`, including a pending system authorization dialog.
    /// It never removes preferences or stops another App's VPN configuration.
    func stop() async throws {
        #if targetEnvironment(simulator)
        lastError = Failure.simulatorUnsupported.localizedDescription
        throw Failure.simulatorUnsupported
        #else
        let token = UUID()
        generation = token
        operation = .stopping
        lastError = nil
        updateStatus()

        // Cleanup proceeds even if the caller's Task is already cancelled.
        try await Task { @MainActor in
            do {
                guard generation == token else { throw CancellationError() }
                let providerID = try providerBundleIdentifier()
                if manager == nil {
                    let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
                    guard generation == token else { throw CancellationError() }
                    adopt(try Self.ownedConfiguration(in: configurations, providerID: providerID))
                }
                if let manager {
                    guard generation == token else { throw CancellationError() }
                    guard Self.isOwned(manager, providerID: providerID) else {
                        throw Failure.system(String(localized: "tunnel.error.unowned_configuration", table: "Connections"))
                    }
                    manager.connection.stopVPNTunnel()
                    try await waitForDisconnection(manager, token: token)
                }
                finish(token)
            } catch {
                let failure = Self.presentable(error)
                if generation == token {
                    if !(failure is CancellationError) {
                        lastError = failure.localizedDescription
                    }
                    finish(token)
                }
                throw failure
            }
        }.value
        #endif
    }

    private func providerBundleIdentifier() throws -> String {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
            throw Failure.missingBundleIdentifier
        }
        return identifier + LocalTunnelConfiguration.providerBundleSuffix
    }

    static func isOwned(_ manager: NETunnelProviderManager, providerID: String) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerBundleIdentifier == providerID
    }

    static func ownedConfiguration(
        in configurations: [NETunnelProviderManager], providerID: String
    ) throws -> NETunnelProviderManager? {
        let owned = configurations.filter { isOwned($0, providerID: providerID) }
        guard owned.count <= 1 else { throw Failure.duplicateConfigurations }
        return owned.first
    }

    static func configure(_ manager: NETunnelProviderManager, providerID: String) {
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerID
        // iOS requires a nonempty server-address field. This is the local peer,
        // not an external VPN service; the extension opens no server connection.
        configuration.serverAddress = LocalTunnelConfiguration.peerAddress
        configuration.providerConfiguration = [
            LocalTunnelConfiguration.schemaVersionKey: LocalTunnelConfiguration.schemaVersion,
            "localAddress": LocalTunnelConfiguration.interfaceAddress,
            "peerAddress": LocalTunnelConfiguration.peerAddress,
        ]
        configuration.includeAllNetworks = false
        configuration.enforceRoutes = false
        manager.protocolConfiguration = configuration
        manager.localizedDescription = String(localized: "tunnel.configuration.display_name", table: "Connections")
        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
        manager.isEnabled = true
    }

    private func adopt(_ selected: NETunnelProviderManager?) {
        statusObservation = nil
        let currentObservationID = UUID()
        observationID = currentObservationID
        manager = selected
        if let selected {
            let token = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange, object: selected.connection, queue: .main
            ) { [weak self] _ in
                // The observer is explicitly delivered on the main queue.
                // NotificationCenter filters the exact connection object. A
                // sendable identity rejects already queued, stale callbacks
                // without transferring Notification across actor boundaries.
                MainActor.assumeIsolated {
                    guard let self, self.observationID == currentObservationID else { return }
                    self.updateStatus()
                }
            }
            statusObservation = TunnelStatusObservation(token: token)
        }
        updateStatus()
    }

    private func updateStatus() {
        let wasConnected = isConnected
        let status = manager?.connection.status
        isConnected = status == .connected
        isTransitioning = operation != nil || preferenceSavePending
            || status == .connecting || status == .reasserting || status == .disconnecting
        switch status {
        case .connected: statusTitle = String(localized: "tunnel.status.connected", table: "Connections")
        case .connecting: statusTitle = String(localized: "tunnel.status.connecting", table: "Connections")
        case .reasserting: statusTitle = String(localized: "tunnel.status.reasserting", table: "Connections")
        case .disconnecting: statusTitle = String(localized: "tunnel.status.disconnecting", table: "Connections")
        case .disconnected, .invalid, .none:
            if operation == .stopping {
                statusTitle = String(localized: "tunnel.status.stopping", table: "Connections")
            } else if operation == .starting {
                statusTitle = String(localized: "tunnel.status.preparing", table: "Connections")
            } else if preferenceSavePending {
                statusTitle = String(localized: "tunnel.status.awaiting_configuration", table: "Connections")
            } else {
                statusTitle = manager == nil ? String(localized: "tunnel.status.unconfigured", table: "Connections") : String(localized: "tunnel.status.disconnected", table: "Connections")
            }
        @unknown default: statusTitle = String(localized: "tunnel.status.unknown", table: "Connections")
        }
        if wasConnected, !isConnected { onDisconnect?() }
    }

    private func checkCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, operation == .starting else { throw CancellationError() }
    }

    private func finish(_ token: UUID) {
        guard generation == token else { return }
        operation = nil
        updateStatus()
    }

    private func waitForConnection(_ selected: NETunnelProviderManager, token: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var hasStartedConnecting = false
        while clock.now < deadline {
            try checkCurrent(token)
            updateStatus()
            switch selected.connection.status {
            case .connected: return
            case .connecting, .reasserting: hasStartedConnecting = true
            case .invalid, .disconnected:
                // The start request may return before status leaves disconnected.
                if hasStartedConnecting { throw Failure.disconnectedDuringStart }
            case .disconnecting: throw Failure.disconnectedDuringStart
            @unknown default: break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.connectionTimedOut
    }

    private func waitForDisconnection(_ selected: NETunnelProviderManager, token: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            guard generation == token else { throw CancellationError() }
            updateStatus()
            if selected.connection.status == .disconnected || selected.connection.status == .invalid {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.disconnectionTimedOut
    }

    private func cleanUpFailedStart(_ selected: NETunnelProviderManager, token: UUID) async {
        guard generation == token else { return }
        operation = .stopping
        selected.connection.stopVPNTunnel()
        updateStatus()
        // Preserve the original start error. Status continues reflecting the
        // system if disconnection itself does not finish within the bound.
        try? await waitForDisconnection(selected, token: token)
    }

    private static func presentable(_ error: any Error) -> any Error {
        if error is Failure || error is CancellationError { return error }
        let native = error as NSError
        if native.domain == NSCocoaErrorDomain, native.code == NSUserCancelledError {
            return Failure.system(String(localized: "tunnel.error.authorization_cancelled", table: "Connections"))
        }
        if native.domain == "NEConfigurationErrorDomain", native.code == 10 {
            return Failure.system(String(localized: "tunnel.error.permission_denied", table: "Connections"))
        }
        if native.domain == NEVPNErrorDomain {
            switch native.code {
            case NEVPNError.configurationInvalid.rawValue:
                return Failure.system(String(localized: "tunnel.error.invalid_configuration", table: "Connections"))
            case NEVPNError.configurationDisabled.rawValue:
                return Failure.system(String(localized: "tunnel.error.disabled_configuration", table: "Connections"))
            case NEVPNError.configurationStale.rawValue:
                return Failure.system(String(localized: "tunnel.error.stale_configuration", table: "Connections"))
            case NEVPNError.configurationReadWriteFailed.rawValue:
                return Failure.system(String(localized: "tunnel.error.preferences_unavailable", table: "Connections"))
            default: break
            }
        }
        return Failure.system(String(format: String(localized: "tunnel.error.operation_failed", table: "Connections"), native.localizedDescription))
    }
}

#if DEBUG
private struct PairingDiagnosticCounts: Decodable, Sendable {
    let syn: UInt64
    let synAck: UInt64
    let ack: UInt64
}

private struct PairingDiagnosticSnapshot: Decodable, Sendable {
    let version: UInt8
    let generation: UInt64
    let running: UInt8
    let received: PairingDiagnosticCounts
    let matched: PairingDiagnosticCounts
    let injected: PairingDiagnosticCounts
}

private enum PairingDiagnosticResponse: Sendable {
    case snapshot(PairingDiagnosticSnapshot), unavailable, emptyResponse, sendError, timeout, invalidResponse
    var status: UInt64 {
        switch self {
        case .snapshot: 0
        case .unavailable: 1
        case .emptyResponse: 2
        case .sendError: 3
        case .timeout: 4
        case .invalidResponse: 5
        }
    }
    static func decode(_ data: Data?) -> Self {
        guard let data else { return .emptyResponse }
        guard data.count <= 4096,
              let snapshot = try? JSONDecoder().decode(PairingDiagnosticSnapshot.self, from: data),
              snapshot.version == 1, snapshot.running <= 1 else { return .invalidResponse }
        return .snapshot(snapshot)
    }
}

@MainActor private final class PairingDiagnosticRequest {
    private var completion: (@MainActor @Sendable (PairingDiagnosticResponse) -> Void)?
    private var timeout: Task<Void, Never>?
    init(_ completion: @escaping @MainActor @Sendable (PairingDiagnosticResponse) -> Void) { self.completion = completion }
    func startTimeout() {
        timeout = Task { @MainActor [self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            finish(.timeout)
        }
    }
    func finish(_ response: PairingDiagnosticResponse) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel(); timeout = nil
        completion(response)
    }
    nonisolated static func handler(for request: PairingDiagnosticRequest) -> @Sendable (Data?) -> Void {
        { data in
            let response = PairingDiagnosticResponse.decode(data)
            Task { @MainActor in request.finish(response) }
        }
    }
}
#endif

/// Releasing the manager also releases its observer without retaining the App.
private final class TunnelStatusObservation {
    let token: any NSObjectProtocol

    init(token: any NSObjectProtocol) { self.token = token }

    deinit { NotificationCenter.default.removeObserver(token) }
}
