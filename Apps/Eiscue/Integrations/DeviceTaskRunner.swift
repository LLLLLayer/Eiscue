import CryptoKit
import EiscueDeviceKit
import Foundation

enum DeviceDecision: Sendable {
    case observe
    case listApplications
    case action(DeviceAction, frameID: UUID)
}

enum DeviceAction: Codable, Sendable {
    case tap(DevicePoint)
    case swipe(from: DevicePoint, to: DevicePoint, duration: Double)
    case typeText(String)
    case pressKey(DeviceKeyboardAction)
    case home
    case launchApplication(String)

    var capability: DeviceCapability {
        switch self {
        case .tap: .tap
        case .swipe: .swipe
        case .typeText: .textInput
        case .pressKey: .keyboardNavigation
        case .home: .home
        case .launchApplication: .launchApplication
        }
    }

    var toolName: String {
        switch self {
        case .tap: "device_tap"
        case .swipe: "device_swipe"
        case .typeText: "device_type_text"
        case .pressKey: "device_press_key"
        case .home: "device_home"
        case .launchApplication: "device_launch_app"
        }
    }
}

struct DeviceObservation: Sendable {
    let screenshot: DeviceScreenshot
    let feedback: String
}

enum DeviceStepResult: Sendable {
    case observation(DeviceObservation)
    case applications([DeviceApplication])
    case action(DeviceObservation)
}

enum DeviceTaskPhase: Sendable {
    case observing, deciding, executing, verifying, paused, stopped
}

enum DeviceTaskPauseReason: Sendable {
    case noProgress, staleFrames, verificationUnavailable, connectionLost

    var detail: String {
        switch self {
        case .noProgress: String(localized: "toolError.noProgress")
        case .staleFrames: String(localized: "toolError.repeatedStaleFrames")
        case .verificationUnavailable: String(localized: "toolError.verificationUnavailable")
        case .connectionLost: String(localized: "run.paused.connection", table: "Runtime")
        }
    }
}

@MainActor
protocol DeviceDecisionExecuting: AnyObject {
    func step(_ decision: DeviceDecision) async throws -> DeviceStepResult
}

/// Owns the observe → act → verify boundary independently of a model runtime.
@MainActor
final class DeviceTaskRunner: DeviceDecisionExecuting {
    private let capabilities: Set<DeviceCapability>
    private let client: DeviceClient
    private let scope: TaskScope
    private let deadline: ContinuousClock.Instant
    private let maxOperations: Int
    private let log: @MainActor (String, String) async throws -> Void
    private let onUnknown: @MainActor () async -> Void
    private let onObservationWillCapture: @MainActor () async -> Void
    private let onActionFinished: @MainActor () async -> Void
    private let onPhaseChanged: @MainActor (DeviceTaskPhase) -> Void
    private var isActive = true
    private var isExecuting = false
    private var operationCount = 0
    private var latestFrame: DeviceObservationCoordinates?
    private var latestScreenDigest: Data?
    private var actionCounts: [Data: Int] = [:]
    private var unverifiedAction: (screen: Data, action: Data)?
    private var consecutiveFrameRejections = 0
    private(set) var hasStartedExecution = false
    private(set) var hasUnknownOutcome = false
    private(set) var phase: DeviceTaskPhase = .deciding
    private(set) var pauseReason: DeviceTaskPauseReason?

    init(capabilities: Set<DeviceCapability> = Set(DeviceCapability.allCases), client: DeviceClient,
         scope: TaskScope, timeoutSeconds: Int, maxOperations: Int = 30,
         log: @escaping @MainActor (String, String) async throws -> Void,
         onUnknown: @escaping @MainActor () async -> Void,
         onObservationWillCapture: @escaping @MainActor () async -> Void = {},
         onActionFinished: @escaping @MainActor () async -> Void = {},
         onPhaseChanged: @escaping @MainActor (DeviceTaskPhase) -> Void = { _ in }) {
        self.capabilities = capabilities; self.client = client; self.scope = scope
        self.maxOperations = max(0, maxOperations)
        deadline = .now.advanced(by: .seconds(timeoutSeconds))
        self.log = log; self.onUnknown = onUnknown
        self.onObservationWillCapture = onObservationWillCapture; self.onActionFinished = onActionFinished
        self.onPhaseChanged = onPhaseChanged
    }

    func stop() {
        isActive = false; latestFrame = nil
        transition(to: .stopped)
    }

    /// Decoding errors use the same failed-decision boundary as typed calls;
    /// releasing the held transcript invalidates its previously observed frame.
    func rejectInvalidDecision(_ error: DeviceTaskError) async throws -> Never {
        try check()
        guard !isExecuting else { throw DeviceTaskError.busy }
        isExecuting = true
        defer { isExecuting = false }
        do {
            guard scope == .control else { throw DeviceTaskError.scope }
            try reserve(2)
            switch error {
            case .frame, .arguments, .scope: throw error
            default: throw DeviceTaskError.arguments
            }
        } catch { throw await finishFailure(error, action: true) }
    }

