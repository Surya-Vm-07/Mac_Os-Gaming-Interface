import AetherCore
import AppKit
import Observation

/// What happened when the user pressed Play.
public enum LaunchOutcome: Sendable, Equatable {
    case started
    /// The router picked the cloud engine. The coordinator opens this service's stream view.
    case needsCloud(CloudService)
    case failed
}

/// Library data, routing, play history and launching. Navigation state lives in `ShellCoordinator`.
@MainActor
@Observable
public final class LibraryViewModel {

    public private(set) var games: [GameItem] = []
    public private(set) var decisions: [GameItem.ID: RoutingDecision] = [:]
    /// Cached artwork *file URLs*, never pixels.
    public private(set) var artwork: [GameItem.ID: [ArtworkKind: URL]] = [:]
    public private(set) var focusedIndex = 0
    public private(set) var isScanning = false
    public private(set) var statusMessage: String?
    public private(set) var history: PlayHistory

    /// Wine session Aether is supervising. The UI suspends while it runs.
    public private(set) var runningGameTitle: String?
    /// Last native game Aether launched, kept so the drawer can force-quit it.
    public private(set) var nativeSession: (title: String, app: URL)?
    /// Cloud service currently streaming inside Aether's window.
    public private(set) var activeStream: CloudService?

    /// Set by the grid from the window width.
    public var columns = 5

    public let hardware: MacHardwareProfile
    private let catalog: ProfileCatalog?
    private let scannerConfiguration: LibraryScanner.Configuration
    private let router = EngineRouter()
    private let artworkFetcher: ArtworkFetcher
    private let bottleRuntime: BottleRuntime?
    private let historyURL: URL

    @ObservationIgnored private var bottleEngine: BottleEngine?
    @ObservationIgnored private var requestedArtwork: Set<String> = []

    public init(
        hardware: MacHardwareProfile,
        catalog: ProfileCatalog?,
        scannerConfiguration: LibraryScanner.Configuration,
        artworkFetcher: ArtworkFetcher,
        bottleRuntime: BottleRuntime?,
        historyURL: URL = AetherPaths.playHistory
    ) {
        self.hardware = hardware
        self.catalog = catalog
        self.scannerConfiguration = scannerConfiguration
        self.artworkFetcher = artworkFetcher
        self.bottleRuntime = bottleRuntime
        self.historyURL = historyURL
        self.history = PlayHistory.load(from: historyURL)
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

    // MARK: - Lookups

    public var focusedGame: GameItem? {
        games.indices.contains(focusedIndex) ? games[focusedIndex] : nil
    }

    public func game(withID id: GameItem.ID) -> GameItem? {
        games.first { $0.id == id }
    }

    public func decision(for game: GameItem) -> RoutingDecision? {
        decisions[game.id]
    }

    public func profile(for game: GameItem) -> GameProfile {
        game.profileID.flatMap { catalog?.profile(id: $0) } ?? .generic(for: game)
    }

    public var recentGames: [GameItem] {
        history.recentGameIDs(limit: 8).compactMap { game(withID: $0) }
    }

    public var isGameRunning: Bool { runningGameTitle != nil }

    /// Title shown in the Quick Drawer's session header.
    public var activeSessionTitle: String? {
        runningGameTitle ?? nativeSession?.title ?? activeStream?.displayName
    }

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
        if games.isEmpty {
            statusMessage = "No games found. Install a game or open Cloud Gaming in the sidebar."
        }
    }

    /// Requests artwork once per game and kind.
    public func loadArtwork(for game: GameItem, kinds: [ArtworkKind]) async {
        for kind in kinds {
            guard requestedArtwork.insert("\(game.id)|\(kind.rawValue)").inserted else { continue }
            if let url = await artworkFetcher.artwork(kind, for: game) {
                artwork[game.id, default: [:]][kind] = url
            }
        }
    }

    // MARK: - Focus & status

    public func moveFocus(_ direction: FocusDirection) {
        focusedIndex = GridNavigator.move(from: focusedIndex, direction, count: games.count, columns: columns)
    }

    public func focus(_ index: Int) {
        guard games.indices.contains(index) else { return }
        focusedIndex = index
    }

    public func showStatus(_ message: String) {
        statusMessage = message
    }

    public func dismissStatus() {
        statusMessage = nil
    }

