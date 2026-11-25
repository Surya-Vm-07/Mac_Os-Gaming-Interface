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
        .library(name: "AetherUI", targets: ["AetherUI"]),
        .executable(name: "aether", targets: ["AetherCLI"]),
        // Development host for the SwiftUI shell: `swift run AetherApp`.
        // The signed, non-sandboxed .app is an Xcode target that links AetherUI (see README).
        .executable(name: "AetherApp", targets: ["AetherApp"]),
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
        // Phase 2 SwiftUI shell: theme, components, screens, view models.
        .target(
            name: "AetherUI",
            dependencies: ["AetherCore"],
            path: "Sources/AetherUI"
        ),
        .executableTarget(
            name: "AetherApp",
            dependencies: ["AetherUI"],
            path: "Sources/AetherApp"
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
