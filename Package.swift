// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HP136wDuplex",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "hpduplex", targets: ["hpduplex"])
    ],
    targets: [
        .target(
            name: "DuplexCore",
            path: "Sources/DuplexCore"
        ),
        .executableTarget(
            name: "hpduplex",
            dependencies: ["DuplexCore"],
            path: "Sources/hpduplex"
        ),
        .testTarget(
            name: "DuplexCoreTests",
            dependencies: ["DuplexCore"],
            path: "Tests/DuplexCoreTests"
        )
    ]
)