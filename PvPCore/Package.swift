// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PvPCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PvPCore", targets: ["PvPCore"]),
    ],
    targets: [
        .target(name: "PvPCore"),
        .testTarget(name: "PvPCoreTests", dependencies: ["PvPCore"]),
    ]
)
