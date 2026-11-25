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

/// Library filter pills (Home). Cycled with LB/RB or [ / ].
public enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, native, windows, cloud

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All Games"
        case .native: "Mac Native"
        case .windows: "Windows"
        case .cloud: "Cloud"
        }
    }
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

    /// Set by the Home page from its width.
    public var columns = 5

    public var filter: LibraryFilter = .all {
        didSet { if filter != oldValue { focusedIndex = 0 } }
    }

    /// User-chosen presets by game id (persisted in `AetherPreferences`).
    public private(set) var presetChoices: [GameItem.ID: PerformancePreset] = AetherPreferences.gamePresets
    /// Wine runtimes installed by the setup wizard (shared engine folder). Refreshed on every scan.
    public private(set) var wineBase: WineRuntime?
    public private(set) var installedFlavors: Set<RuntimeFlavor> = []
    public private(set) var hasDXVK = false

    public let hardware: MacHardwareProfile
    private let catalog: ProfileCatalog?
    private let scannerConfiguration: LibraryScanner.Configuration
    private let router = EngineRouter()
    private let artworkFetcher: ArtworkFetcher
    private let bottleRuntime: BottleRuntime?
    private let historyURL: URL
    private let runtimeStore = WineRuntimeStore()

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

    /// Games shown on Home under the current filter. Focus indexes into this list.
    public var visibleGames: [GameItem] {
        games.filter { matches($0, filter) }
    }

    public func count(for filter: LibraryFilter) -> Int {
        games.filter { matches($0, filter) }.count
    }

    private func matches(_ game: GameItem, _ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: true
        case .native: decisions[game.id]?.engine == .native
        case .windows: decisions[game.id]?.engine == .localTranslation
        case .cloud: decisions[game.id]?.engine == .cloudStream
        }
    }

    public func cycleFilter(by step: Int) {
        let all = LibraryFilter.allCases
        let index = all.firstIndex(of: filter) ?? 0
        filter = all[(index + step + all.count) % all.count]
    }

    public var focusedGame: GameItem? {
        let visible = visibleGames
        return visible.indices.contains(focusedIndex) ? visible[focusedIndex] : nil
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

    /// Set from the click until the game is actually running (spinners on cover and Play button).
    public private(set) var launchingGameID: GameItem.ID?

    /// "Back to Library" during a Wine session: show the launcher while the game keeps running.
    public private(set) var libraryShownDuringSession = false

    /// Whether the full-screen "game running" page should replace the launcher.
    public var showsRunningScreen: Bool { isGameRunning && !libraryShownDuringSession }

    public func showLibraryDuringSession() {
        libraryShownDuringSession = true
        statusMessage = "\(runningGameTitle ?? "Your game") is still running. ⌂ or ⇧⌘G → Force Quit to stop it."
    }

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

        var configuration = scannerConfiguration
        configuration.manualGames = ManualGameStore.load() // pick up games added since launch
        configuration.customDirectories += gameFolders
        let catalog = catalog
        let result = await Task.detached(priority: .userInitiated) {
            LibraryScanner(configuration: configuration, catalog: catalog).scan()
        }.value

        refreshRuntimes()
        games = result.games
        var routed: [GameItem.ID: RoutingDecision] = [:]
        for game in result.games {
            routed[game.id] = route(game)
        }
        decisions = routed
        focusedIndex = min(focusedIndex, max(visibleGames.count - 1, 0))
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

    // MARK: - Runtimes & presets

    public func refreshRuntimes() {
        wineBase = runtimeStore.newestBase()
        installedFlavors = wineBase.map { runtimeStore.installedFlavors(baseID: $0.id) } ?? []
        hasDXVK = runtimeStore.installedDXVK() != nil
    }

    /// The user's choice, else the best preset for what is installed.
    public func preset(for game: GameItem) -> PerformancePreset {
        if let chosen = presetChoices[game.id] { return chosen }
        let profileBackend = profile(for: game).localTranslation?.backend ?? .d3dmetal
        return .recommended(profileBackend: profileBackend, installed: installedFlavors)
    }

    public func setPreset(_ preset: PerformancePreset, for game: GameItem) {
        presetChoices[game.id] = preset
        AetherPreferences.gamePresets = presetChoices
    }

    /// Whether a preset can run right now (its graphics stack is installed).
    public func isAvailable(_ preset: PerformancePreset, for game: GameItem) -> Bool {
        let backend = preset.effectiveBackend(profile(for: game).localTranslation?.backend ?? .d3dmetal)
        switch backend {
        case .dxvk: return wineBase != nil && hasDXVK
        default: return installedFlavors.contains(RuntimeFlavor.forBackend(backend))
        }
    }

    // MARK: - Focus & status

    public func moveFocus(_ direction: FocusDirection) {
        focusedIndex = GridNavigator.move(from: focusedIndex, direction, count: visibleGames.count, columns: columns)
    }

    /// Focuses an index in `visibleGames`.
    public func focus(_ index: Int) {
        guard visibleGames.indices.contains(index) else { return }
        focusedIndex = index
    }

    /// Focuses a game by id, switching to "All Games" if the current filter hides it.
    public func focus(gameID: GameItem.ID) {
        if let index = visibleGames.firstIndex(where: { $0.id == gameID }) {
            focusedIndex = index
        } else if games.contains(where: { $0.id == gameID }) {
            filter = .all
            if let index = visibleGames.firstIndex(where: { $0.id == gameID }) { focusedIndex = index }
        }
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
        guard launchingGameID == nil else { return .failed } // a click while something is starting
        launchingGameID = game.id
        defer { if launchingGameID == game.id { launchingGameID = nil } }
        guard let decision = route(game, preference: preference) else {
            statusMessage = "No engine can run \(game.title) on this Mac."
            return .failed
        }
        switch decision.engine {
        case .native:
            return await launchNative(game) ? .started : .failed
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
            statusMessage = "‹ Library (top-left) or ⇧⌘W returns to Home. ⌂ or ⇧⌘G opens Quick Access."
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

    private func launchNative(_ game: GameItem) async -> Bool {
        let steamURL = game.steamAppID.flatMap { URL(string: "steam://rungameid/\($0)") }
        let steamAvailable = steamURL.map { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil } ?? false
        if let steamURL, steamAvailable {
            // Through Steam when it's installed: DRM, cloud saves and the overlay keep working.
            guard NSWorkspace.shared.open(steamURL) else {
                statusMessage = "Steam couldn't start \(game.title)."
                return false
            }
        } else if let app = game.installation.nativeApplication {
            // No Steam app (or not a Steam game): open the game's own .app directly.
            if let failure = await openApplication(at: app) {
                statusMessage = "Could not launch \(game.title): \(failure)"
                return false
            }
        } else {
            statusMessage = "\(game.title) has no Mac app to open."
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

    /// Opens an app and returns macOS's own error message on failure (damaged or unsigned app,
    /// iPhone-only app, wrong architecture…), instead of a bare true/false.
    private func openApplication(at url: URL) async -> String? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { @Sendable _, error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
    }

    private func launchLocal(_ game: GameItem) async -> Bool {
        guard let executable = game.installation.windowsExecutable else {
            statusMessage = "No Windows executable found for \(game.title)."
            return false
        }
        let prefix = AetherPaths.bottle(for: game.bottleName)
        var translation = profile(for: game).localTranslation ?? LocalTranslationConfig()
        let chosenPreset = preset(for: game)
        var activePreset = chosenPreset
        let runtime: BottleRuntime

        if let configured = bottleRuntime {
            // Developer override (AETHER_WINE / AETHER_D3DMETAL): Phase 1 GPTK script path.
            runtime = configured
        } else {
            // Setup-wizard runtimes: pick the flavor the preset's backend needs.
            refreshRuntimes()
            do {
                // "Just play": anything missing is installed now, once, with progress in the toast.
                try await ensureRosetta()
                let base = try await ensureWine()
                let wanted = chosenPreset.effectiveBackend(translation.backend)
                let backend = await ensureBackend(wanted, base: base)
                if backend != wanted {
                    activePreset = backend == .dxmt ? .dx11DXMT : .compatibility
                }
                translation.backend = backend
                let wine = try runtimeStore.resolve(baseID: base.id, backend: backend)
                if !WinePrefix.isInitialized(prefix) {
                    statusMessage = "Creating a Windows bottle for \(game.title)… (first launch only)"
                    try await WinePrefix.initialize(prefix, runtime: wine)
                }
                if backend == .dxvk {
                    guard let dxvk = runtimeStore.installedDXVK() else { throw WineRuntimeError.dxvkNotInstalled }
                    try WinePrefix.syncDXVK(from: dxvk, into: prefix)
                }
                runtime = BottleRuntime(runtime: wine)
            } catch {
                statusMessage = String(describing: error)
                return false
            }
        }
        // A fresh engine per launch: each game can need a different runtime flavor.
        let engine = BottleEngine(runtime: runtime)
        bottleEngine = engine

        do {
            let events = try await engine.launch(BottleLaunchRequest(
                executable: executable,
                bottle: prefix,
                translation: translation,
                metalHUDEnabled: AetherPreferences.metalHUDEnabled || activePreset.metalHUDDefault,
                preset: activePreset
            ))
            recordLaunch(game)
            runningGameTitle = game.title
            launchingGameID = nil
            libraryShownDuringSession = false
            if activePreset == chosenPreset { statusMessage = nil }
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

    // MARK: - Adding games

    /// Extra folders scanned for games (external SSDs etc.), in addition to ~/Documents/Aether Games.
    public private(set) var gameFolders: [URL] = AetherPreferences.gameFolders

    /// Adds whatever the user picked: a single .exe, one game's folder, or a folder (or drive) of games.
    public func addGames(at url: URL) async {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if !isDirectory {
            guard url.pathExtension.lowercased() == "exe" else {
                statusMessage = "Pick a Windows .exe, a game folder, or a folder of games."
                return
            }
            await addManualGame(title: Self.title(forExecutable: url), executable: url, bottleID: nil)
            return
        }
        if LibraryScanner.looksLikeSingleGame(url) {
            guard let exe = LibraryScanner.findWindowsExecutable(in: url, hint: nil) else {
                statusMessage = "No Windows .exe found in \(url.lastPathComponent)."
                return
            }
            await addManualGame(title: url.lastPathComponent, executable: exe, bottleID: nil)
            return
        }
        guard !gameFolders.contains(url) else {
            statusMessage = "\(url.lastPathComponent) is already in your library folders."
            return
        }
        gameFolders.append(url)
        AetherPreferences.gameFolders = gameFolders
        let before = games.count
        await refresh()
        statusMessage = "Added \(url.lastPathComponent): \(max(games.count - before, 0)) game(s) found. Click a cover to play."
    }

    public func removeGameFolder(_ url: URL) async {
        gameFolders.removeAll { $0 == url }
        AetherPreferences.gameFolders = gameFolders
        await refresh()
    }

    /// "…/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe" → "Cyberpunk 2077".
    static func title(forExecutable exe: URL) -> String {
        var folder = exe.deletingLastPathComponent()
        let generic: Set<String> = ["bin", "binaries", "win64", "x64", "x86", "win32", "game", "retail"]
        while generic.contains(folder.lastPathComponent.lowercased()), folder.pathComponents.count > 2 {
            folder = folder.deletingLastPathComponent()
        }
        let name = folder.lastPathComponent
        return name.isEmpty || name == "/" ? exe.deletingPathExtension().lastPathComponent : name
    }

    // MARK: - Automatic setup on Play

    private func ensureRosetta() async throws {
        guard !RuntimeInstaller.isRosettaInstalled else { return }
        statusMessage = "Installing Rosetta 2 (one-time): macOS will ask for your password…"
        try await RuntimeInstaller.installRosetta()
    }

    private func ensureWine() async throws -> WineRuntime {
        if let base = wineBase { return base }
        try await installWithStatus("Downloading Wine") { progress in
            _ = try await RuntimeInstaller().installWine(progress: progress)
        }
        guard let base = wineBase else { throw WineRuntimeError.noRuntime }
        return base
    }

    /// Returns the backend to actually use: installs DXMT / DXVK when missing; D3DMetal can't be
    /// downloaded (Apple license), so it falls back to DXMT, and if that fails too, to WineD3D.
    private func ensureBackend(_ backend: TranslationBackend, base: WineRuntime) async -> TranslationBackend {
        switch backend {
        case .wined3d:
            return .wined3d
        case .dxvk:
            if hasDXVK { return .dxvk }
            let installed = (try? await installWithStatus("Downloading DXVK") { progress in
                _ = try await RuntimeInstaller().installDXVK(progress: progress)
            }) != nil
            return installed && hasDXVK ? .dxvk : .wined3d
        case .dxmt, .d3dmetal:
            if backend == .d3dmetal, installedFlavors.contains(.d3dmetal) { return .d3dmetal }
            if !installedFlavors.contains(.dxmt) {
                _ = try? await installWithStatus("Downloading DXMT") { progress in
                    _ = try await RuntimeInstaller().installDXMT(base: base, progress: progress)
                }
            }
            let resolved: TranslationBackend = installedFlavors.contains(.dxmt) ? .dxmt : .wined3d
            if backend == .d3dmetal {
                statusMessage = "D3DMetal isn't installed (it needs your free Apple GPTK download, see Engine Setup). Using \(resolved.label) instead."
            }
            return resolved
        }
    }

    private func installWithStatus(
        _ label: String,
        _ work: (RuntimeInstaller.Progress) async throws -> Void
    ) async throws {
        statusMessage = "\(label) (one-time)…"
        let progress: RuntimeInstaller.Progress = { [weak self] update in
            Task { @MainActor in
                guard let self else { return }
                switch update {
                case .downloading(let received, let total):
                    let percent = total.map { " \(Int(Double(received) / Double(max($0, 1)) * 100))%" } ?? ""
                    self.statusMessage = "\(label) (one-time)…\(percent)"
                case .extracting, .installing:
                    self.statusMessage = "\(label): installing…"
                default:
                    break
                }
            }
        }
        defer { refreshRuntimes() }
        try await work(progress)
    }

    // MARK: - Bottles

    /// Runs any Windows program (usually an installer) inside a bottle with plain WineD3D:
    /// the most compatible setup, and installers don't need fast graphics.
    public func runExecutable(_ executable: URL, inBottle bottle: BottleInfo) async {
        guard !isGameRunning else {
            statusMessage = "\(runningGameTitle ?? "A game") is still running."
            return
        }
        refreshRuntimes()
        guard let base = wineBase else {
            statusMessage = String(describing: WineRuntimeError.noRuntime)
            return
        }
        do {
            if !WinePrefix.isInitialized(bottle.url) {
                statusMessage = "Preparing bottle \(bottle.id)… (first run only)"
                try await WinePrefix.initialize(bottle.url, runtime: base)
            }
            let engine = BottleEngine(runtime: BottleRuntime(runtime: base))
            bottleEngine = engine
            let events = try await engine.launch(BottleLaunchRequest(
                executable: executable,
                bottle: bottle.url,
                translation: LocalTranslationConfig(backend: .wined3d),
                metalHUDEnabled: false,
                preset: .compatibility
            ))
            runningGameTitle = executable.deletingPathExtension().lastPathComponent
            libraryShownDuringSession = false
            statusMessage = nil
            for await _ in events {}
            runningGameTitle = nil
            statusMessage = "Finished. If it installed a game, use Bottles → Add Game to put it in your library."
        } catch {
            runningGameTitle = nil
            statusMessage = String(describing: error)
        }
    }

    /// Adds a game installed inside a bottle to the library; it will always run in that bottle.
    public func addManualGame(title: String, executable: URL, bottle: BottleInfo) async {
        await addManualGame(title: title, executable: executable, bottleID: bottle.id)
    }

    /// `bottleID == nil`: the game gets its own bottle, created automatically on first play.
    public func addManualGame(title: String, executable: URL, bottleID: String?) async {
        do {
            let bottle = bottleID ?? RuntimeInstaller.slugify(title)
            try ManualGameStore.add(ManualGame(title: title, executable: executable, bottle: bottle))
            statusMessage = "Added \(title) to your library."
            await refresh()
        } catch {
            statusMessage = "Couldn't save \(title): \(error.localizedDescription)"
        }
    }

    /// Kills every Wine process in a bottle (hung game, stuck wineserver).
    public func stopBottle(_ bottle: BottleInfo) async {
        refreshRuntimes()
        guard let base = wineBase else { return }
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = bottle.url.path(percentEncoded: false)
        _ = await WinePrefix.run(base.wineserver, ["-k"], environment: environment)
        statusMessage = "Stopped everything running in \(bottle.id)."
    }

    private func recordLaunch(_ game: GameItem) {
        history.recordLaunch(game.id)
        saveHistory()
    }

    private func saveHistory() {
        try? history.save(to: historyURL)
    }
}
