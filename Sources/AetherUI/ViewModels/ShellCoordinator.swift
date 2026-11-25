import AetherCore
import AppKit
import Observation

/// The single input router. Keyboard keys and controller buttons both become `GamepadCommand`s
/// and go through `handle(_:)`, so the two input methods can never drift apart.
@MainActor
@Observable
public final class ShellCoordinator {
    public let library: LibraryViewModel
    public let drawer: QuickDrawerModel
    public let gamepad: GamepadManager

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
        gamepad.onCommand = { [weak self] command in self?.handle(command) }
        gamepad.start()
    }

    public func handle(_ command: GamepadCommand) {
        // Home/Menu works everywhere, even over a fullscreen game.
        if command == .toggleDrawer {
            toggleDrawer()
            return
        }
        // Background monitoring is on for the Home button. While another app (the game) is
        // frontmost, every other press belongs to that game, not to the library.
        guard NSApp.isActive else { return }

        if drawer.isPresented {
            switch command {
            case .move(let direction): drawer.move(direction)
            case .confirm: Task { await drawer.activateFocused() }
            case .back: toggleDrawer()
            case .secondary, .tertiary, .toggleDrawer: break
            }
            return
        }

        switch command {
        case .move(let direction): library.moveFocus(direction)
        case .confirm: Task { await library.playFocused() }
        case .secondary: Task { await library.playFocused(preference: .preferLocal) }
        case .tertiary: Task { await library.refresh() }
        case .back: library.dismissStatus()
        case .toggleDrawer: break
        }
    }

    /// Opening brings Aether to the front over the game. Closing during a session hides Aether,
    /// which hands focus straight back to the game.
    public func toggleDrawer() {
        if drawer.isPresented {
            drawer.dismiss()
            if library.canForceQuit {
                NSApp.hide(nil)
            }
        } else {
            NSApp.unhide(nil)
            NSApp.activate()
            drawer.present()
        }
    }
}
