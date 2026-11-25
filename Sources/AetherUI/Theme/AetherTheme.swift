import AetherCore
import SwiftUI

/// Design tokens (PROJECT_SPEC §4): obsidian base, glass surfaces, electric execution badges.
public enum AetherTheme {

    // MARK: Color

    /// `#0A0B0E`
    public static var obsidian: Color { Color(red: 10 / 255, green: 11 / 255, blue: 14 / 255) }
    // One cool palette, all at the same lightness so nothing shouts:
    //   accent (blue 500/400) for actions and focus, teal = native, blue = Wine,
    //   violet = cloud, amber reserved for warnings.
    /// #3B82F6: primary buttons.
    public static var accent: Color { Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255) }
    /// #2563EB: primary button pressed / hovered.
    public static var accentDeep: Color { Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255) }
    /// #60A5FA: focus rings, labels, links.
    public static var cyan: Color { Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255) }
    /// #5EEAD4: native.
    public static var emerald: Color { Color(red: 94 / 255, green: 234 / 255, blue: 212 / 255) }
    /// #A78BFA: cloud.
    public static var violet: Color { Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255) }
    /// #FBBF24: warnings only.
    public static var amber: Color { Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255) }
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
        // Hues 195°–265° (teal → blue → indigo) so placeholders sit inside the theme.
        let hue = (195 + Double(hash % 70)) / 360
        return [
            Color(hue: hue, saturation: 0.45, brightness: 0.40),
            Color(hue: hue + 0.04, saturation: 0.55, brightness: 0.14),
        ]
    }

    public static func tint(for engine: ExecutionEngine?) -> Color {
        switch engine {
        case .native: emerald
        case .localTranslation: Color(red: 147 / 255, green: 197 / 255, blue: 253 / 255) // blue 300
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