    func step(_ decision: DeviceDecision) async throws -> DeviceStepResult {
        try check()
        guard !isExecuting else { throw DeviceTaskError.busy }
        isExecuting = true
        defer { isExecuting = false }
        do {
            switch decision {
            case .observe:
                try require(.screenshot)
                try reserve(1)
                hasStartedExecution = true
                transition(to: .observing)
                return .observation(try await capture(afterAction: false))
            case .listApplications:
                try require(.listApplications)
                try reserve(1)
                hasStartedExecution = true
                try await record("observation.prepared", "device_list_apps")
                try check()
                let apps = try await client.listApplications()
                try check()
                transition(to: .deciding)
                try check()
                return .applications(apps)
            case .action(let action, let frameID):
                guard scope == .control else { throw DeviceTaskError.scope }
                try require(action.capability)
                try require(.screenshot)
                // Every decision attempt consumes its bounded allocation;
                // malformed typed input cannot bypass the run's operation limit.
                try reserve(2)
                let frame = try frame(for: frameID)
                try validate(action, width: frame.width, height: frame.height)
                let digest = try actionDigest(action)
                if actionCounts[digest, default: 0] >= 2 {
                    throw pause(.noProgress)
                }
                hasStartedExecution = true
                latestFrame = nil
                transition(to: .executing)
                try await record("action.prepared", action.toolName)
                try check()
                try await record("action.dispatched", action.toolName)
                try check()
                try await dispatch(action, frame: frame)
                try check()
                try await record("action.acknowledged", action.toolName)
                consecutiveFrameRejections = 0
                if let screen = latestScreenDigest { unverifiedAction = (screen, digest) }
                // Publish the completed step before freezing its next observation.
                await onActionFinished()
                try check()
                transition(to: .verifying)
                return .action(try await capture(afterAction: true))
            }
        } catch let error as DeviceControlError where error.isDeliveryUnknown {
            markUnknown()
            try? await log("action.unknown", decision.actionName ?? "device_screenshot")
            await onActionFinished()
            throw error
        } catch {
            throw await finishFailure(error, action: decision.actionName != nil)
        }
    }

    private func capture(afterAction: Bool) async throws -> DeviceObservation {
        latestFrame = nil
        try await record("observation.prepared", "device_screenshot")
        await onObservationWillCapture()
        try check()
        let nativeImage: DeviceScreenshot
        let image: DeviceScreenshot
        do {
            nativeImage = try await client.captureScreenshot()
            try check()
            image = try DeviceObservationImage.prepare(nativeImage)
        }
        catch {
            try check()
            if error is CancellationError { throw error }
            if afterAction {
                // Input was acknowledged; losing its visual result must not
                // turn into an ordinary model retry of that same input.
                throw pause(.verificationUnavailable)
            }
            throw error
        }
        try check()
        guard image.width > 0, image.height > 0, !image.data.isEmpty else {
            if afterAction { throw pause(.verificationUnavailable) }
            throw DeviceTaskError.arguments
        }
        let feedback = observe(image)
        try await record("observation.captured", "width=\(image.width);height=\(image.height);frame=\(image.frameID.uuidString)")
        try check()
        latestFrame = DeviceObservationCoordinates(id: image.frameID, width: image.width, height: image.height,
                                                   nativeWidth: nativeImage.width, nativeHeight: nativeImage.height)
        transition(to: .deciding)
        try check()
        return DeviceObservation(screenshot: image, feedback: feedback)
    }

    private func dispatch(_ action: DeviceAction, frame: DeviceObservationCoordinates) async throws {
        switch action {
        case .tap(let point): try await client.tap(at: frame.nativePoint(point), frameID: frame.id)
        case .swipe(let from, let to, let duration):
            try await client.swipe(from: frame.nativePoint(from), to: frame.nativePoint(to),
                                   duration: .seconds(duration), frameID: frame.id)
        case .typeText(let text): try await client.typeText(text, frameID: frame.id)
        case .pressKey(let key): try await client.pressKey(key, frameID: frame.id)
        case .home: try await client.home()
        case .launchApplication(let bundleID): try await client.launchApplication(bundleID: bundleID)
        }
    }

    private func frame(for id: UUID) throws -> DeviceObservationCoordinates {
        // The controller owns freshness, including ReplayKit's heartbeat rule
        // for an unchanged screen whose JPEG timestamp can be older than 30 s.
        guard let frame = latestFrame, frame.id == id else { throw DeviceTaskError.frame }
        return frame
    }

