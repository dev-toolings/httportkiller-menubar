// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HTTPPortKiller",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "HTTPPortKillerCore", targets: ["HTTPPortKillerCore"]),
        .executable(name: "HTTPPortKillerApp", targets: ["HTTPPortKillerApp"]),
    ],
    targets: [
        .target(name: "HTTPPortKillerCore"),
        .executableTarget(
            name: "HTTPPortKillerApp",
            dependencies: ["HTTPPortKillerCore"]
        ),
        .testTarget(
            name: "HTTPPortKillerCoreTests",
            dependencies: ["HTTPPortKillerCore"]
        ),
    ]
)
