// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentHUD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "agenthud-hud", targets: ["agenthud-hud"]),
        .library(name: "HUDCore", targets: ["HUDCore"]),
    ],
    targets: [
        .target(
            name: "HUDCore"
        ),
        .executableTarget(
            name: "agenthud-hud",
            dependencies: ["HUDCore"]
        ),
        .testTarget(
            name: "HUDCoreTests",
            dependencies: ["HUDCore"],
            resources: [
                .copy("Fixtures/snapshot.json")
            ]
        ),
    ]
)
