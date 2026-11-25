import Foundation
import GameController
import Observation

/// What a controller press means to the shell. Layout-agnostic: A/Cross, B/Circle, X/Square, Y/Triangle.
public enum GamepadCommand: Sendable, Equatable {
    case move(FocusDirection)
    /// A / Cross
    case confirm
    /// B / Circle
    case back
    /// X / Square: play locally (low-spec override)
    case secondary
    /// Y / Triangle: rescan
    case tertiary
    /// Home / Guide / PS, or Menu (☰ / Options)
    case toggleDrawer
    /// LB / L1: previous tab or filter
    case previousTab
    /// RB / R1: next tab or filter
    case nextTab
}

/// Plain-value copy of a gamepad's state, taken inside the GameController callback.
struct PadState: Sendable, Equatable {
    enum Button: Int, Sendable, Hashable, CaseIterable {
        case a, b, x, y, menu, home, leftShoulder, rightShoulder

        var command: GamepadCommand {
            switch self {
            case .a: .confirm
            case .b: .back
            case .x: .secondary
            case .y: .tertiary
            case .menu, .home: .toggleDrawer
            case .leftShoulder: .previousTab
            case .rightShoulder: .nextTab
            }
        }
    }

    var x: Float = 0
    var y: Float = 0
    var buttons: Set<Button> = []

    init() {}

    init(_ pad: GCExtendedGamepad) {
        // Whichever of D-pad and left stick is deflected more wins.
        let dx = pad.dpad.xAxis.value, dy = pad.dpad.yAxis.value
        let sx = pad.leftThumbstick.xAxis.value, sy = pad.leftThumbstick.yAxis.value
        if abs(dx) + abs(dy) >= abs(sx) + abs(sy) {
            x = dx; y = dy
        } else {
            x = sx; y = sy
        }
        if pad.buttonA.isPressed { buttons.insert(.a) }
        if pad.buttonB.isPressed { buttons.insert(.b) }
        if pad.buttonX.isPressed { buttons.insert(.x) }
        if pad.buttonY.isPressed { buttons.insert(.y) }
        if pad.buttonMenu.isPressed { buttons.insert(.menu) }
        if pad.buttonHome?.isPressed == true { buttons.insert(.home) }
        if pad.leftShoulder.isPressed { buttons.insert(.leftShoulder) }
        if pad.rightShoulder.isPressed { buttons.insert(.rightShoulder) }
    }
}

/// Bridges `GCController` (Xbox, DualSense, DualShock, Switch Pro, MFi) to `GamepadCommand`s.
///
/// - Edge-triggered buttons: one command per press, never per frame.
/// - Directions go through `DirectionalRepeater`: one move, a pause, then a steady repeat.
/// - Background monitoring is ON so Home can summon the Quick Drawer over a running game.
///   The receiver must ignore everything except `.toggleDrawer` while Aether is inactive,
///   otherwise the game's input would also drive the library.
@MainActor
@Observable
public final class GamepadManager {
    /// Vendor name of the active controller, e.g. "Xbox Wireless Controller" or "DualSense Wireless Controller".
    public private(set) var controllerName: String?

    @ObservationIgnored public var onCommand: (@MainActor (GamepadCommand) -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var repeater = DirectionalRepeater()
    @ObservationIgnored private var heldDirection: FocusDirection?
    @ObservationIgnored private var lastState = PadState()
    @ObservationIgnored private var repeatTask: Task<Void, Never>?

    public init() {}

    public func start() {
        guard observers.isEmpty else { return }
        GCController.shouldMonitorBackgroundEvents = true

        let center = NotificationCenter.default
        let names: [Notification.Name] = [.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // queue: .main guarantees we are on the main thread.
                MainActor.assumeIsolated { self?.refreshControllers() }
            }
            observers.append(token)
        }
        refreshControllers()
    }

    public func stop() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        repeatTask?.cancel()
        repeatTask = nil
    }

    // MARK: - Controllers

    private func refreshControllers() {
        let controllers = GCController.controllers()
        controllers.forEach(attach)
        controllerName = (GCController.current ?? controllers.first)?.vendorName
        if controllers.isEmpty {
            resetInput()
        }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main
        // Deliver Home/Menu to us instead of the system (Launchpad / Game Center overlay).
        pad.buttonHome?.preferredSystemGestureState = .disabled
        pad.buttonMenu.preferredSystemGestureState = .disabled

        pad.valueChangedHandler = { [weak self] gamepad, _ in
            let state = PadState(gamepad) // copy values here; GC objects stay out of the main-actor hop
            MainActor.assumeIsolated { self?.process(state) }
        }
    }

    // MARK: - Input processing

    private func process(_ state: PadState) {
        let newlyPressed = state.buttons.subtracting(lastState.buttons)
        lastState = state
        for button in newlyPressed.sorted(by: { $0.rawValue < $1.rawValue }) {
            onCommand?(button.command)
        }
        updateDirection(DirectionalRepeater.direction(x: state.x, y: state.y))
    }

    private func updateDirection(_ direction: FocusDirection?) {
        heldDirection = direction
        if let move = repeater.update(direction, at: .now) {
            onCommand?(.move(move))
        }

        if direction == nil {
            repeatTask?.cancel()
            repeatTask = nil
        } else if repeatTask == nil {
            // GameController only reports *changes*. A steadily held stick sends nothing,
            // so auto-repeat runs on a ~60 Hz tick that exists only while a direction is held.
            repeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(16))
                    guard let self else { return }
                    self.tick()
                }
            }
        }
    }

    private func tick() {
        if let move = repeater.update(heldDirection, at: .now) {
            onCommand?(.move(move))
        }
    }

    private func resetInput() {
        lastState = PadState()
        heldDirection = nil
        _ = repeater.update(nil, at: .now)
        repeatTask?.cancel()
        repeatTask = nil
    }
}
