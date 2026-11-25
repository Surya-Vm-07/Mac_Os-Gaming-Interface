import AetherCore
import AppKit
import Observation

/// Main-area page.
public enum ShellRoute: Hashable, Sendable {
    case home
    case game(GameItem.ID)
    case cloudHub
}

/// Which half of the window the controller is driving.
public enum FocusZone: Hashable, Sendable {
    case sidebar
    case content
}

public enum SidebarEntry: Hashable, Sendable {
    case home
    case cloudHub
    case game(GameItem.ID)
}

public enum DetailAction: Hashable, Sendable {
    case play
    case playLocally
    case back
}

/// Navigation plus the single input router. Keyboard keys and controller buttons both become
/// `GamepadCommand`s and go through `handle(_:)`.
///
/// Layout: sidebar (Home, Cloud Gaming, searchable game list) | content (Home grid, Game page,
/// Cloud hub). ← from the content's left edge enters the sidebar; → or Ⓐ in the sidebar goes back.
@MainActor
@Observable
public final class ShellCoordinator {
    public let library: LibraryViewModel
    public let drawer: QuickDrawerModel
    public let gamepad: GamepadManager

    public private(set) var route: ShellRoute = .home
    public private(set) var zone: FocusZone = .content
    public private(set) var sidebarIndex = 0
    public private(set) var detailIndex = 0
    public private(set) var cloudIndex = 0
    /// Bumped to ask the sidebar search field to take keyboard focus.
    public private(set) var searchFocusToken = 0
    /// Bumped to hand keyboard focus back to the root view (after search or mouse clicks).
    public private(set) var rootFocusToken = 0
    /// Mirrors `AetherPreferences.defaultCloudService` so views observe changes.
    public private(set) var defaultCloudService = AetherPreferences.defaultCloudService

    public var searchText = "" {
        didSet { sidebarIndex = min(sidebarIndex, max(sidebarEntries.count - 1, 0)) }
    }

    @ObservationIgnored private var started = false

    public init(library: LibraryViewModel) {
        self.library = library
        self.drawer = QuickDrawerModel(library: library)
        self.gamepad = GamepadManager()
    }

    public static func makeDefault() -> ShellCoordinator {
        ShellCoordinator(library: .makeDefault())
    }

    public func start() {
        guard !started else { return }
        started = true
        drawer.onCloseRequest = { [weak self] in self?.toggleDrawer() }
        drawer.onEndStream = { [weak self] in self?.endStream() }
        gamepad.onCommand = { [weak self] command in self?.handle(command) }
        gamepad.start()
    }

    // MARK: - Derived

    public var filteredGames: [GameItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.games }
        return library.games.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    public var sidebarEntries: [SidebarEntry] {
        [.home, .cloudHub] + filteredGames.map { .game($0.id) }
    }

    public func detailActions(for game: GameItem) -> [DetailAction] {
        var actions: [DetailAction] = [.play]
        if library.decision(for: game)?.allowLocalOverride == true { actions.append(.playLocally) }
        actions.append(.back)
        return actions
    }

    public func isSelected(_ entry: SidebarEntry) -> Bool {
        switch (entry, route) {
        case (.home, .home), (.cloudHub, .cloudHub): true
        case (.game(let a), .game(let b)): a == b
        default: false
        }
    }

    // MARK: - Navigation

    public func open(_ entry: SidebarEntry) {
        switch entry {
        case .home: route = .home
        case .cloudHub: route = .cloudHub
        case .game(let id):
            if let index = library.games.firstIndex(where: { $0.id == id }) { library.focus(index) }
            route = .game(id)
        }
        if let index = sidebarEntries.firstIndex(of: entry) { sidebarIndex = index }
        detailIndex = 0
        cloudIndex = 0
        zone = .content
        rootFocusToken += 1
    }

    public func openGame(_ game: GameItem) {
        open(.game(game.id))
    }

    public func goHome() {
        open(.home)
    }

    public func requestSearchFocus() {
        zone = .sidebar
        searchFocusToken += 1
    }

    /// Return in the search field opens the first match.
    public func submitSearch() {
        if let first = filteredGames.first {
            openGame(first)
        } else {
            rootFocusToken += 1
        }
    }

    public func endSearch() {
        rootFocusToken += 1
    }

    // MARK: - Actions

    public func perform(_ action: DetailAction, for game: GameItem) {
        switch action {
        case .play: Task { await play(game, preference: .automatic) }
        case .playLocally: Task { await play(game, preference: .preferLocal) }
        case .back: goHome()
        }
    }

    public func play(_ game: GameItem, preference: RoutingPreference) async {
        let outcome = await library.play(game, preference: preference)
        if case .needsCloud(let service) = outcome {
            library.startStream(service, for: game)
        }
    }

