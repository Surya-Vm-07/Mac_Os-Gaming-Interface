import AetherCore
import AppKit
import Combine
import SwiftUI

/// Window root. Three modes:
/// - **Stream**: the cloud player fills the window; the library is unmounted.
/// - **Game running** (Wine): a minimal status page; the library is unmounted.
/// - **Launcher**: sidebar plus the routed page.
/// The Quick Access drawer overlays all three. Every key becomes a `GamepadCommand`.
public struct RootView: View {
    let shell: ShellCoordinator
    @FocusState private var hasKeyboardFocus: Bool

    public init(shell: ShellCoordinator) {
        self.shell = shell
    }

    public var body: some View {
        ZStack {
            AetherTheme.obsidian.ignoresSafeArea()

            if let service = shell.library.activeStream {
                CloudStreamView(service: service)
                    .ignoresSafeArea()
            } else if shell.library.isGameRunning {
                GameRunningView(library: shell.library)
            } else {
                HStack(spacing: 0) {
                    SidebarView(shell: shell)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .ignoresSafeArea()
            }

            StatusToast(message: shell.library.statusMessage)

            if shell.drawer.isPresented {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { shell.toggleDrawer() }
                    .transition(.opacity)
                QuickOverlayDrawer(drawer: shell.drawer)
                    .transition(.move(edge: .trailing))
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: shell.drawer.isPresented)
        .animation(.easeInOut(duration: 0.2), value: shell.route)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onChange(of: shell.rootFocusToken) { _, _ in hasKeyboardFocus = true }
        .onKeyPress(.leftArrow) { send(.move(.left)) }
        .onKeyPress(.rightArrow) { send(.move(.right)) }
        .onKeyPress(.upArrow) { send(.move(.up)) }
        .onKeyPress(.downArrow) { send(.move(.down)) }
        .onKeyPress(keys: [.return, .space]) { press in
            send(press.modifiers.contains(.shift) ? .secondary : .confirm)
        }
        .onKeyPress(.escape) { send(.back) }
        .task { shell.start() }
        .task { await shell.library.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // Aether in the background (a game is fullscreen): drop decoded artwork.
            ImagePipeline.shared.purge()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch shell.route {
        case .home:
            LibraryHomeView(shell: shell)
        case .game(let id):
            if let game = shell.library.game(withID: id) {
                GameDetailView(shell: shell, game: game)
                    .id(id)
            } else {
                LibraryHomeView(shell: shell)
            }
        case .cloudHub:
            CloudHubView(shell: shell)
        }
    }

    private func send(_ command: GamepadCommand) -> KeyPress.Result {
        shell.handle(command)
        return .handled
    }
}
