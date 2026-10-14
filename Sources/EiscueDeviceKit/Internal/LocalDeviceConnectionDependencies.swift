import Foundation
@preconcurrency import PhoneAgentNCM

/// Internal seams exercise lifecycle and transport isolation without attaching
/// a device or starting a VPN. Production uses the native implementations only.
@MainActor protocol LocalVPNDiscovering: AnyObject, Sendable {
    func discoverPort(configuration: VPNLoopbackConfiguration) async throws -> UInt16
    func cancel()
}
extension LocalVPNDiscovery: LocalVPNDiscovering {}

@MainActor protocol USBBoardDiscovering: AnyObject, Sendable {
    func discoverRemotePairing() async throws -> NCMDiscoveredEndpoint
    func cancel()
}
extension NCMProbeClient: USBBoardDiscovering {}

@MainActor protocol LocalDeviceSession: AnyObject, Sendable {
    var supportedControlActions: Set<NativeControlAction> { get }
    func connectLocalVPN(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                         pairingPort: UInt16, configuration: VPNLoopbackConfiguration) async throws
    func connect(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                 discovery: NCMDiscoveredEndpoint) async throws
    func checkDeveloperReadiness() async throws
    func startTouchMedia() async throws
    func stopTouchMediaWhenIdle() async throws -> Bool
    func close()
    func captureVideoJPEGWithGeometry() async throws -> NativeVideoSnapshot
    func currentVideoGeometry() async throws -> NativeVideoGeometry?
    func tapDelivery(x: UInt16, y: UInt16) async throws -> InputDelivery
    func dragDelivery(fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16) async throws -> InputDelivery
    func typeText(_ text: String) async throws
    func launchApplication(bundleID: String, arguments: [String]) async throws
    func home() async throws
    func installedApplications() async throws -> Data
}
extension LocalDeviceSession {
    var supportedControlActions: Set<NativeControlAction> { Set(NativeControlAction.allCases) }
}
extension NativeDeveloperServices: LocalDeviceSession {}

struct LocalDeviceConnectionDependencies: Sendable {
    let supportsPhysicalDevice: Bool
    let makeSession: @MainActor @Sendable () -> any LocalDeviceSession
    let makeVPNDiscovery: @MainActor @Sendable () -> any LocalVPNDiscovering
    let makeBoardDiscovery: @MainActor @Sendable () -> any USBBoardDiscovering

    init(supportsPhysicalDevice: Bool,
         makeSession: @escaping @MainActor @Sendable () -> any LocalDeviceSession,
         makeVPNDiscovery: @escaping @MainActor @Sendable () -> any LocalVPNDiscovering,
         makeBoardDiscovery: @escaping @MainActor @Sendable () -> any USBBoardDiscovering) {
        self.supportsPhysicalDevice = supportsPhysicalDevice
        self.makeSession = makeSession
        self.makeVPNDiscovery = makeVPNDiscovery
        self.makeBoardDiscovery = makeBoardDiscovery
    }

    static let live = Self(
        supportsPhysicalDevice: {
            #if os(iOS) && !targetEnvironment(simulator)
            true
            #else
            false
            #endif
        }(),
        makeSession: { NativeDeveloperServices() },
        makeVPNDiscovery: { LocalVPNDiscovery() },
        makeBoardDiscovery: { NCMProbeClient() }
    )
}