    // MARK: - Launch

    /// Routes and starts `game`. Local (Wine) launches suspend until the whole prefix exits.
    public func play(_ game: GameItem, preference: RoutingPreference = .automatic) async -> LaunchOutcome {
        guard !isGameRunning else {
            statusMessage = "\(runningGameTitle ?? "A game") is still running."
            return .failed
        }
        guard let decision = route(game, preference: preference) else {
            statusMessage = "No engine can run \(game.title) on this Mac."
            return .failed
        }
        switch decision.engine {
        case .native:
            return launchNative(game) ? .started : .failed
        case .localTranslation:
            return await launchLocal(game) ? .started : .failed
        case .cloudStream:
            return .needsCloud(cloudService(for: game))
        }
    }

    /// GeForce NOW if the profile lists a GFN id; otherwise the user's default service.
    public func cloudService(for game: GameItem) -> CloudService {
        if profile(for: game).cloudFallback?.geforceNowID != nil { return .geforceNow }
        return AetherPreferences.defaultCloudService
    }

    /// Opens a cloud service inside Aether. The library is unmounted and artwork dropped:
    /// the only heavy thing left is the video decoder.
    public func startStream(_ service: CloudService, for game: GameItem? = nil) {
        if let game {
            recordLaunch(game)
            statusMessage = "\(service.displayName): search for “\(game.title)”. Press ⌂ or ⇧⌘G for Quick Access."
        } else {
            statusMessage = "Press ⌂ or ⇧⌘G for Quick Access and End Stream."
        }
        ImagePipeline.shared.purge()
        activeStream = service
    }

    public func endStream() {
        activeStream = nil
        statusMessage = nil
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

    // MARK: - Internals

    private func route(_ game: GameItem, preference: RoutingPreference = .automatic) -> RoutingDecision? {
        try? router.route(profile: profile(for: game), installation: game.installation, hardware: hardware, preference: preference)
    }

    private func launchNative(_ game: GameItem) -> Bool {
        // Steam games go through Steam so DRM, cloud saves and the overlay work.
        let target: URL? = game.steamAppID.flatMap { URL(string: "steam://rungameid/\($0)") }
            ?? game.installation.nativeApplication
        guard let target, NSWorkspace.shared.open(target) else {
            statusMessage = "Could not launch \(game.title)."
            return false
        }
        recordLaunch(game)
        // We cannot see when a native game exits, so do not lock the UI. Just free the textures.
        ImagePipeline.shared.purge()
        if let app = game.installation.nativeApplication {
            nativeSession = (game.title, app)
        }
        statusMessage = "Launching \(game.title)…"
        return true
    }

    private func launchLocal(_ game: GameItem) async -> Bool {
        guard let runtime = bottleRuntime else {
            statusMessage = "Set AETHER_WINE and AETHER_D3DMETAL to run Windows games locally."
            return false
        }
        guard let executable = game.installation.windowsExecutable else {
            statusMessage = "No Windows executable found for \(game.title)."
            return false
        }
        let engine = bottleEngine ?? BottleEngine(runtime: runtime)
        bottleEngine = engine

        do {
            let events = try await engine.launch(BottleLaunchRequest(
                executable: executable,
                bottle: AetherPaths.bottle(for: game.bottleName),
                translation: profile(for: game).localTranslation ?? LocalTranslationConfig(),
                metalHUDEnabled: AetherPreferences.metalHUDEnabled
            ))
            recordLaunch(game)
            runningGameTitle = game.title
            statusMessage = nil
            ImagePipeline.shared.purge()
            let started = ContinuousClock.now

            var lastExit: BottleExit?
            for await event in events {
                if case .processExited(let exit) = event { lastExit = exit }
            }

            let elapsed = started.duration(to: .now)
            history.recordSession(game.id, duration: Double(elapsed.components.seconds))
            saveHistory()
            runningGameTitle = nil
            if let hint = lastExit?.launcherFailureHint { statusMessage = hint }
            return true
        } catch {
            runningGameTitle = nil
            statusMessage = String(describing: error)
            return false
        }
    }

    private func recordLaunch(_ game: GameItem) {
        history.recordLaunch(game.id)
        saveHistory()
    }

    private func saveHistory() {
        try? history.save(to: historyURL)
    }
}
