// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RelayCodeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RelayCodeCore", targets: ["RelayCodeCore"]),
    ],
    targets: [
        .target(
            name: "RelayCodeCore",
            path: "RelayCodeCore"
        ),
        .testTarget(
            name: "RelayCodeCoreTests",
            dependencies: ["RelayCodeCore"],
            path: "RelayCodeTests"
        ),
    ]
)
