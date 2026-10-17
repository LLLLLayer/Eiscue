import EiscueDeviceCore
import Foundation
import Observation

/// Owns transport selection, transitions and the identity of the device borrower.
@MainActor @Observable
final class DeviceSession {
    enum Owner: Equatable, Sendable { case run(UUID), dictation(UUID), repair, setup }
    enum State: Equatable {
        case idle(route: DeviceConnectionMethod)
        case connecting(route: DeviceConnectionMethod, backend: DeviceControlBackend?, opID: UUID)
        case connected(route: DeviceConnectionMethod, backend: DeviceControlBackend?, status: DeviceStatus)
        case releasing(route: DeviceConnectionMethod, opID: UUID)
        case switching(from: DeviceConnectionMethod, to: DeviceConnectionMethod)
    }
    enum ExternalEvent: Equatable, Sendable {
        case transportLost, authenticationFailed, hardwareStopped, screenSharingStopped, geometryChanged, backgrounded
    }
    struct Identity: Equatable, Sendable {
        let operationID: UUID
        fileprivate let clientID: ObjectIdentifier
        fileprivate let generation: UUID
        fileprivate let leaseID: UUID?
    }
    struct Operation: Sendable {
        let id: UUID
        let method: DeviceConnectionMethod
        let backend: DeviceControlBackend?
        let client: DeviceClient
        fileprivate let kind: OperationKind
        fileprivate let leaseID: UUID?
        fileprivate let token: UUID
        fileprivate let hadConnection: Bool
        fileprivate let previousActiveMethod: DeviceConnectionMethod?
        fileprivate let previousActiveBackend: DeviceControlBackend?
        fileprivate let previousStatus: DeviceStatus
    }
    struct ExternalOutcome: Equatable, Sendable {
        let event: ExternalEvent
        let isIgnored: Bool
        let invalidatesPreview: Bool
        let stopRunID: UUID?
        let cancelDictationID: UUID?
        let preservesTransport: Bool
    }
    enum Failure: LocalizedError {
        case releaseUnconfirmed
        var errorDescription: String? { String(localized: "connectionRepair.connection.unconfirmed", table: "Connections") }
    }
    fileprivate enum OperationKind: Equatable, Sendable { case connection, release, selection, setup }

    private(set) var state: State = .idle(route: .localVPN)
    private(set) var owner: Owner?
    private(set) var selectedMethod: DeviceConnectionMethod = .localVPN
    private(set) var backendPreference: DeviceControlBackend = .automatic
    private(set) var hasUnconfirmedRelease = false
    private(set) var client: DeviceClient
    private(set) var networkClient: DeviceClient?
    let bluetooth: BluetoothDeviceController
    private(set) var activeMethod: DeviceConnectionMethod?
    private(set) var activeBackend: DeviceControlBackend?
    private(set) var operationID = UUID() { didSet { generation = UUID() } }
    private(set) var status: DeviceStatus = .unavailable(reason: String(localized: "device.not_connected", table: "Runtime"))
    var onExternalStop: ((UUID, ExternalEvent) -> Void)?
    var onInvalidateDictation: ((UUID, ExternalEvent) -> Void)?
    var onExternalOutcome: ((ExternalOutcome) -> Void)?
    @ObservationIgnored private var leaseID: UUID?
    private var operations: [UUID: Operation] = [:]
    @ObservationIgnored private var connectionTasks: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var confirmedRelease: Identity?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operatingSystemVersion: OperatingSystemVersion

