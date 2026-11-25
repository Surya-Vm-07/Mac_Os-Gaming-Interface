import AetherCore
import SwiftUI

/// Design tokens (PROJECT_SPEC §4): obsidian base, glass surfaces, electric execution badges.
public enum AetherTheme {

    // MARK: Color

    /// `#0A0B0E`
    public static var obsidian: Color { Color(red: 10 / 255, green: 11 / 255, blue: 14 / 255) }
    public static var emerald: Color { Color(red: 0.12, green: 0.88, blue: 0.56) }
    public static var cyan: Color { Color(red: 0.0, green: 0.86, blue: 1.0) }
    public static var violet: Color { Color(red: 0.66, green: 0.47, blue: 1.0) }
    public static var amber: Color { Color(red: 1.0, green: 0.73, blue: 0.12) }
    public static var unavailable: Color { Color(white: 0.55) }

    public static func tint(for engine: ExecutionEngine?) -> Color {
        switch engine {
        case .native: emerald
        case .localTranslation: cyan
        case .cloudStream: violet
        case nil: unavailable
        }
    }

    // MARK: Type

    /// SF Pro Display, heavy. Pair with `.tracking(heroTracking)`.
    public static var heroTitle: Font { Font.system(size: 56, weight: .heavy) }
    public static let heroTracking: CGFloat = -1.6

    /// SF Mono for telemetry, flags and badges.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Motion

    /// Card focus spring. SwiftUI drives it at the display's refresh rate (120 Hz on ProMotion).
    public static var focusSpring: Animation { Animation.spring(response: 0.28, dampingFraction: 0.72) }
    public static var heroCrossfade: Animation { Animation.easeInOut(duration: 0.22) }
    public static let focusScale: CGFloat = 1.08

    // MARK: Layout

    public static let cardSize = CGSize(width: 200, height: 300)
    public static let cardCornerRadius: CGFloat = 14
    public static let gridSpacing: CGFloat = 28
    /// Horizontal padding inside the scroll view, so focused cards are not clipped when scaled up.
    public static let gridInset: CGFloat = 16

    /// Column count for the available width. The view model needs it so up/down moves exactly one row.
    public static func columns(forWidth width: CGFloat) -> Int {
        let usable = width - gridInset * 2
        return max(1, Int((usable + gridSpacing) / (cardSize.width + gridSpacing)))
    }
}
