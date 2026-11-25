import AetherCore
import SwiftUI

/// Window root: library + Quick Access drawer overlay, and the only keyboard entry point.
/// Every key becomes a `GamepadCommand`, so the keyboard and the controller behave the same.
public struct RootView: View {
    let shell: ShellCoordinator
    @FocusState private var hasKeyboardFocus: Bool

    public init(shell: ShellCoordinator) {
        self.shell = shell
    }

    public var body: some View {
        ZStack {
            LibraryHomeView(model: shell.library)

            if shell.drawer.isPresented {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { shell.toggleDrawer() }
                    .transition(.opacity)
                QuickOverlayDrawer(drawer: shell.drawer)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: shell.drawer.isPresented)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onAppear { hasKeyboardFocus = true }
        .onKeyPress(.leftArrow) { send(.move(.left)) }
        .onKeyPress(.rightArrow) { send(.move(.right)) }
        .onKeyPress(.upArrow) { send(.move(.up)) }
        .onKeyPress(.downArrow) { send(.move(.down)) }
        .onKeyPress(keys: [.return, .space]) { press in
            send(press.modifiers.contains(.shift) ? .secondary : .confirm)
        }
        .onKeyPress(.escape) { send(.back) }
        .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in send(.tertiary) }
        .task { shell.start() }
    }

    private func send(_ command: GamepadCommand) -> KeyPress.Result {
        shell.handle(command)
        return .handled
    }
}
