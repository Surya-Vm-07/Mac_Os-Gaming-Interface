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
    /// Elevated surfaces: panels, action bars, sidebar.
    public static var carbon: Color { Color(red: 17 / 255, green: 21 / 255, blue: 31 / 255) }
    public static var carbonHigh: Color { Color(red: 24 / 255, green: 29 / 255, blue: 42 / 255) }
    public static var hairline: Color { Color.white.opacity(0.08) }

    /// Deterministic two-stop gradient for games without artwork, so every title gets its own
    /// colour instead of the same grey slab. FNV-1a keeps it stable across launches
    /// (`String.hashValue` is randomised per process).
    public static func placeholderColors(for seed: String) -> [Color] {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let hue = Double(hash % 360) / 360
        return [
            Color(hue: hue, saturation: 0.62, brightness: 0.46),
            Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.16),
        ]
    }

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

    public static let cardSize = CGSize(width: 176, height: 264)
    public static let cardCornerRadius: CGFloat = 10
    public static let gridSpacing: CGFloat = 22
    /// Extra padding around the grid, so focused cards are not clipped when scaled up.
    public static let gridInset: CGFloat = 10
    /// Horizontal page margin of the main content area.
    public static let pageMargin: CGFloat = 40
    public static let heroHeight: CGFloat = 440

    /// Column count for the available width. The view model needs it so up/down moves exactly one row.
    public static func columns(forWidth width: CGFloat) -> Int {
        let usable = width - gridInset * 2
        return max(1, Int((usable + gridSpacing) / (cardSize.width + gridSpacing)))
    }
}