    init(client: DeviceClient, bluetooth: BluetoothDeviceController = BluetoothDeviceController(),
         operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.client = client; self.bluetooth = bluetooth; self.operatingSystemVersion = operatingSystemVersion
    }
    var identity: Identity { Identity(operationID: operationID, clientID: ObjectIdentifier(client.device), generation: generation, leaseID: leaseID) }
    var isTransitioning: Bool {
        if !operations.isEmpty { return true }
        return switch state { case .connecting, .releasing, .switching: true; case .idle, .connected: false }
    }
    var expectsTransportChanges: Bool {
        guard let operation = operations[operationID], isCurrent(operation) else { return false }
        return switch operation.kind { case .connection, .release, .selection: true; case .setup: false }
    }
    var isBusy: Bool { owner != nil || isTransitioning }
    var showsConnectionProgress: Bool {
        switch state {
        case .connecting: true
        case .releasing(_, let id): operations[id]?.hadConnection == true
        case .idle, .connected, .switching: false
        }
    }
    func isCurrent(_ identity: Identity) -> Bool { self.identity == identity }
    func isCurrent(_ operation: Operation) -> Bool {
        operations[operation.id]?.token == operation.token && operationID == operation.id && client.device === operation.client.device && leaseID == operation.leaseID
    }
    /// An active session must be released before startup/test injection can install another client.
    func configure(method: DeviceConnectionMethod, backend: DeviceControlBackend,
                   client suppliedClient: DeviceClient? = nil, networkClient suppliedNetwork: DeviceClient? = nil) throws {
        guard owner == nil, !isTransitioning, activeMethod == nil, !hasUnconfirmedRelease else { throw DeviceControlError.busy }
        let target = try selection(method: method, suppliedClient: suppliedClient, suppliedNetwork: suppliedNetwork)
        client = target.client; networkClient = target.network
        selectedMethod = method; backendPreference = backend
        confirmedRelease = nil
        operationID = UUID(); activeBackend = nil; status = Self.disconnected; state = .idle(route: method)
    }
    func acquire(_ requested: Owner, cancellingConnection: Bool = false) throws -> DeviceLease {
        let canCancelConnection: Bool = {
            guard requested == .setup, cancellingConnection, case .connecting = state else { return false }
            return operations.values.allSatisfy { $0.kind == .connection }
        }()
        guard owner == nil, !isTransitioning || canCancelConnection,
              !hasUnconfirmedRelease || requested == .repair || requested == .setup else { throw DeviceControlError.busy }
        if canCancelConnection { for task in connectionTasks.values { task.cancel() } }
        let id = UUID(); confirmedRelease = nil; owner = requested; leaseID = id
        return DeviceLease(session: self, id: id, owner: requested, client: client)
    }
    fileprivate func release(_ expected: Owner, id: UUID) {
        guard owner == expected, leaseID == id else { return }
        confirmedRelease = nil; owner = nil; leaseID = nil
    }
    func beginConnection(method: DeviceConnectionMethod, backend: DeviceControlBackend,
                         owner expectedOwner: Owner? = nil, id: UUID = UUID()) throws -> Operation {
        try requireOwner(expectedOwner)
        guard !isTransitioning, !hasUnconfirmedRelease, activeMethod == nil, method == selectedMethod else { throw DeviceControlError.busy }
        if method != .bluetoothBoard, !backend.isAvailable(on: operatingSystemVersion) { throw DeviceControlError.backendUnavailable(backend) }
        backendPreference = backend
        let resolved = method == .bluetoothBoard ? nil : backend.resolved(on: operatingSystemVersion)
        let operation = register(kind: .connection, method: method, backend: resolved, id: id)
        activeMethod = nil; activeBackend = nil; status = Self.disconnected
        state = .connecting(route: method, backend: resolved, opID: id)
        return operation
    }
    func beginSetup(owner expectedOwner: Owner, id: UUID = UUID(), showsProgress: Bool = true) throws -> Operation {
        try requireOwner(expectedOwner)
        guard expectedOwner == .setup, !isTransitioning else { throw DeviceControlError.busy }
        let operation = register(kind: .setup, method: activeMethod ?? selectedMethod, backend: activeBackend, id: id)
        if showsProgress { state = .connecting(route: operation.method, backend: operation.backend, opID: id) }
        return operation
    }
    @discardableResult
    func completeSetup(_ operation: Operation, status suppliedStatus: DeviceStatus? = nil, transportConnected: Bool? = nil) -> Bool {
        guard operation.kind == .setup, operations[operation.id]?.token == operation.token else { return false }
        let current = isCurrent(operation); finish(operation)
        guard current else { settleStale(operation); return false }
        let connected = !hasUnconfirmedRelease && operation.previousActiveMethod != nil && transportConnected != false
        var value = suppliedStatus ?? status
        // Setup can retain or downgrade existing authority. Only connection and
        // fresh status admission may establish readiness that was unavailable.
        if Self.isReady(value), (!connected || !Self.isReady(operation.previousStatus) || !Self.isReady(status)) {
            value = Self.isReady(status) ? Self.disconnected : status
        }
        activeMethod = connected ? operation.previousActiveMethod : nil
        activeBackend = connected ? operation.previousActiveBackend : nil
        status = value; settle(); return true
    }
    @discardableResult
    func completeConnection(_ operation: Operation, status: DeviceStatus, connected: Bool = true) -> Bool {
        guard operation.kind == .connection, operations[operation.id]?.token == operation.token else { return false }
        let current = isCurrent(operation)
        finish(operation)
        guard current else { settleStale(operation); return false }
        let connected = connected && (Self.isReady(status) || (operation.method == .bluetoothBoard && operation.client.hidSetup?.isConnected == true))
        self.status = status; activeMethod = connected ? operation.method : nil; activeBackend = connected ? operation.backend : nil
        settle(); return true
    }
    func beginRelease(owner expectedOwner: Owner? = nil, id: UUID = UUID()) throws -> Operation {
        try requireOwner(expectedOwner)
        guard operations.values.allSatisfy({ $0.kind == .connection || $0.kind == .setup }) else { throw DeviceControlError.busy }
        for task in connectionTasks.values { task.cancel() }
        let operation = register(kind: .release, method: activeMethod ?? selectedMethod, backend: activeBackend, id: id)
        activeMethod = nil; activeBackend = nil; status = Self.disconnected
        state = .releasing(route: operation.method, opID: id)
        return operation
    }
    @discardableResult
    func completeRelease(_ operation: Operation, confirmed: Bool, status: DeviceStatus? = nil) -> Bool {
        guard operation.kind == .release, operations[operation.id]?.token == operation.token else { return false }
        let current = isCurrent(operation); finish(operation)
        if operation.client.device === client.device, operation.method != .bluetoothBoard, !confirmed { hasUnconfirmedRelease = true }
        guard current else { settleStale(operation); return false }
        hasUnconfirmedRelease = operation.method != .bluetoothBoard && !confirmed
        activeMethod = nil; activeBackend = nil
        // A disconnected backend's stale ready cache cannot restore authority.
        if let status, case .unavailable = status { self.status = status } else { self.status = Self.disconnected }
        settle(); confirmedRelease = confirmed ? identity : nil; return true
    }
    @discardableResult
    func connect(method: DeviceConnectionMethod, backend: DeviceControlBackend,
                 configuration: LocalVPNConfiguration = .defaults, owner expectedOwner: Owner? = nil, id: UUID = UUID()) async throws -> DeviceStatus {
        let operation = try beginConnection(method: method, backend: backend, owner: expectedOwner, id: id)
        let task = Task { try await operation.client.connect(method: method, configuration: configuration, backend: backend) }
        connectionTasks[operation.id] = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            let status = await operation.client.status()
            guard isCurrent(operation) else { throw CancellationError() }
            _ = completeConnection(operation, status: status); return status
        } catch {
            let releaseIsOwnedElsewhere = operations.values.contains { $0.kind == .release && $0.client.device === operation.client.device }
            if !releaseIsOwnedElsewhere {
                let released = await operation.client.disconnectAndConfirmRelease()
                if operation.client.device === client.device, method != .bluetoothBoard, !released { hasUnconfirmedRelease = true }
            }
            _ = completeConnection(operation, status: Self.disconnected, connected: false)
            throw error
        }
    }
    /// HID has no owned DisplayService media session: its unconfirmed reply does
    /// not block route selection. The return value still reports the raw confirmation.
    @discardableResult
    func releaseConnection(owner expectedOwner: Owner? = nil, id: UUID = UUID()) async throws -> Bool {
        let pending = Array(connectionTasks.values)
        let pendingOperations = operations.values.filter { $0.kind == .connection }
        let operation = try beginRelease(owner: expectedOwner, id: id)
        for task in pending { _ = await task.result }
        for pendingOperation in pendingOperations { await waitForCompletion(pendingOperation) }
        let confirmed = await operation.client.disconnectAndConfirmRelease()
        let status = await operation.client.status()
        _ = completeRelease(operation, confirmed: confirmed, status: status)
        return confirmed
    }
    func switchRoute(to method: DeviceConnectionMethod, client suppliedClient: DeviceClient? = nil,
                     networkClient suppliedNetwork: DeviceClient? = nil, owner expectedOwner: Owner? = nil) async throws {
        try requireOwner(expectedOwner)
        guard !isTransitioning else { throw DeviceControlError.busy }
        guard method != selectedMethod else { return }
        let target = try selection(method: method, suppliedClient: suppliedClient, suppliedNetwork: suppliedNetwork)
        let wasReleased = confirmedRelease == identity
        let previous = selectedMethod
        let operation = register(kind: .selection, method: activeMethod ?? selectedMethod, backend: activeBackend)
        state = .switching(from: previous, to: method)
        activeMethod = nil; activeBackend = nil; status = Self.disconnected
        let confirmed = wasReleased ? true : await operation.client.disconnectAndConfirmRelease()
        let current = isCurrent(operation); finish(operation)
        if operation.client.device === client.device, operation.method != .bluetoothBoard, !confirmed { hasUnconfirmedRelease = true }
        guard current else { throw CancellationError() }
        hasUnconfirmedRelease = operation.method != .bluetoothBoard && !confirmed
        guard !hasUnconfirmedRelease else { settle(); throw Failure.releaseUnconfirmed }
        do { try Task.checkCancellation() } catch { settle(); throw error }
        client = target.client; networkClient = target.network
        selectedMethod = method; operationID = UUID(); status = Self.disconnected; state = .idle(route: method)
    }
    func selectBackend(_ preference: DeviceControlBackend, owner expectedOwner: Owner? = nil) async throws {
        try requireOwner(expectedOwner)
        guard preference.isAvailable(on: operatingSystemVersion) else { throw DeviceControlError.backendUnavailable(preference) }
        let effective = preference.resolved(on: operatingSystemVersion)
        if isTransitioning {
            guard case .connecting = state,
                  effective == (activeBackend ?? backendPreference.resolved(on: operatingSystemVersion)) else { throw DeviceControlError.busy }
        }
        if preference == backendPreference || selectedMethod == .bluetoothBoard || effective == (activeBackend ?? backendPreference.resolved(on: operatingSystemVersion)) {
            if preference != backendPreference { confirmedRelease = nil }
            backendPreference = preference; return
        }
        guard !isTransitioning else { throw DeviceControlError.busy }
        if confirmedRelease != identity { _ = try await releaseConnection(owner: expectedOwner) }
        guard !hasUnconfirmedRelease else { throw Failure.releaseUnconfirmed }
        backendPreference = preference; confirmedRelease = nil
    }
    @discardableResult
    func updateStatus(_ status: DeviceStatus, expected: Identity? = nil, transportConnected: Bool? = nil) -> Bool {
        guard expected.map(isCurrent) != false else { return false }
        self.status = hasUnconfirmedRelease && Self.isReady(status) ? Self.disconnected : status
        if transportConnected == true || Self.isReady(self.status) { confirmedRelease = nil }
        // Only the operation's completion may publish a newly connected route.
        if isTransitioning, activeMethod == nil, Self.isReady(self.status) { self.status = Self.disconnected }
        if !isTransitioning {
            let connected = !hasUnconfirmedRelease && (transportConnected ?? (activeMethod != nil || Self.isReady(status)))
            activeMethod = connected ? selectedMethod : nil
            activeBackend = connected && selectedMethod != .bluetoothBoard ? activeBackend ?? backendPreference.resolved(on: operatingSystemVersion) : nil
            if !connected, Self.isReady(status) { self.status = Self.disconnected }
            settle()
        }
        return true
    }
    @discardableResult
    func refreshStatus(expected: Identity? = nil, probe: Bool = false, transportConnected: Bool? = nil) async -> Bool {
        let captured = expected ?? identity, target = client
        guard isCurrent(captured) else { return false }
        let value = probe && owner == nil ? await target.probe() : await target.status()
        return updateStatus(value, expected: captured, transportConnected: transportConnected)
    }
    @discardableResult
    func handle(_ event: ExternalEvent, expected: Identity? = nil, status suppliedStatus: DeviceStatus? = nil) -> ExternalOutcome {
        guard expected.map(isCurrent) != false else {
            return .init(event: event, isIgnored: true, invalidatesPreview: false, stopRunID: nil, cancelDictationID: nil, preservesTransport: true)
        }
        let target = client
        confirmedRelease = nil
        let runID: UUID? = { if case .run(let id) = owner { id } else { nil } }()
        let dictationID: UUID? = { if case .dictation(let id) = owner { id } else { nil } }()
        let losesTransport = event == .transportLost || event == .authenticationFailed
        let invalidates = event != .backgrounded
        if invalidates {
            target.device.invalidate()
            for task in connectionTasks.values { task.cancel() }
            operationID = UUID()
            status = suppliedStatus ?? .unavailable(reason: event == .geometryChanged ? DeviceControlError.staleFrame.localizedDescription : DeviceControlError.connectionLost.localizedDescription)
            if losesTransport { activeMethod = nil; activeBackend = nil }
            settle()
        } else if dictationID != nil {
            // Invalidates a captured foreground restoration without disconnecting an idle transport.
            for task in connectionTasks.values { task.cancel() }
            operationID = UUID()
            settle()
        }
        let outcome = ExternalOutcome(event: event, isIgnored: false, invalidatesPreview: invalidates,
            stopRunID: invalidates ? runID : nil, cancelDictationID: dictationID, preservesTransport: !losesTransport)
        if let id = outcome.stopRunID { onExternalStop?(id, event) }
        if let id = outcome.cancelDictationID { onInvalidateDictation?(id, event) }
        onExternalOutcome?(outcome)
        return outcome
    }
    private func settle() { state = activeMethod.map { .connected(route: $0, backend: activeBackend, status: status) } ?? .idle(route: selectedMethod) }
    #if DEBUG
    func debugSeedSnapshot(client suppliedClient: DeviceClient? = nil, networkClient suppliedNetwork: DeviceClient?? = nil,
                           activeMethod suppliedMethod: DeviceConnectionMethod?? = nil, activeBackend suppliedBackend: DeviceControlBackend?? = nil,
                           operationID suppliedID: UUID? = nil, status suppliedStatus: DeviceStatus? = nil, showsConnectionProgress: Bool? = nil) {
        if let suppliedClient { client = suppliedClient }
        if let suppliedNetwork { networkClient = suppliedNetwork }
        if let suppliedMethod { activeMethod = suppliedMethod }
        if let suppliedBackend { activeBackend = suppliedBackend }
        if let suppliedID { operationID = suppliedID }
        if let suppliedStatus { status = suppliedStatus }
        confirmedRelease = nil; generation = UUID()
        if showsConnectionProgress == true { state = .connecting(route: activeMethod ?? selectedMethod, backend: activeBackend, opID: operationID) }
        else { settle() }
    }
    #endif
    private func requireOwner(_ expected: Owner?) throws { guard owner == expected else { throw DeviceControlError.busy } }
    private func register(kind: OperationKind, method: DeviceConnectionMethod, backend: DeviceControlBackend?, id: UUID = UUID()) -> Operation {
        let operation = Operation(id: id, method: method, backend: backend, client: client, kind: kind, leaseID: leaseID,
                                  token: UUID(), hadConnection: activeMethod != nil || Self.isReady(status),
                                  previousActiveMethod: activeMethod, previousActiveBackend: activeBackend, previousStatus: status)
        confirmedRelease = nil; operationID = id; operations[id] = operation; return operation
    }
    private func finish(_ operation: Operation) {
        guard operations[operation.id]?.token == operation.token else { return }
        operations.removeValue(forKey: operation.id); connectionTasks.removeValue(forKey: operation.id)
        for waiter in completionWaiters.removeValue(forKey: operation.token) ?? [] { waiter.resume() }
    }
    private func waitForCompletion(_ operation: Operation) async {
        guard operations[operation.id]?.token == operation.token else { return }
        await withCheckedContinuation { completionWaiters[operation.token, default: []].append($0) }
    }
    private func settleStale(_ operation: Operation) {
        guard operationID == operation.id else { return }
        if operation.kind == .setup { settle(); return }
        switch state {
        case .connecting(_, _, operation.id), .releasing(_, operation.id):
            activeMethod = nil; activeBackend = nil; status = Self.disconnected; settle()
        default: break
        }
    }
    private func selection(method: DeviceConnectionMethod, suppliedClient: DeviceClient?, suppliedNetwork: DeviceClient?) throws -> (client: DeviceClient, network: DeviceClient?) {
        if method == .bluetoothBoard {
            let retained = suppliedNetwork ?? (selectedMethod == .bluetoothBoard ? networkClient : client)
            return (suppliedClient ?? (selectedMethod == .bluetoothBoard ? client : DeviceClient(actuator: bluetooth, hidSetup: bluetooth)),
                    retained?.networkSetup == nil ? nil : retained)
        }
        guard let target = suppliedClient ?? (selectedMethod == .bluetoothBoard ? networkClient : client) else { throw DeviceControlError.routeUnsupported(method) }
        return (target, suppliedNetwork)
    }
    private static var disconnected: DeviceStatus { .unavailable(reason: String(localized: "device.not_connected", table: "Runtime")) }
    private static func isReady(_ status: DeviceStatus) -> Bool { if case .ready = status { true } else { false } }
}

@MainActor
final class DeviceLease {
    let client: DeviceClient
    let owner: DeviceSession.Owner
    let id: UUID
    private weak var session: DeviceSession?
    init(session: DeviceSession, id: UUID, owner: DeviceSession.Owner, client: DeviceClient) {
        self.session = session; self.id = id; self.owner = owner; self.client = client
    }
    func release() { session?.release(owner, id: id); session = nil }
}
