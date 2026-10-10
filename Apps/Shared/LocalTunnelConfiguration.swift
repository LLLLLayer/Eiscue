import Foundation

/// Shared by the host App and its packet tunnel extension. This tunnel only
/// reflects the local device-control peer; it does not provide Internet access.
enum LocalTunnelConfiguration {
    static let interfaceAddress = "10.7.1.1"
    static let interfaceSubnetMask = "255.255.255.0"
    static let peerAddress = "10.7.0.1"
    static let peerSubnetMask = "255.255.255.255"
    static let schemaVersion = 1
    static let schemaVersionKey = "schemaVersion"
    static let providerBundleSuffix = ".tunnel"
}
