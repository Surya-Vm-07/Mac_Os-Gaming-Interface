import AetherCore
import AppKit
import Observation

/// Library state for the console shell. Focus lives here, not in SwiftUI `@FocusState`, so the
/// keyboard (Phase 2) and the gamepad (Phase 3) drive the same `moveFocus` / `playFocused` API.
@MainActor
@Observable
public final class LibraryViewModel {

    public private(set) var games: [GameItem] = []
    public private(set) var decisions: [GameItem.ID: RoutingDecision] = [:]
    /// Cached artwork *file URLs*, never pixels.
    public private(set) var artwork: [GameItem.ID: [ArtworkKind: URL]] = [:]
    public private(set) var focusedIndex = 0
    public private(set) var isScanning = false
    /// Title of a Wine session Aether is supervising (the UI suspends while it runs).
    public private(set) var runningGameTitle: String?
    /// Last native game Aether launched. Kept so the drawer can force-quit it.
    public private(set) var nativeSession: (title: String, app: URL)?
    public private(set) var statusMessage: String?
    /// Set by the grid from the window width.
    public var columns = 5

    private let hardware: MacHardwareProfile
    private let catalog: ProfileCatalog?
    private let scannerConfiguration: LibraryScanner.Configuration
    private let router = EngineRouter()
    private let artworkFetcher: ArtworkFetcher
    private let bottleRuntime: BottleRuntime?

    @ObservationIgnored private var bottleEngine: BottleEngine?
    @ObservationIgnored private var requestedArtwork: Set<String> = []

    public init(
        hardware: MacHardwareProfile,
        catalog: ProfileCatalog?,
        scannerConfiguration: LibraryScanner.Configuration,
        artworkFetcher: ArtworkFetcher,
        bottleRuntime: BottleRuntime?
    ) {
        self.hardware = hardware
        self.catalog = catalog
        self.scannerConfiguration = scannerConfiguration
        self.artworkFetcher = artworkFetcher
        self.bottleRuntime = bottleRuntime
    }

    /// Production wiring: real hardware, bundled + user profiles, Keychain API key, env runtime.
    public static func makeDefault() -> LibraryViewModel {
        LibraryViewModel(
            hardware: MacHardwareProfiler.current,
            catalog: try? GameManifestLoader().load(),
            scannerConfiguration: .standard,
            artworkFetcher: ArtworkFetcher(apiKey: SecretStore.steamGridDBAPIKey()),
            bottleRuntime: .fromEnvironment()
        )
    }

    // MARK: - Derived state

    public var focusedGame: GameItem? {
        games.indices.contains(focusedIndex) ? games[focusedIndex] : nil
    }

    public var focusedDecision: RoutingDecision? {
        focusedGame.flatMap { decisions[$0.id] }
    }

    public var isGameRunning: Bool { runningGameTitle != nil }

    /// Title shown in the Quick Drawer's session header.
    public var activeSessionTitle: String? { runningGameTitle ?? nativeSession?.title }

    public var canForceQuit: Bool { runningGameTitle != nil || nativeSession != nil }

    public var hardwareSummary: String {
        "\(hardware.chip?.description ?? hardware.chipName) · \(hardware.totalMemoryGB) GB · TIER \(hardware.tier.rawValue)"
    }

    // MARK: - Library

    public func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let configuration = scannerConfiguration
        let catalog = catalog
        let result = await Task.detached(priority: .userInitiated) {
            LibraryScanner(configuration: configuration, catalog: catalog).scan()
        }.value

