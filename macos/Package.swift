// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PlinkMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PlinkCore", targets: ["PlinkCore"]),
        .executable(name: "PlinkMac", targets: ["PlinkMac"]),
        .executable(name: "PlinkMacDebugReceiver", targets: ["PlinkMacDebugReceiver"])
    ],
    targets: [
        .target(name: "PlinkCore"),
        .executableTarget(name: "PlinkMac", dependencies: ["PlinkCore"]),
        .executableTarget(name: "PlinkMacDebugReceiver", dependencies: ["PlinkCore"]),
        .testTarget(name: "PlinkCoreTests", dependencies: ["PlinkCore"])
    ]
)
