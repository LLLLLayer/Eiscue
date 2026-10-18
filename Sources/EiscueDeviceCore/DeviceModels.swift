import Foundation

/// The host selects one transport explicitly. Selection never starts a VPN,
/// changes the default route, or falls back to the other transport.
public enum DeviceConnectionMethod: String, Codable, Sendable, CaseIterable {
    case bluetoothBoard
    case localVPN
    case usbBoard
}

/// Developer-services control selection for local VPN and USB network routes.
/// Automatic resolves once per connection; explicit choices never fall back.
public enum DeviceControlBackend: String, Codable, Sendable, CaseIterable {
    case automatic
    case coreDevice
    case xcTest

    public func resolved(on version: OperatingSystemVersion) -> Self {
        self == .automatic ? (version.majorVersion >= 27 ? .coreDevice : .xcTest) : self
    }

    public func isAvailable(on version: OperatingSystemVersion) -> Bool {
        switch resolved(on: version) {
        case .automatic: false
        case .coreDevice: version.majorVersion >= 27
        case .xcTest: version.majorVersion >= 26
        }
    }
}

public struct LocalVPNConfiguration: Codable, Sendable, Equatable {
    public var localAddress: String
    public var peerAddress: String
    public static let defaults = Self(localAddress: "10.7.1.1", peerAddress: "10.7.0.1")
    public init(localAddress: String, peerAddress: String) {
        self.localAddress = localAddress
        self.peerAddress = peerAddress
    }
}

public struct DevicePoint: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct DeviceScreenshot: Sendable, Equatable {
    public let frameID: UUID
    public let capturedAt: Date
    public let width: Int
    public let height: Int
    public let mimeType: String
    public let data: Data
    public let geometry: DeviceFrameGeometry?
    public init(frameID: UUID = UUID(), capturedAt: Date = Date(), width: Int, height: Int, mimeType: String, data: Data, geometry: DeviceFrameGeometry? = nil) {
        self.frameID = frameID; self.capturedAt = capturedAt
        self.width = width; self.height = height; self.mimeType = mimeType; self.data = data; self.geometry = geometry
    }
}

public struct DeviceApplication: Identifiable, Codable, Sendable, Equatable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

public enum DevicePairingEvent: Sendable, Equatable {
    case waitingForDevice
    case code(String)
    case identitySaved
    case completed
}

public enum DeviceControlError: Error, LocalizedError, Sendable, Equatable {
    case unsupported, notConnected, busy, noIdentity, invalidIdentity, pairingAlreadyExists
    case connectionLost
    case serviceUnavailable(DeviceService)
    case capabilityUnavailable(DeviceCapability)
    case routeUnsupported(DeviceConnectionMethod)
    case systemPairingUnavailable
    case backendUnavailable(DeviceControlBackend)
    case staleFrame, invalidCoordinates, invalidDuration, invalidText, invalidBundleID
    case relativeDragUnrepresentable
    case keychain(Int32)
    case connection(String)
    case deliveryUnknown(String)

    public var isDeliveryUnknown: Bool {
        if case .deliveryUnknown = self { true } else { false }
    }

    public var errorDescription: String? {
        switch self {
        case .connectionLost: String(localized: "device.error.connection-lost", defaultValue: "Device connection lost. Reconnect the device.", bundle: .module)
        case .serviceUnavailable: String(localized: "device.error.service-unavailable", defaultValue: "This device service is unavailable. Other device services may still work.", bundle: .module)
        case .capabilityUnavailable: String(localized: "device.error.capability-unavailable", defaultValue: "This action is unavailable on the selected device connection.", bundle: .module)
        case .routeUnsupported: String(localized: "device.error.route-unsupported", defaultValue: "The selected connection does not support this route.", bundle: .module)
        case .unsupported: String(localized: "device.error.unsupported", defaultValue: "Local device control needs a physical iOS device. This connection is unavailable on simulators and Macs.", bundle: .module)
        case .notConnected: String(localized: "device.error.not-connected", defaultValue: "Device not connected. Complete pairing, then connect using your selected method.", bundle: .module)
        case .busy: String(localized: "device.error.busy", defaultValue: "The device is busy. Wait for the current operation to finish.", bundle: .module)
        case .noIdentity: String(localized: "device.error.no-identity", defaultValue: "System pairing is incomplete. Pair the device or import a pairing file for this app.", bundle: .module)
        case .invalidIdentity: String(localized: "device.error.invalid-identity", defaultValue: "The pairing identity is invalid or incomplete. A completed version 1 RemotePairing identity is required.", bundle: .module)
        case .pairingAlreadyExists: String(localized: "device.error.pairing-exists", defaultValue: "Pairing is already saved. Remove it locally before pairing again.", bundle: .module)
        case .systemPairingUnavailable: String(localized: "device.error.system-pairing-unavailable", defaultValue: "Pairing from Settings requires iOS 27 or later. On iOS 26, import a compatible RemotePairing file created on a computer.", bundle: .module)
        case .backendUnavailable(.coreDevice): String(localized: "device.error.core-device-unavailable", defaultValue: "CoreDevice control requires iOS 27 or later. Select XCTest on iOS 26.", bundle: .module)
        case .backendUnavailable(.automatic), .backendUnavailable(.xcTest): String(localized: "device.error.xctest-unavailable", defaultValue: "XCTest control requires iOS 26 or later.", bundle: .module)
        case .staleFrame: String(localized: "device.error.stale-frame", defaultValue: "The screenshot expired, was used, or belongs to an old connection. Take a new screenshot before acting.", bundle: .module)
        case .invalidCoordinates: String(localized: "device.error.invalid-coordinates", defaultValue: "Coordinates must be inside the current screenshot.", bundle: .module)
        case .invalidDuration: String(localized: "device.error.invalid-duration", defaultValue: "Swipe duration must be between 0.1 and 2 seconds.", bundle: .module)
        case .relativeDragUnrepresentable: String(localized: "device.error.relative-drag-unrepresentable", defaultValue: "This swipe exceeds the calibrated movement or timing limits. Try a shorter swipe or a different duration.", bundle: .module)
        case .invalidText: String(localized: "device.error.invalid-text", defaultValue: "Input text must not be empty or exceed 8 KB in UTF-8. The encoded request must not exceed 16 KB.", bundle: .module)
        case .invalidBundleID: String(localized: "device.error.invalid-bundle-id", defaultValue: "The app bundle ID is invalid.", bundle: .module)
        case .keychain(let status): String(localized: "device.error.keychain", defaultValue: "Could not access secure storage (\(String(describing: status))).", bundle: .module)
        case .connection(let message): message
        case .deliveryUnknown(let message): String(localized: "device.error.delivery-unknown", defaultValue: "The action may have reached the device. Do not repeat it. \(String(describing: message)) Reconnect and view the screen to check the result.", bundle: .module)
        }
    }
}

public enum DeviceService: String, Codable, Sendable { case screen, input, applicationList, developerServices, bluetooth }
