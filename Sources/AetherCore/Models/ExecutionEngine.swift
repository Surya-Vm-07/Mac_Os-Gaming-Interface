import Foundation

/// The three execution backends Aether can route a game to.
///
/// Raw values match the `preferred_engine` strings used in `game_profiles.json`
/// (`"native"`, `"local"`, `"cloud"`). The blueprint's original raw values
/// (`"NATIVE"`, `"METAL_LOCAL"`, `"CLOUD_60FPS"`) did NOT match its own JSON
/// (`"native"`, `"cloud"`), so decoding the sample manifest would have failed.
/// Decoding here accepts both spellings; UI text lives in `badgeLabel`.
public enum ExecutionEngine: String, Codable, Sendable, CaseIterable {
    case native
    case localTranslation = "local"
    case cloudStream = "cloud"

    /// Text for the execution pill badge on game cards.
    public var badgeLabel: String {
        switch self {
        case .native: "NATIVE"
        case .localTranslation: "METAL LOCAL"
        case .cloudStream: "CLOUD 60FPS"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw.lowercased() {
        case "native":
            self = .native
        case "local", "metal_local", "local_translation", "d3dmetal":
            self = .localTranslation
        case "cloud", "cloud_60fps", "cloud_stream", "stream":
            self = .cloudStream
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown execution engine '\(raw)'. Expected native | local | cloud."
            )
        }
    }
    // encode(to:) is synthesized from RawRepresentable and writes "native" / "local" / "cloud".
}

/// Windows-graphics translation backend used inside a Wine bottle.
public enum TranslationBackend: String, Codable, Sendable, CaseIterable {
    /// Apple Game Porting Toolkit D3D11/D3D12 -> Metal.
    case d3dmetal
    /// DXVK (D3D -> Vulkan) over MoltenVK (Vulkan -> Metal). Not implemented in Phase 1.
    case dxvk
}
