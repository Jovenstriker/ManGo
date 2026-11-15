// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PvPCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PvPCore", targets: ["PvPCore"]),
    ],
    targets: [
        // Optimized even in debug builds: the phone checks your buttons and HP bar on every frame
        // (about 60 a second), which unoptimized is several times the work. Same results.
        .target(name: "PvPCore", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // Dev tool: prints the text in a battle recording over time.
        .executableTarget(name: "screen-log", dependencies: ["PvPCore"]),
        // Dev tool: writes a battle report (timeline, energy math, hand counts) for a recording.
        .executableTarget(name: "battle-report", dependencies: ["PvPCore"]),
        .testTarget(name: "PvPCoreTests", dependencies: ["PvPCore"], resources: [.copy("Fixtures")]),
    ]
)
