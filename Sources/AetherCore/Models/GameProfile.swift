import Foundation

/// Wine + D3DMetal launch settings for one game, as tested by the community.
public struct LocalTranslationConfig: Codable, Sendable, Equatable {
    public var backend: TranslationBackend
    /// Target Windows version for the bottle (e.g. `win10`). Applied by the Phase 3 auto-config step.
    public var windowsVersion: String
    /// Extra environment variables for the Wine process (e.g. `WINEMSYNC`, `D3DM_ENABLE_METALFX`).
    public var envVars: [String: String]
    /// Extra arguments passed to the game executable.
    public var launchArgs: [String]
    /// Path of the game .exe relative to its install folder (e.g. `bin/x64/Cyberpunk2077.exe`).
    /// When it is missing, `LibraryScanner` falls back to a heuristic.
    public var executable: String?

    public init(
        backend: TranslationBackend = .d3dmetal,
        windowsVersion: String = "win10",
        envVars: [String: String] = [:],
        launchArgs: [String] = [],
        executable: String? = nil
    ) {
        self.backend = backend
        self.windowsVersion = windowsVersion
        self.envVars = envVars
        self.launchArgs = launchArgs
        self.executable = executable
    }

    enum CodingKeys: String, CodingKey {
        case backend
        case windowsVersion = "windows_version"
        case envVars = "env_vars"
        case launchArgs = "launch_args"
        case executable
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decode(TranslationBackend.self, forKey: .backend)
        windowsVersion = try c.decodeIfPresent(String.self, forKey: .windowsVersion) ?? "win10"
        envVars = try c.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:]
        launchArgs = try c.decodeIfPresent([String].self, forKey: .launchArgs) ?? []
        executable = try c.decodeIfPresent(String.self, forKey: .executable)
    }
}

/// How to reach a game through a streaming backend.
public struct CloudFallbackConfig: Codable, Sendable, Equatable {
    public var geforceNowID: String?
    public var moonlightAppName: String?

    public init(geforceNowID: String? = nil, moonlightAppName: String? = nil) {
        self.geforceNowID = geforceNowID
        self.moonlightAppName = moonlightAppName
    }

    /// `true` when at least one streaming target is configured.
    public var isAvailable: Bool {
        !(geforceNowID ?? "").isEmpty || !(moonlightAppName ?? "").isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case geforceNowID = "geforce_now_id"
        case moonlightAppName = "moonlight_app_name"
    }
}

/// One entry from `game_profiles.json`.
public struct GameProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var steamAppID: String?
    public var hasKernelAnticheat: Bool
    public var anticheatName: String?
    /// The publisher ships an Apple Silicon build. Says nothing about whether it is *installed*:
    /// the router uses `GameInstallation` for that.
    public var nativeMacosAvailable: Bool
    /// Minimum `HardwareTier` (1–4) for 60 FPS via local translation. Above 4 (e.g. 99) means "never local".
    public var minLocalTier: Int
    public var preferredEngine: ExecutionEngine
    public var localTranslation: LocalTranslationConfig?
    public var cloudFallback: CloudFallbackConfig?

    public init(
        id: String,
        title: String,
        steamAppID: String? = nil,
        hasKernelAnticheat: Bool = false,
        anticheatName: String? = nil,
        nativeMacosAvailable: Bool = false,
        minLocalTier: Int = 2,
        preferredEngine: ExecutionEngine = .localTranslation,
        localTranslation: LocalTranslationConfig? = nil,
        cloudFallback: CloudFallbackConfig? = nil
    ) {
        self.id = id
        self.title = title
        self.steamAppID = steamAppID
        self.hasKernelAnticheat = hasKernelAnticheat
        self.anticheatName = anticheatName
        self.nativeMacosAvailable = nativeMacosAvailable
        self.minLocalTier = minLocalTier
        self.preferredEngine = preferredEngine
        self.localTranslation = localTranslation
        self.cloudFallback = cloudFallback
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case steamAppID = "steam_app_id"
        case hasKernelAnticheat = "has_kernel_anticheat"
        case anticheatName = "anticheat_name"
        case nativeMacosAvailable = "native_macos_available"
        case minLocalTier = "min_local_tier"
        case preferredEngine = "preferred_engine"
        case localTranslation = "local_translation"
        case cloudFallback = "cloud_fallback"
    }
}

/// Top-level shape of a profile manifest file.
public struct GameManifest: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var profiles: [GameProfile]

    public init(schemaVersion: String, profiles: [GameProfile]) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case profiles
    }
}
