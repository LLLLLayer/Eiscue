import Foundation
#if os(iOS)
import UIKit
#endif

public enum DeviceCapability: String, Codable, Sendable, CaseIterable {
    case screenshot, tap, swipe, textInput, launchApplication, home, listApplications, keyboardNavigation
}
public enum DeviceKeyboardAction: String, Codable, Sendable, CaseIterable { case search, enter, escape }
public enum DeviceStatus: Sendable, Equatable {
    case unavailable(reason: String)
    case ready(capabilities: Set<DeviceCapability>)
}

public enum DeviceAction: Sendable, Equatable {
    case tap(DevicePoint), swipe(DevicePoint, DevicePoint, Duration)
    case typeText(String), pressKey(DeviceKeyboardAction), home, launch(bundleID: String)

    public var capability: DeviceCapability {
        switch self {
        case .tap: .tap
        case .swipe: .swipe
        case .typeText: .textInput
        case .pressKey: .keyboardNavigation
        case .home: .home
        case .launch: .launchApplication
        }
    }
    var points: [DevicePoint] {
        switch self { case .tap(let p): [p]; case .swipe(let a, let b, _): [a, b]; default: [] }
    }
}

/// A route's coordinate space. Revisions must change even when a display rotates
/// back to its original dimensions. New pixels alone do not change this identity.
public struct DeviceFrameGeometry: Sendable, Equatable {
    public let sessionID: UUID
    public let revision: String
    public let width: Int
    public let height: Int
    public init(sessionID: UUID, revision: String, width: Int, height: Int) {
        self.sessionID = sessionID; self.revision = revision; self.width = width; self.height = height
    }
}
public struct DeviceFrameState: Sendable, Equatable {
    public let geometry: DeviceFrameGeometry
    public let isLive: Bool
    /// ReplayKit's latest publication or heartbeat confirmation. Nil means a
    /// native session without ReplayKit's separate stream-liveness requirement.
    public let confirmedUptime: TimeInterval?
    public init(geometry: DeviceFrameGeometry, isLive: Bool, confirmedUptime: TimeInterval? = nil) {
        self.geometry = geometry; self.isLive = isLive; self.confirmedUptime = confirmedUptime
    }
}
public struct FrameGrant: Sendable, Equatable {
    public let frameID: UUID
    public let geometry: DeviceFrameGeometry
    public let issuedUptime: TimeInterval
    static func permits(decisionIssuedUptime: TimeInterval, currentConfirmedUptime: TimeInterval?, now: TimeInterval) -> Bool {
        let age = now - decisionIssuedUptime
        guard age.isFinite, age >= 0, age < 30 else { return false }
        guard let confirmed = currentConfirmedUptime else { return true }
        let streamAge = now - confirmed
        return streamAge.isFinite && streamAge >= 0 && streamAge <= ScreenBroadcastStore.maximumFrameAge
    }
    init(frameID: UUID, geometry: DeviceFrameGeometry, issuedUptime: TimeInterval) {
        self.frameID = frameID; self.geometry = geometry; self.issuedUptime = issuedUptime
    }
}
public enum SubmissionResult: Sendable, Equatable {
    case submitted
    /// Returned only when the backend can prove that input was never submitted.
    case notSubmitted(DeviceControlError)
}
public enum ReleaseConfirmation: Sendable, Equatable { case confirmed, unconfirmed }

/// Replaceable execution surface. There are deliberately no default operations.
/// A perform error after entry is conservatively treated as an unknown outcome;
/// implementations must return notSubmitted for a proven pre-dispatch rejection.
public protocol DeviceActuator: Sendable {
    func cachedStatus() async -> DeviceStatus
    func probe() async -> DeviceStatus
    /// Attach the capture's coordinate-space geometry. A screenshot without a
    /// bound geometry is display-only and cannot authorize input.
    func capture() async throws -> DeviceScreenshot
    func frameState() async throws -> DeviceFrameState
    func perform(_ action: DeviceAction, frame: FrameGrant) async throws -> SubmissionResult
    func releaseInput() async throws
    func disconnect() async -> ReleaseConfirmation
    func listApplications() async throws -> [DeviceApplication]
}

