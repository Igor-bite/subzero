// swift-tools-version: 6.2
import PackageDescription

// Layers, each depends only on the ones above it:
//
//   SubzeroCore    pure models and decisions (IP math, policy verdict, process matching).
//                  Foundation only, no side effects, fully unit-testable.
//   SubzeroSystem  macOS adapters: external IP probes, network/sleep monitors,
//                  process scanning and signals, config file storage.
//   SubzeroEngine  UI-free orchestrator (`GuardEngine`): check loop + enforcement.
//                  Talks to the system through injectable protocols.
//   Subzero        the menu bar app (SwiftUI/AppKit), not part of the public API.
let package = Package(
    name: "Subzero",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SubzeroCore", targets: ["SubzeroCore"]),
        .library(name: "SubzeroSystem", targets: ["SubzeroSystem"]),
        .library(name: "SubzeroEngine", targets: ["SubzeroEngine"]),
        .executable(name: "Subzero", targets: ["Subzero"]),
    ],
    targets: [
        .target(
            name: "SubzeroCore",
            path: "Sources/SubzeroCore"
        ),
        .target(
            name: "SubzeroSystem",
            dependencies: ["SubzeroCore"],
            path: "Sources/SubzeroSystem"
        ),
        .target(
            name: "SubzeroEngine",
            dependencies: ["SubzeroCore", "SubzeroSystem"],
            path: "Sources/SubzeroEngine"
        ),
        .executableTarget(
            name: "Subzero",
            dependencies: ["SubzeroCore", "SubzeroSystem", "SubzeroEngine"],
            path: "Sources/Subzero"
        ),
        .testTarget(
            name: "SubzeroCoreTests",
            dependencies: ["SubzeroCore"],
            path: "Tests/SubzeroCoreTests"
        ),
        .testTarget(
            name: "SubzeroSystemTests",
            dependencies: ["SubzeroCore", "SubzeroSystem"],
            path: "Tests/SubzeroSystemTests"
        ),
        .testTarget(
            name: "SubzeroEngineTests",
            dependencies: ["SubzeroCore", "SubzeroSystem", "SubzeroEngine"],
            path: "Tests/SubzeroEngineTests"
        ),
    ]
)
