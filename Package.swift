// swift-tools-version: 6.0
// Project Aether — Phase 1 engine core.
//
// Tools version 6.0 => Swift 6 language mode (strict concurrency) for every target.
// Zero third-party dependencies by design.

import PackageDescription

let package = Package(
    name: "Aether",
    platforms: [
        // macOS 15 gives us `Synchronization.Mutex`, modern URL APIs and Swift Testing.
        .macOS(.v15)
    ],
    products: [
        .library(name: "AetherCore", targets: ["AetherCore"]),
        .executable(name: "aether", targets: ["AetherCLI"]),
    ],
    targets: [
        // Engine core: models, hardware profiler, router, manifest loader, bottle engine.
        // The SwiftUI app target (Phase 2) links this library.
        .target(
            name: "AetherCore",
            path: "Sources/AetherCore",
            resources: [
                .copy("Resources/Profiles"),
                .copy("Resources/Scripts"),
            ]
        ),
        // Phase 1 CLI proof-of-concept: `aether hw | profiles | route | launch`.
        .executableTarget(
            name: "AetherCLI",
            dependencies: ["AetherCore"],
            path: "Sources/AetherCLI"
        ),
        .testTarget(
            name: "AetherCoreTests",
            dependencies: ["AetherCore"],
            path: "Tests/AetherCoreTests"
        ),
    ]
)
