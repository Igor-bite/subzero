// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Freezer",
    platforms: [
        .macOS(.v15),
    ],
    targets: [
        .target(
            name: "FreezerCore",
            path: "Sources/FreezerCore"
        ),
        .executableTarget(
            name: "Freezer",
            dependencies: ["FreezerCore"],
            path: "Sources/Freezer"
        ),
        .testTarget(
            name: "FreezerCoreTests",
            dependencies: ["FreezerCore"],
            path: "Tests/FreezerCoreTests"
        ),
    ]
)
