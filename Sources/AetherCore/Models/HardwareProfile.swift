import Foundation

/// Aether's 4-tier classification of the host Mac (see ENGINE_BLUEPRINT.md §1).
public enum HardwareTier: Int, Codable, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    case entry = 1
    case mid = 2
    case high = 3
    case ultra = 4

    public static func < (lhs: HardwareTier, rhs: HardwareTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether this tier satisfies a profile's `min_local_tier`.
    public func meets(minimumTier: Int) -> Bool {
        rawValue >= minimumTier
    }

    public var description: String {
        switch self {
        case .entry: "Tier 1 (Entry)"
        case .mid: "Tier 2 (Mid)"
        case .high: "Tier 3 (High)"
        case .ultra: "Tier 4 (Ultra)"
        }
    }
}

/// A parsed Apple Silicon chip identifier, e.g. "Apple M3 Pro" -> (3, .pro).
public struct AppleChip: Sendable, Equatable, CustomStringConvertible {
    public enum Variant: String, Sendable, CaseIterable {
        case base, pro, max, ultra
    }

    public let generation: Int
    public let variant: Variant

    public init(generation: Int, variant: Variant) {
        self.generation = generation
        self.variant = variant
    }

    /// Parses `machdep.cpu.brand_string` / `MTLDevice.name` output such as
    /// "Apple M1", "Apple M2 Max", "Apple M4 Pro", "Apple M1 Ultra".
    /// Returns `nil` for Intel brand strings and virtual-machine placeholders.
    public init?(brandString: String) {
        guard let match = brandString.firstMatch(of: #/\bM(\d+)(?:\s+(Pro|Max|Ultra))?\b/#),
              let generation = Int(match.output.1)
        else { return nil }
        self.generation = generation
        let suffix = match.output.2.map(String.init) ?? ""
        switch suffix {
        case "Pro": variant = .pro
        case "Max": variant = .max
        case "Ultra": variant = .ultra
        default: variant = .base
        }
    }

    public var description: String {
        variant == .base ? "M\(generation)" : "M\(generation) \(variant.rawValue.capitalized)"
    }
}

/// Static description of the host Mac, captured once at launch.
public struct MacHardwareProfile: Sendable, Equatable {
    /// Raw marketing name, e.g. "Apple M3 Max".
    public let chipName: String
    /// Parsed chip, `nil` on Intel or unrecognised hardware.
    public let chip: AppleChip?
    public let isAppleSilicon: Bool
    /// `true` when Aether itself is running under Rosetta (wrong build was shipped).
    public let isRunningUnderRosetta: Bool
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let totalMemoryGB: Int
    /// GPU core count from the IORegistry (`0` if unavailable).
    public let gpuCoreCount: Int
    public let tier: HardwareTier

    public init(
        chipName: String,
        chip: AppleChip?,
        isAppleSilicon: Bool,
        isRunningUnderRosetta: Bool = false,
        performanceCores: Int,
        efficiencyCores: Int,
        totalMemoryGB: Int,
        gpuCoreCount: Int,
        tier: HardwareTier
    ) {
        self.chipName = chipName
        self.chip = chip
        self.isAppleSilicon = isAppleSilicon
        self.isRunningUnderRosetta = isRunningUnderRosetta
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.totalMemoryGB = totalMemoryGB
        self.gpuCoreCount = gpuCoreCount
        self.tier = tier
    }
}

/// Thermal pressure, mirrored from `ProcessInfo.ThermalState` so it is Codable and printable.
public enum ThermalPressure: String, Sendable, Codable {
    case nominal, fair, serious, critical, unknown
}
