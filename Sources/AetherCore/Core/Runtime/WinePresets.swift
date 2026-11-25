import Foundation

/// One-click performance presets. Each one picks a translation backend and its environment.
/// `.custom` keeps the game's own backend and adds no preset variables.
public enum PerformancePreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case maxFPS = "max-fps"
    case dx12AAA = "dx12-aaa"
    case dx11DXMT = "dx11-dxmt"
    case compatibility
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .maxFPS: "Max FPS"
        case .dx12AAA: "DX12 AAA · D3DMetal"
        case .dx11DXMT: "DX11 · DXMT"
        case .compatibility: "Compatibility"
        case .custom: "Custom"
        }
    }

    public var summary: String {
        switch self {
        case .maxFPS: "D3DMetal + MSync + AVX, MetalFX on, all logging off."
        case .dx12AAA: "Apple D3DMetal for DX12/DX11 AAA, MetalFX, Metal HUD on."
        case .dx11DXMT: "Open-source DXMT; often the fastest DX10/DX11 path."
        case .compatibility: "WineD3D, no MSync. Slow, but runs the most games."
        case .custom: "The game profile's backend and variables only."
        }
    }

    /// `nil` for `.custom`: the game's own backend applies.
    public var backend: TranslationBackend? {
        switch self {
        case .maxFPS, .dx12AAA: .d3dmetal
        case .dx11DXMT: .dxmt
        case .compatibility: .wined3d
        case .custom: nil
        }
    }

    public var metalHUDDefault: Bool { self == .dx12AAA }

    public func effectiveBackend(_ gameBackend: TranslationBackend) -> TranslationBackend {
        backend ?? gameBackend
    }

    /// - `WINEMSYNC`: Mach-semaphore sync, the macOS-native and lowest-overhead option. `WINEESYNC` stays on
    ///   as the fallback for builds without msync.
    /// - `ROSETTA_ADVERTISE_AVX`: Rosetta (macOS 15+) reports AVX/AVX2, which many 2020+ engines require.
    /// - `D3DM_ENABLE_METALFX`: lets D3DMetal map DLSS calls to MetalFX upscaling.
    public var environment: [String: String] {
        switch self {
        case .maxFPS:
            ["WINEMSYNC": "1", "WINEESYNC": "1", "ROSETTA_ADVERTISE_AVX": "1", "D3DM_ENABLE_METALFX": "1", "WINEDEBUG": "-all"]
        case .dx12AAA:
            ["WINEMSYNC": "1", "WINEESYNC": "1", "ROSETTA_ADVERTISE_AVX": "1", "D3DM_ENABLE_METALFX": "1"]
        case .dx11DXMT:
            ["WINEMSYNC": "1", "WINEESYNC": "1", "ROSETTA_ADVERTISE_AVX": "1"]
        case .compatibility:
            ["WINEESYNC": "1", "WINEMSYNC": "0", "WINEDEBUG": "fixme-all"]
        case .custom:
            [:]
        }
    }

    /// Best default for a game given the graphics stacks actually installed:
    /// D3DMetal for D3DMetal-profiled games when available, else DXMT, else WineD3D.
    public static func recommended(profileBackend: TranslationBackend, installed: Set<RuntimeFlavor>) -> PerformancePreset {
        if profileBackend == .d3dmetal, installed.contains(.d3dmetal) { return .dx12AAA }
        if installed.contains(.dxmt) { return .dx11DXMT }
        return .compatibility
    }
}

/// Builds the complete Wine environment for one launch. Pure, so it is unit-tested.
///
/// Precedence, lowest → highest: base (WINEPREFIX, WINEDEBUG, WINEDLLOVERRIDES) → preset → game profile
/// → Metal HUD toggle → DXMT_CONFIG → user overrides → WINEPREFIX re-pinned (never overridable).
public enum WineEnvironment {
    public static func build(
        prefix: URL,
        preset: PerformancePreset,
        backend: TranslationBackend,
        metalHUD: Bool,
        dxmtConfig: String? = nil,
        profileEnvironment: [String: String] = [:],
        userOverrides: [String: String] = [:]
    ) -> [String: String] {
        let prefixPath = prefix.path(percentEncoded: false)
        var env: [String: String] = [
            "WINEPREFIX": prefixPath,
            "WINEDEBUG": "-all",
            "WINEDLLOVERRIDES": preset.effectiveBackend(backend).dllOverrides,
        ]
        let blocked: (String) -> Bool = { $0.isEmpty || $0.hasPrefix("DYLD_") }

        env.merge(preset.environment) { _, new in new }
        for (key, value) in profileEnvironment where !blocked(key) { env[key] = value }
        env["MTL_HUD_ENABLED"] = metalHUD ? "1" : "0"
        if let config = dxmtConfig?.trimmingCharacters(in: .whitespaces), !config.isEmpty {
            env["DXMT_CONFIG"] = config
        }
        for (key, value) in userOverrides {
            let key = key.trimmingCharacters(in: .whitespaces)
            if !blocked(key) { env[key] = value }
        }
        env["WINEPREFIX"] = prefixPath
        return env
    }
}
