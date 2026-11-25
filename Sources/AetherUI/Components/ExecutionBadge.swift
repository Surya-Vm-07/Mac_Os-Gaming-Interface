import AetherCore
import SwiftUI

/// `NATIVE` (emerald) · `METAL LOCAL` (cyan) · `CLOUD 60FPS` (violet) · `UNAVAILABLE` (grey).
public struct ExecutionBadge: View {
    let engine: ExecutionEngine?

    public init(engine: ExecutionEngine?) {
        self.engine = engine
    }

    public var body: some View {
        let tint = AetherTheme.tint(for: engine)
        Text(engine?.badgeLabel ?? "UNAVAILABLE")
            .font(AetherTheme.mono(10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1))
            .accessibilityLabel("Runs via \(engine?.badgeLabel ?? "no available engine")")
    }
}