public protocol NetworkRouteSetup: Sendable {
    func hasPairingIdentity() async throws -> Bool
    func importPairingIdentity(_ data: Data) async throws
    func removePairingIdentity() async throws
    func beginPairing() async -> AsyncThrowingStream<DevicePairingEvent, Error>
    func beginPairing(configuration: LocalVPNConfiguration) async -> AsyncThrowingStream<DevicePairingEvent, Error>
    func connectLocalVPN(configuration: LocalVPNConfiguration, backend: DeviceControlBackend) async throws
    func connectUSBBoard(backend: DeviceControlBackend) async throws
    #if DEBUG
    func probeLegacyDeveloperServices(configuration: LocalVPNConfiguration) async throws -> Data
    #endif
}
@MainActor public protocol HIDRouteSetup: Sendable {
    var isConnected: Bool { get }
    var isCalibrating: Bool { get }
    var isInputReady: Bool { get }
    var isPointerVerified: Bool { get }
    var inputRoute: BluetoothBoardInputRoute { get }
    var outputInfo: BluetoothBoardOutputInfo? { get }
    var screenState: ScreenBroadcastState? { get }
    var supportsCompanionDisplay: Bool { get }
    var isHardwareStopLatched: Bool { get }
    var onChange: (@MainActor () -> Void)? { get set }
    var onHardwareStop: (@MainActor (BluetoothHardwareStopEvent) -> Void)? { get set }
    func connectBluetoothBoard() async throws
    func selectInputRoute(_ route: BluetoothBoardInputRoute) throws
    func refreshScreenState() async
    func stopSharing() async throws
    func cancelCalibration() async
    func updateCompanionStatus(_ status: BluetoothCompanionStatus)
    func calibrationClick(x: Double, y: Double) async throws
    func completeCalibration(observed: [DevicePoint]) async throws
    func markKeyboardVerified() async throws
    func pasteCalibrationText(_ text: String, frameID: UUID) async throws
    #if os(iOS)
    func beginCalibration(window: UIWindow, viewport: UIView) async throws
    #endif
}

/// Shared limits used by tools and route-independent execution.
public enum DeviceInputValidation {
    public static let maximumTextBytes = 8 * 1024
    public static let maximumEncodedTextBytes = 16 * 1024
    public static let maximumBundleIDBytes = 255
    public static let minimumSwipeSeconds = 0.1
    public static let maximumSwipeSeconds = 2.0
    public static let minimumSwipeDuration: Duration = .milliseconds(100)
    public static let maximumSwipeDuration: Duration = .seconds(2)
    public static func swipeDuration(seconds: Double) throws -> Duration {
        guard seconds.isFinite, (minimumSwipeSeconds...maximumSwipeSeconds).contains(seconds) else { throw DeviceControlError.invalidDuration }
        return .seconds(seconds)
    }
    public static func text(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= maximumTextBytes, !text.utf8.contains(0),
              let payload = try? JSONSerialization.data(withJSONObject: ["text": text]), payload.count <= maximumEncodedTextBytes else {
            throw DeviceControlError.invalidText
        }
    }
    public static func bundleID(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBundleIDBytes,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46].contains($0) }) else {
            throw DeviceControlError.invalidBundleID
        }
    }
    public static func action(_ action: DeviceAction, geometry: DeviceFrameGeometry) throws {
        guard action.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 && $0.x < Double(geometry.width) && $0.y < Double(geometry.height) }) else { throw DeviceControlError.invalidCoordinates }
        switch action {
        case .swipe(_, _, let duration):
            guard duration >= minimumSwipeDuration, duration <= maximumSwipeDuration else { throw DeviceControlError.invalidDuration }
        case .typeText(let value): try text(value)
        case .launch(let value): try bundleID(value)
        default: break
        }
    }
}
