import Foundation

/// Well-known on-disk locations. Non-sandboxed, so these are the real `~/Library` paths.
public enum AetherPaths {
    /// `~/Library/Application Support/Aether`
    public static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: "Aether", directoryHint: .isDirectory)
    }

    /// One Wine prefix per game: `~/Library/Application Support/Aether/Bottles/<id>`.
    public static var bottles: URL {
        applicationSupport.appending(path: "Bottles", directoryHint: .isDirectory)
    }

    /// User and community profile overrides: `~/Library/Application Support/Aether/Profiles`.
    public static var userProfiles: URL {
        applicationSupport.appending(path: "Profiles", directoryHint: .isDirectory)
    }

    /// Downloaded artwork: `~/Library/Caches/Aether/Artwork`. The OS may purge it, which is fine.
    public static var artworkCache: URL {
        URL.cachesDirectory.appending(path: "Aether/Artwork", directoryHint: .isDirectory)
    }

    /// Shared engine data, also used by the setup wizard: Wine runtimes (`runtimes/`) and
    /// graphics components (`components/`) live in `~/Library/Application Support/Aether Launcher`.
    public static var engineRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Aether Launcher", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/Aether/play_history.json`
    public static var playHistory: URL {
        applicationSupport.appending(path: "play_history.json")
    }

    public static func bottle(for gameID: String) -> URL {
        bottles.appending(path: gameID, directoryHint: .isDirectory)
    }
}

/// How `BottleEngine` starts Wine.
public enum LaunchMode: Sendable, Equatable {
    /// Phase 1 path: `launch_d3dmetal.sh` with an external GPTK Wine and a D3DMetal library folder.
    case gptkScript
    /// Self-contained runtime from `WineRuntimeStore`: exec `wine` directly. The Gcenx build is a
    /// plain x86_64 binary, so macOS runs it under Rosetta itself, with no `arch` or `DYLD_*` needed.
    case direct
}

/// Where the Wine toolchain lives on this Mac.
public struct BottleRuntime: Sendable, Equatable {
    /// GPTK-compatible Wine loader (x86_64), e.g. `.../bin/wine64`.
    public var wineBinary: URL
    /// The matching `wineserver`. Used to wait for (`-w`) and kill (`-k`) every process in a prefix.
    public var wineserverBinary: URL
    /// Folder that holds `D3DMetal.framework` / `libd3dshared.dylib` (GPTK `redist/lib/external`).
    public var d3dMetalLibraryDirectory: URL
    /// The `launch_d3dmetal.sh` bootstrapper. Defaults to the copy bundled in AetherCore.
    public var launcherScript: URL
    public var mode: LaunchMode

    public init(
        wineBinary: URL,
        wineserverBinary: URL? = nil,
        d3dMetalLibraryDirectory: URL,
        launcherScript: URL = BottleRuntime.bundledLauncherScript,
        mode: LaunchMode = .gptkScript
    ) {
        self.mode = mode
        self.wineBinary = wineBinary
        // GPTK / CrossOver-style builds put wineserver next to the wine loader.
        self.wineserverBinary = wineserverBinary
            ?? wineBinary.deletingLastPathComponent().appending(path: "wineserver")
        self.d3dMetalLibraryDirectory = d3dMetalLibraryDirectory
        self.launcherScript = launcherScript
    }

    /// Direct launches through an installed runtime (base, `+d3dmetal` or `+dxmt`).
    public init(runtime: WineRuntime) {
        self.init(
            wineBinary: runtime.wineBinary,
            wineserverBinary: runtime.wineserver,
            d3dMetalLibraryDirectory: runtime.libDirectory.appending(path: "external", directoryHint: .isDirectory),
            mode: .direct
        )
    }

    /// Development hook until the Settings screen exists: reads `AETHER_WINE`, `AETHER_D3DMETAL`
    /// and optionally `AETHER_WINESERVER`. Returns `nil` if the required variables are missing.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BottleRuntime? {
        guard let wine = environment["AETHER_WINE"], !wine.isEmpty,
              let d3d = environment["AETHER_D3DMETAL"], !d3d.isEmpty
        else { return nil }
        return BottleRuntime(
            wineBinary: URL(filePath: wine),
            wineserverBinary: environment["AETHER_WINESERVER"].map { URL(filePath: $0) },
            d3dMetalLibraryDirectory: URL(filePath: d3d, directoryHint: .isDirectory)
        )
    }

    /// The `launch_d3dmetal.sh` that ships inside the AetherCore resource bundle.
    public static var bundledLauncherScript: URL {
        Bundle.module.url(forResource: "launch_d3dmetal", withExtension: "sh", subdirectory: "Scripts")
            ?? Bundle.module.bundleURL.appending(path: "Scripts/launch_d3dmetal.sh")
    }
}

/// One request to start a Windows executable inside a bottle.
public struct BottleLaunchRequest: Sendable, Equatable {
    public var executable: URL
    /// WINEPREFIX directory. Created if missing.
    public var bottle: URL
    public var translation: LocalTranslationConfig
    /// Apple's Metal Performance HUD. Overrides any `MTL_HUD_ENABLED` in the profile.
    public var metalHUDEnabled: Bool
    public var additionalArguments: [String]
    public var additionalEnvironment: [String: String]
    /// Direct mode only: preset env vars (`.custom` = none).
    public var preset: PerformancePreset
    /// Direct mode only: passed through as `DXMT_CONFIG`.
    public var dxmtConfig: String?

    public init(
        executable: URL,
        bottle: URL,
        translation: LocalTranslationConfig = LocalTranslationConfig(),
        metalHUDEnabled: Bool = true,
        additionalArguments: [String] = [],
        additionalEnvironment: [String: String] = [:],
        preset: PerformancePreset = .custom,
        dxmtConfig: String? = nil
    ) {
        self.preset = preset
        self.dxmtConfig = dxmtConfig
        self.executable = executable
        self.bottle = bottle
        self.translation = translation
        self.metalHUDEnabled = metalHUDEnabled
        self.additionalArguments = additionalArguments
        self.additionalEnvironment = additionalEnvironment
    }
}

/// How the primary Wine process ended.
public struct BottleExit: Sendable, Equatable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable {
        case exited
        case signaled
    }

    public let reason: Reason
    /// Exit code for `.exited`, signal number for `.signaled`.
    public let status: Int32

    public init(reason: Reason, status: Int32) {
        self.reason = reason
        self.status = status
    }

    init(process: Process) {
        reason = process.terminationReason == .uncaughtSignal ? .signaled : .exited
        status = process.terminationStatus
    }

    /// Maps `launch_d3dmetal.sh` exit codes to a likely cause. A game can return the same
    /// codes, so treat this as a hint and show it only for early exits.
    public var launcherFailureHint: String? {
        guard reason == .exited else { return nil }
        switch status {
        case 64: return "Launcher usage error (bad arguments)."
        case 66: return "Game executable not found."
        case 69: return "Rosetta 2 is not installed. Run: softwareupdate --install-rosetta --agree-to-license"
        case 126, 127: return "Wine binary missing or not executable."
        default: return nil
        }
    }

    public var description: String {
        switch reason {
        case .exited: "exited with code \(status)"
        case .signaled: "terminated by signal \(status)"
        }
    }
}

/// Events streamed from a running bottle session.
public enum BottleEvent: Sendable, Equatable {
    case launched(pid: Int32)
    case stdout(String)
    case stderr(String)
    /// The primary Wine process ended. The stream keeps going until the whole prefix is idle
    /// (launchers often exit while the real game keeps running), then finishes.
    case processExited(BottleExit)
}
