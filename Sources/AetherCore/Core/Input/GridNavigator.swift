/// Direction from a D-pad, analog stick or arrow key.
public enum FocusDirection: Sendable, Equatable, CaseIterable {
    case up, down, left, right
}

/// Pure focus math for a row-major grid. The keyboard (Phase 2) and the GCController focus
/// engine (Phase 3) share it, so both behave the same.
///
/// Console behaviour: edges stop instead of wrapping. Pressing down onto a shorter last row
/// lands on that row's last item.
public enum GridNavigator {
    public static func move(from index: Int, _ direction: FocusDirection, count: Int, columns: Int) -> Int {
        guard count > 0 else { return 0 }
        let columns = max(1, columns)
        let current = min(max(index, 0), count - 1)

        switch direction {
        case .left:
            return current % columns == 0 ? current : current - 1
        case .right:
            let atRowEnd = current % columns == columns - 1 || current == count - 1
            return atRowEnd ? current : current + 1
        case .up:
            return current >= columns ? current - columns : current
        case .down:
            let target = current + columns
            if target < count { return target }
            let hasNextRow = current / columns < (count - 1) / columns
            return hasNextRow ? count - 1 : current
        }
    }
}
