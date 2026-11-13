// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Subzero",
    platforms: [
        .macOS(.v15),
    ],
    targets: [
        .target(
            name: "SubzeroCore",
            path: "Sources/SubzeroCore"
        ),
        .executableTarget(
            name: "Subzero",
            dependencies: ["SubzeroCore"],
            path: "Sources/Subzero"
        ),
        .testTarget(
            name: "SubzeroCoreTests",
            dependencies: ["SubzeroCore"],
            path: "Tests/SubzeroCoreTests"
        ),
    ]
)