    private func validate(_ action: DeviceAction, width: Int, height: Int) throws {
        func pointIsValid(_ point: DevicePoint) -> Bool {
            point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0
                && point.x < Double(width) && point.y < Double(height)
        }
        switch action {
        case .tap(let point): guard pointIsValid(point) else { throw DeviceTaskError.arguments }
        case .swipe(let from, let to, let duration):
            guard pointIsValid(from), pointIsValid(to), duration.isFinite, (0.1...2).contains(duration) else { throw DeviceTaskError.arguments }
        case .typeText(let text):
            guard !text.isEmpty, text.count <= 4096, text.utf8.count <= 8192 else { throw DeviceTaskError.arguments }
        case .launchApplication(let bundle):
            guard !bundle.isEmpty, bundle.utf8.count <= 255,
                  bundle.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else { throw DeviceTaskError.arguments }
        case .pressKey, .home: break
        }
    }

    private func observe(_ image: DeviceScreenshot) -> String {
        var hash = SHA256()
        hash.update(data: Data("\(image.width):\(image.height):\(image.mimeType):".utf8))
        hash.update(data: image.data)
        let digest = Data(hash.finalize())
        if digest != latestScreenDigest { actionCounts.removeAll() }
        latestScreenDigest = digest
        defer { unverifiedAction = nil }
        guard let previous = unverifiedAction, previous.screen == digest else { return "" }
        actionCounts[previous.action, default: 0] += 1
        let repeats = actionCounts[previous.action, default: 0]
        return " Screen pixels are unchanged after the last submitted action (\(repeats) identical submissions on this screen). This is not evidence of success. Reassess the visible controls and choose another route; a third identical action on an unchanged screen will pause the task."
    }

    private func actionDigest(_ action: DeviceAction) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try encoder.encode(action)))
    }

    private func record(_ kind: String, _ detail: String) async throws {
        do { try await log(kind, detail) }
        catch {
            // Continuing without durable host state is unsafe, including a
            // failed preflight log before the next input has been dispatched.
            markUnknown()
            throw error
        }
    }

    private func markUnknown() {
        guard !hasUnknownOutcome else { return }
        hasUnknownOutcome = true
        stop()
        Task { await onUnknown() }
    }

    private func reserve(_ count: Int) throws {
        guard maxOperations - operationCount >= count else {
            isActive = false; latestFrame = nil; transition(to: .paused)
            throw DeviceTaskError.budget
        }
        operationCount += count
    }

    private func require(_ capability: DeviceCapability) throws {
        guard scope != .chat, capabilities.contains(capability) else { throw DeviceTaskError.scope }
    }

    private func check() throws {
        if Task.isCancelled { stop(); throw CancellationError() }
        guard isActive else { throw DeviceTaskError.stopped }
        guard .now < deadline else { stop(); throw DeviceTaskError.expired }
    }

    private func pause(_ reason: DeviceTaskPauseReason) -> DeviceTaskError {
        pauseReason = reason
        isActive = false; latestFrame = nil; transition(to: .paused)
        return .paused(reason.detail)
    }

    private func transition(to value: DeviceTaskPhase) {
        phase = value; onPhaseChanged(value)
    }

    private func isFrameRejection(_ error: Error) -> Bool {
        if case DeviceTaskError.frame = error { return true }
        return (error as? DeviceControlError) == .staleFrame
    }

    private func finishFailure(_ error: Error, action: Bool) async -> Error {
        latestFrame = nil
        await onActionFinished()
        if error is CancellationError || Task.isCancelled {
            stop()
            return CancellationError()
        }
        if isActive, let deviceError = error as? DeviceControlError {
            let connectionLost: Bool
            switch deviceError {
            case .notConnected: connectionLost = true
            case .connection:
                // An optional service can fail while screen control remains
                // usable. Pause only when the controller lost readiness.
                if case .unavailable = await client.status() { connectionLost = true }
                else { connectionLost = false }
            default: connectionLost = false
            }
            if Task.isCancelled { stop(); return CancellationError() }
            if isActive, connectionLost { return pause(.connectionLost) }
        }
        if action, isFrameRejection(error), isActive {
            consecutiveFrameRejections += 1
            if consecutiveFrameRejections >= 3 { return pause(.staleFrames) }
        }
        if isActive { transition(to: .deciding) }
        return error
    }
}

private extension DeviceDecision {
    var actionName: String? {
        if case .action(let action, _) = self { action.toolName } else { nil }
    }
}

enum DeviceTaskError: LocalizedError {
    case stopped, expired, scope, frame, arguments, busy, budget, paused(String)

    var errorDescription: String? {
        switch self {
        case .stopped: String(localized: "toolError.stopped")
        case .expired: String(localized: "toolError.expired")
        case .scope: String(localized: "toolError.scope")
        case .frame: String(localized: "toolError.frame")
        case .arguments: String(localized: "toolError.arguments")
        case .busy: String(localized: "toolError.busy")
        case .budget: String(localized: "run.paused.toolLimit", table: "Runtime")
        case .paused(let reason): reason
        }
    }
}
