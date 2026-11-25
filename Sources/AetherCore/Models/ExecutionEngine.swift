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

/// DirectX → Metal translation path inside a Wine bottle.
public enum TranslationBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple Game Porting Toolkit: D3D11/D3D12 → Metal. Best for DX12 AAA.
    case d3dmetal
    /// DXMT: open-source D3D10/D3D11 → Metal. Often the fastest DX11 path.
    case dxmt
    /// DXVK (macOS build): D3D9–11 → Vulkan → MoltenVK → Metal.
    case dxvk
    /// Wine's built-in WineD3D (→ OpenGL). Slowest, most compatible.
    case wined3d

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .wined3d: "WineD3D"
        }
    }

    /// `WINEDLLOVERRIDES` for this backend. DXVK installs **native** DLLs into the bottle (`n,b`).
    /// D3DMetal / DXMT live in their own runtime as **builtins** (`b`); the explicit `b` also beats
    /// DXVK DLLs left in the bottle from an earlier backend switch.
    public var dllOverrides: String {
        switch self {
        case .dxvk: "d3d9,d3d10core,d3d11,dxgi=n,b"
        case .dxmt: "d3d10core,d3d11,dxgi=b"
        case .d3dmetal: "d3d10core,d3d11,d3d12,dxgi=b"
        case .wined3d: "d3d9,d3d10core,d3d11,dxgi=b"
        }
    }
}