    public func startStream(_ service: CloudService) {
        library.startStream(service)
    }

    public func endStream() {
        library.endStream()
        drawer.dismiss()
        rootFocusToken += 1
    }

    public func setDefaultCloudService(_ service: CloudService) {
        AetherPreferences.defaultCloudService = service
        defaultCloudService = service
        library.showStatus("\(service.displayName) is now the default for cloud-routed games.")
    }

    public func openNativeClient(_ service: CloudService) {
        guard let app = service.nativeAppURL else {
            library.showStatus("\(service.displayName) has no native app installed.")
            return
        }
        NSWorkspace.shared.open(app)
    }

    // MARK: - Input

    public func handle(_ command: GamepadCommand) {
        // Home/Menu works everywhere: over a fullscreen game and over a stream.
        if command == .toggleDrawer {
            toggleDrawer()
            return
        }
        // While another app (the game) is frontmost, every other press belongs to that game.
        guard NSApp.isActive else { return }

        if drawer.isPresented {
            handleDrawer(command)
            return
        }
        // During a stream the web page reads the controller through the Gamepad API.
        guard library.activeStream == nil else { return }

        switch zone {
        case .sidebar: handleSidebar(command)
        case .content: handleContent(command)
        }
    }

    private func handleDrawer(_ command: GamepadCommand) {
        switch command {
        case .move(let direction): drawer.move(direction)
        case .confirm: Task { await drawer.activateFocused() }
        case .back: toggleDrawer()
        case .secondary, .tertiary, .toggleDrawer: break
        }
    }

    private func handleSidebar(_ command: GamepadCommand) {
        let entries = sidebarEntries
        switch command {
        case .move(.up): sidebarIndex = max(sidebarIndex - 1, 0)
        case .move(.down): sidebarIndex = min(sidebarIndex + 1, max(entries.count - 1, 0))
        case .move(.right), .back: zone = .content
        case .move(.left): break
        case .confirm:
            if entries.indices.contains(sidebarIndex) { open(entries[sidebarIndex]) }
        case .tertiary: Task { await library.refresh() }
        case .secondary, .toggleDrawer: break
        }
    }

    private func handleContent(_ command: GamepadCommand) {
        switch route {
        case .home:
            handleHome(command)
        case .game(let id):
            guard let game = library.game(withID: id) else { return goHome() }
            handleDetail(command, game: game)
        case .cloudHub:
            handleCloudHub(command)
        }
    }

    private func handleHome(_ command: GamepadCommand) {
        switch command {
        case .move(.left) where library.focusedIndex % max(library.columns, 1) == 0:
            zone = .sidebar
        case .move(let direction):
            library.moveFocus(direction)
        case .confirm:
            if let game = library.focusedGame { openGame(game) }
        case .secondary:
            if let game = library.focusedGame { Task { await play(game, preference: .automatic) } }
        case .tertiary:
            Task { await library.refresh() }
        case .back:
            library.dismissStatus()
        case .toggleDrawer:
            break
        }
    }

    private func handleDetail(_ command: GamepadCommand, game: GameItem) {
        let actions = detailActions(for: game)
        switch command {
        case .move(.left):
            if detailIndex == 0 { zone = .sidebar } else { detailIndex -= 1 }
        case .move(.right):
            detailIndex = min(detailIndex + 1, actions.count - 1)
        case .move(.up), .move(.down):
            break
        case .confirm:
            if actions.indices.contains(detailIndex) { perform(actions[detailIndex], for: game) }
        case .secondary:
            perform(.play, for: game)
        case .back:
            goHome()
        case .tertiary, .toggleDrawer:
            break
        }
    }

    private func handleCloudHub(_ command: GamepadCommand) {
        let services = CloudService.allCases
        switch command {
        case .move(.left):
            if cloudIndex == 0 { zone = .sidebar } else { cloudIndex -= 1 }
        case .move(.right):
            cloudIndex = min(cloudIndex + 1, services.count - 1)
        case .move(.up), .move(.down):
            break
        case .confirm:
            startStream(services[cloudIndex])
        case .secondary:
            setDefaultCloudService(services[cloudIndex])
        case .tertiary:
            openNativeClient(services[cloudIndex])
        case .back:
            goHome()
        case .toggleDrawer:
            break
        }
    }

    /// Opening brings Aether to the front. Closing during a native or Wine session hides Aether,
    /// which hands focus straight back to the game. Streams live inside Aether, so they stay put.
    public func toggleDrawer() {
        if drawer.isPresented {
            drawer.dismiss()
            if library.canForceQuit && library.activeStream == nil {
                NSApp.hide(nil)
            }
            rootFocusToken += 1
        } else {
            NSApp.unhide(nil)
            NSApp.activate()
            drawer.present()
        }
    }
}
