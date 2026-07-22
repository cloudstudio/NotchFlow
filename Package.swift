// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NotchFlowCore", targets: ["NotchFlowCore"]),
        .library(name: "NotchKit", targets: ["NotchKit"]),
        .executable(name: "NotchFlow", targets: ["NotchApp"]),
        .executable(name: "notchflow-hook", targets: ["NotchFlowHook"]),
        .executable(name: "notchflow-install", targets: ["NotchFlowInstaller"])
    ],
    targets: [
        .target(name: "NotchFlowCore"),
        .target(
            name: "NotchKit",
            dependencies: ["NotchFlowCore"],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "NotchApp",
            dependencies: ["NotchFlowCore", "NotchKit"]
        ),
        .executableTarget(
            name: "NotchFlowHook",
            dependencies: ["NotchFlowCore"]
        ),
        .executableTarget(
            name: "NotchFlowInstaller",
            dependencies: ["NotchFlowCore"]
        ),
        .testTarget(
            name: "NotchFlowCoreTests",
            dependencies: ["NotchFlowCore"]
        ),
        .testTarget(
            name: "NotchKitTests",
            dependencies: ["NotchKit", "NotchFlowCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
