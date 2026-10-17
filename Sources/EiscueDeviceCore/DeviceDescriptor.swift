public enum DevicePlatform: String, Codable, Sendable {
    case iOS
    case iPadOS
    case macOS
    case android
    case harmonyOS
}

/// Display metadata supplied by the host, independent of control availability.
public struct DeviceDescriptor: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let platform: DevicePlatform
    public let systemVersion: String

    public init(id: String, name: String, platform: DevicePlatform, systemVersion: String) {
        self.id = id
        self.name = name
        self.platform = platform
        self.systemVersion = systemVersion
    }
}
