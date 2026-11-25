import Foundation

/// What is actually on disk for a game. Comes from the Phase 2 `LibraryScanner`.
///
/// The spec routes Native when an Apple Silicon binary is *installed*. The profile flag
/// `native_macos_available` only says one *exists*, so the router needs this separate input.
public struct GameInstallation: Sendable, Hashable {
    /// `.app` bundle of a native macOS build, if installed.
    public var nativeApplication: URL?
    /// Windows `.exe` to run through Wine, if installed.
    public var windowsExecutable: URL?

    public init(nativeApplication: URL? = nil, windowsExecutable: URL? = nil) {
        self.nativeApplication = nativeApplication
        self.windowsExecutable = windowsExecutable
    }

    public static let notInstalled = GameInstallation()
}

/// The user's choice in the "below threshold" prompt: cloud (default) or local low-spec override.
public enum RoutingPreference: Sendable, Equatable {
    case automatic
    case preferLocal
}

/// Why the router picked an engine, or why it could not. Typed so tests and UI never parse strings.
public enum RoutingReason: Sendable, Equatable, CustomStringConvertible {
    case nativeBinaryInstalled
    case kernelAntiCheat(name: String?)
    case hardwareNotAppleSilicon
    case noLocalTranslationProfile
    case localTranslationUnsupportedByProfile
    case windowsBuildNotInstalled
    case curatedCloudPreference
    case meetsTier(actual: HardwareTier, required: Int)
    case belowTier(actual: HardwareTier, required: Int)
    case belowTierNoCloudFallback(actual: HardwareTier, required: Int)
    case userLocalOverride(actual: HardwareTier, required: Int)

    public var description: String {
        switch self {
        case .nativeBinaryInstalled:
            "Apple Silicon build installed. Launching natively (Game Mode)."
        case .kernelAntiCheat(let name):
            "Kernel anti-cheat (\(name ?? "unknown")) cannot run under Wine. Streaming required."
        case .hardwareNotAppleSilicon:
            "D3DMetal needs Apple Silicon. This Mac cannot translate locally."
        case .noLocalTranslationProfile:
            "No tested Wine/D3DMetal profile for this game."
        case .localTranslationUnsupportedByProfile:
            "Profile marks this game as not runnable locally."
        case .windowsBuildNotInstalled:
            "Windows build not installed locally."
        case .curatedCloudPreference:
            "Profile maintainers recommend streaming for this title."
        case .meetsTier(let actual, let required):
            "\(actual) meets required Tier \(required). Running locally via D3DMetal."
        case .belowTier(let actual, let required):
            "\(actual) is below required Tier \(required). Streaming by default."
        case .belowTierNoCloudFallback(let actual, let required):
            "\(actual) is below required Tier \(required) and no stream is configured. Running locally at low spec."
        case .userLocalOverride(let actual, let required):
            "User override: running locally on \(actual) (recommended Tier \(required))."
        }
    }
}

public struct RoutingDecision: Sendable, Equatable {
    public let engine: ExecutionEngine
    public let reason: RoutingReason
    /// Whether the UI should offer a "Play locally anyway (low spec)" button.
    public let allowLocalOverride: Bool

    public init(engine: ExecutionEngine, reason: RoutingReason, allowLocalOverride: Bool) {
        self.engine = engine
        self.reason = reason
        self.allowLocalOverride = allowLocalOverride
    }
}

public enum RoutingError: Error, Equatable, CustomStringConvertible {
    /// No engine can run this game on this Mac with the current install and profile.
    case noViableEngine(gameID: String, blockedBy: RoutingReason)

    public var description: String {
        switch self {
        case .noViableEngine(let id, let reason):
            "No viable engine for '\(id)': \(reason) No cloud fallback configured."
        }
    }
}
