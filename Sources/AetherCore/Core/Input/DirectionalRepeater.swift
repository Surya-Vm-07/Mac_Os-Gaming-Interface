/// Turns a held D-pad or stick direction into discrete focus moves:
/// one move at once, then (after `initialDelay`) one every `repeatInterval`. This gives the
/// "crisp, mechanical" console-dashboard feel and keeps analog noise from skipping cards.
public struct DirectionalRepeater: Sendable {
    public var initialDelay: Duration
    public var repeatInterval: Duration

    private var held: FocusDirection?
    private var nextFire: ContinuousClock.Instant?

    public init(initialDelay: Duration = .milliseconds(320), repeatInterval: Duration = .milliseconds(150)) {
        self.initialDelay = initialDelay
        self.repeatInterval = repeatInterval
    }

    public var isHolding: Bool { held != nil }

    /// Feeds the current direction (`nil` = centred). Returns a direction when a move should fire.
    public mutating func update(_ direction: FocusDirection?, at now: ContinuousClock.Instant) -> FocusDirection? {
        guard let direction else {
            held = nil
            nextFire = nil
            return nil
        }
        if direction != held {
            held = direction
            nextFire = now.advanced(by: initialDelay)
            return direction
        }
        if let nextFire, now >= nextFire {
            self.nextFire = now.advanced(by: repeatInterval)
            return direction
        }
        return nil
    }

    /// Dominant-axis direction for a stick or D-pad vector (GameController: +y is up).
    /// The 0.5 deadzone ignores stick drift and diagonal slop.
    public static func direction(x: Float, y: Float, deadzone: Float = 0.5) -> FocusDirection? {
        guard max(abs(x), abs(y)) >= deadzone else { return nil }
        if abs(x) > abs(y) {
            return x > 0 ? .right : .left
        }
        return y > 0 ? .up : .down
    }
}
