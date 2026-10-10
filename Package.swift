// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Eiscue",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EiscueAgentKit", targets: ["EiscueAgentKit"]),
        .library(name: "EiscueDeviceKit", targets: ["EiscueDeviceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/finnvoor/PiDurableKit.git", revision: "6e7f267181500943db328bbe2a262ae17b39bef1"),
    ],
    targets: [
        .target(name: "EiscueAgentKit", dependencies: [.product(name: "PiDurableKit", package: "PiDurableKit")],
                resources: [.process("Resources")]),
        .binaryTarget(name: "NCMNativeBackend", path: "Vendor/DeviceBackend/Frameworks/NCMNativeBackend.xcframework"),
        .target(
            name: "CNCMBackend", dependencies: ["NCMNativeBackend"],
            path: "Vendor/DeviceBackend/Sources/CNCMBackend", publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration")]
        ),
        .target(
            name: "PhoneAgentNCM", dependencies: ["CNCMBackend"],
            path: "Vendor/DeviceBackend/Sources/PhoneAgentNCM", swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "EiscueDeviceKit", dependencies: ["PhoneAgentNCM"], resources: [.process("Resources")]),
        .testTarget(name: "EiscueAgentKitTests", dependencies: ["EiscueAgentKit", .product(name: "PiDurableKit", package: "PiDurableKit")]),
        .testTarget(name: "EiscueDeviceKitTests", dependencies: ["EiscueDeviceKit"]),
    ]
)
