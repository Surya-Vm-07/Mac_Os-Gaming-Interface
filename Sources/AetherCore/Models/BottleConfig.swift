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

    public static func bottle(for gameID: String) -> URL {
        bottles.appending(path: gameID, directoryHint: .isDirectory)
    }
}

/// Where the Wine + GPTK toolchain lives on this Mac. Set once in Settings.
public struct BottleRuntime: Sendable, Equatable {
    /// GPTK-compatible Wine loader (x86_64), e.g. `.../bin/wine64`.
    public var wineBinary: URL
    /// The matching `wineserver`. Used to wait for (`-w`) and kill (`-k`) every process in a prefix.
    public var wineserverBinary: URL
    /// Folder that holds `D3DMetal.framework` / `libd3dshared.dylib` (GPTK `redist/lib/external`).
    public var d3dMetalLibraryDirectory: URL
    /// The `launch_d3dmetal.sh` bootstrapper. Defaults to the copy bundled in AetherCore.
    public var launcherScript: URL

    public init(
        wineBinary: URL,
        wineserverBinary: URL? = nil,
        d3dMetalLibraryDirectory: URL,
        launcherScript: URL = BottleRuntime.bundledLauncherScript
    ) {
        self.wineBinary = wineBinary
        // GPTK / CrossOver-style builds put wineserver next to the wine loader.
        self.wineserverBinary = wineserverBinary
            ?? wineBinary.deletingLastPathComponent().appending(path: "wineserver")
        self.d3dMetalLibraryDirectory = d3dMetalLibraryDirectory
        self.launcherScript = launcherScript
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

    public init(
        executable: URL,
        bottle: URL,
        translation: LocalTranslationConfig = LocalTranslationConfig(),
        metalHUDEnabled: Bool = true,
        additionalArguments: [String] = [],
        additionalEnvironment: [String: String] = [:]
    ) {
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