        games = result.games
        var routed: [GameItem.ID: RoutingDecision] = [:]
        for game in result.games {
            routed[game.id] = route(game)
        }
        decisions = routed
        focusedIndex = min(focusedIndex, max(games.count - 1, 0))
        statusMessage = games.isEmpty
            ? "No games found. Install a Steam game or a Games-category app, then refresh."
            : nil
    }

    /// Requests artwork once per game and kind. Cards call it on appear; the hero calls it on focus.
    public func loadArtwork(for game: GameItem, kinds: [ArtworkKind]) async {
        for kind in kinds {
            guard requestedArtwork.insert("\(game.id)|\(kind.rawValue)").inserted else { continue }
            if let url = await artworkFetcher.artwork(kind, for: game) {
                artwork[game.id, default: [:]][kind] = url
            }
        }
    }

    // MARK: - Focus

    public func moveFocus(_ direction: FocusDirection) {
        focusedIndex = GridNavigator.move(from: focusedIndex, direction, count: games.count, columns: columns)
    }

    public func focus(_ index: Int) {
        guard games.indices.contains(index) else { return }
        focusedIndex = index
    }

    public func dismissStatus() {
        statusMessage = nil
    }

    // MARK: - Launch

    /// Routes the focused game and starts it. For local translation this suspends until the
    /// whole Wine prefix exits.
    public func playFocused(preference: RoutingPreference = .automatic) async {
        guard let game = focusedGame, !isGameRunning else { return }
        guard let decision = route(game, preference: preference) else {
            statusMessage = "No engine can run \(game.title) on this Mac."
            return
        }
        switch decision.engine {
        case .native:
            launchNative(game)
        case .localTranslation:
            await launchLocal(game)
        case .cloudStream:
            statusMessage = "\(decision.reason) Cloud streaming arrives in Phase 4."
        }
    }

    /// Quick Drawer → Force Quit. Wine sessions: SIGTERM → `wineserver -k` → SIGKILL.
    /// Native games: polite terminate, then force-terminate after 3 s.
    public func forceQuitActiveGame() async {
        if runningGameTitle != nil {
            await bottleEngine?.terminate()
            return
        }
        guard let session = nativeSession else { return }
        let target = session.app.standardizedFileURL
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == target }
        running.forEach { $0.terminate() }
        try? await Task.sleep(for: .seconds(3))
        for app in running where !app.isTerminated {
            app.forceTerminate()
        }
        nativeSession = nil
        statusMessage = "\(session.title) closed."
    }

    private func route(_ game: GameItem, preference: RoutingPreference = .automatic) -> RoutingDecision? {
        let profile = game.profileID.flatMap { catalog?.profile(id: $0) } ?? .generic(for: game)
        return try? router.route(profile: profile, installation: game.installation, hardware: hardware, preference: preference)
    }

    private func launchNative(_ game: GameItem) {
        // Steam games go through Steam so DRM, cloud saves and the overlay work.
        let target: URL?
        if let appID = game.steamAppID {
            target = URL(string: "steam://rungameid/\(appID)")
        } else {
            target = game.installation.nativeApplication
        }
        guard let target, NSWorkspace.shared.open(target) else {
            statusMessage = "Could not launch \(game.title)."
            return
        }
        // We cannot see when a native game exits, so do not lock the UI. Just free the textures.
        ImagePipeline.shared.purge()
        if let app = game.installation.nativeApplication {
            nativeSession = (game.title, app)
        }
        statusMessage = "Launching \(game.title)…"
    }

    private func launchLocal(_ game: GameItem) async {
        guard let runtime = bottleRuntime else {
            statusMessage = "Set AETHER_WINE and AETHER_D3DMETAL to run Windows games (Settings arrives in Phase 3)."
            return
        }
        guard let executable = game.installation.windowsExecutable else {
            statusMessage = "No Windows executable found for \(game.title)."
            return
        }
        let translation = game.profileID.flatMap { catalog?.profile(id: $0)?.localTranslation } ?? LocalTranslationConfig()
        let engine = bottleEngine ?? BottleEngine(runtime: runtime)
        bottleEngine = engine

        do {
            let events = try await engine.launch(BottleLaunchRequest(
                executable: executable,
                bottle: AetherPaths.bottle(for: game.bottleName),
                translation: translation,
                metalHUDEnabled: AetherPreferences.metalHUDEnabled
            ))
            runningGameTitle = game.title
            statusMessage = nil
            ImagePipeline.shared.purge() // The UI drops all artwork while the game runs.

            var lastExit: BottleExit?
            for await event in events {
                if case .processExited(let exit) = event { lastExit = exit }
            }
            runningGameTitle = nil
            if let hint = lastExit?.launcherFailureHint { statusMessage = hint }
        } catch {
            runningGameTitle = nil
            statusMessage = String(describing: error)
        }
    }
}
