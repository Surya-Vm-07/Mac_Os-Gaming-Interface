//! Graphics backends, performance presets, and the launch environment builder.
//!
//! Precedence, lowest → highest:
//! base (WINEPREFIX, WINEDEBUG, WINEDLLOVERRIDES) → preset → Metal HUD toggle → DXMT_CONFIG
//! → per-game user overrides → WINEPREFIX (always re-pinned last, so it cannot be overridden).

use std::collections::BTreeMap;
use std::path::Path;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

use crate::error::EngineError;

/// DirectX → Metal translation path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GraphicsBackend {
    /// Apple Game Porting Toolkit: D3D11/D3D12 → Metal. Best for DX12 AAA.
    D3dmetal,
    /// DXMT: D3D10/D3D11 → Metal, open source. Often the fastest DX11 path.
    Dxmt,
    /// DXVK (macOS build) over MoltenVK: D3D9–11 → Vulkan → Metal.
    Dxvk,
    /// Wine's built-in WineD3D (→ OpenGL). Slowest, most compatible.
    Wined3d,
}

impl GraphicsBackend {
    pub const ALL: [GraphicsBackend; 4] = [Self::D3dmetal, Self::Dxmt, Self::Dxvk, Self::Wined3d];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::D3dmetal => "d3dmetal",
            Self::Dxmt => "dxmt",
            Self::Dxvk => "dxvk",
            Self::Wined3d => "wined3d",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::D3dmetal => "D3DMetal",
            Self::Dxmt => "DXMT",
            Self::Dxvk => "DXVK",
            Self::Wined3d => "WineD3D",
        }
    }

    /// `WINEDLLOVERRIDES` for this backend.
    /// - DXVK installs **native** DLLs into the bottle → `n,b`.
    /// - D3DMetal / DXMT live in a derived runtime as **builtins** → `b`. The explicit `b` also
    ///   beats any DXVK DLLs left in the bottle from an earlier backend switch.
    pub fn dll_overrides(self) -> &'static str {
        match self {
            Self::Dxvk => "d3d9,d3d10core,d3d11,dxgi=n,b",
            Self::Dxmt => "d3d10core,d3d11,dxgi=b",
            Self::D3dmetal => "d3d10core,d3d11,d3d12,dxgi=b",
            Self::Wined3d => "d3d9,d3d10core,d3d11,dxgi=b",
        }
    }
}

impl FromStr for GraphicsBackend {
    type Err = EngineError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|b| b.as_str() == s)
            .ok_or_else(|| EngineError::Invalid(format!("unknown graphics backend `{s}`")))
    }
}

/// One-click performance presets. `Custom` keeps the game's own backend and adds no preset vars.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Preset {
    MaxFps,
    Dx12Aaa,
    Dx11Dxmt,
    Compatibility,
    Custom,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PresetInfo {
    pub id: Preset,
    pub name: &'static str,
    pub description: &'static str,
    /// `None` for `Custom`: the game's chosen backend applies.
    pub backend: Option<GraphicsBackend>,
    pub hud_default: bool,
    pub env: BTreeMap<&'static str, &'static str>,
}

impl Preset {
    pub const ALL: [Preset; 5] = [
        Self::MaxFps,
        Self::Dx12Aaa,
        Self::Dx11Dxmt,
        Self::Compatibility,
        Self::Custom,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::MaxFps => "max-fps",
            Self::Dx12Aaa => "dx12-aaa",
            Self::Dx11Dxmt => "dx11-dxmt",
            Self::Compatibility => "compatibility",
            Self::Custom => "custom",
        }
    }

    pub fn backend(self) -> Option<GraphicsBackend> {
        match self {
            Self::MaxFps | Self::Dx12Aaa => Some(GraphicsBackend::D3dmetal),
            Self::Dx11Dxmt => Some(GraphicsBackend::Dxmt),
            Self::Compatibility => Some(GraphicsBackend::Wined3d),
            Self::Custom => None,
        }
    }

    /// The backend a game actually uses under this preset.
    pub fn effective_backend(self, game_backend: GraphicsBackend) -> GraphicsBackend {
        self.backend().unwrap_or(game_backend)
    }

    /// Environment variables the preset sets.
    /// - `WINEMSYNC`: Mach-semaphore sync (macOS-native, lowest overhead). `WINEESYNC` is the
    ///   eventfd/kqueue fallback, kept on for builds without msync.
    /// - `ROSETTA_ADVERTISE_AVX`: Rosetta (macOS 15+) reports AVX/AVX2, which many 2020+ engines require.
    /// - `D3DM_ENABLE_METALFX`: lets D3DMetal map DLSS calls to MetalFX upscaling.
    pub fn env(self) -> BTreeMap<&'static str, &'static str> {
        let pairs: &[(&str, &str)] = match self {
            Self::MaxFps => &[
                ("WINEMSYNC", "1"),
                ("WINEESYNC", "1"),
                ("ROSETTA_ADVERTISE_AVX", "1"),
                ("D3DM_ENABLE_METALFX", "1"),
                ("WINEDEBUG", "-all"),
            ],
            Self::Dx12Aaa => &[
                ("WINEMSYNC", "1"),
                ("WINEESYNC", "1"),
                ("ROSETTA_ADVERTISE_AVX", "1"),
                ("D3DM_ENABLE_METALFX", "1"),
            ],
            Self::Dx11Dxmt => &[
                ("WINEMSYNC", "1"),
                ("WINEESYNC", "1"),
                ("ROSETTA_ADVERTISE_AVX", "1"),
            ],
            // Fewest moving parts; keep Wine's fixme channel quiet but errors visible in the console.
            Self::Compatibility => &[
                ("WINEESYNC", "1"),
                ("WINEMSYNC", "0"),
                ("WINEDEBUG", "fixme-all"),
            ],
            Self::Custom => &[],
        };
        pairs.iter().copied().collect()
    }

    pub fn info(self) -> PresetInfo {
        let (name, description, hud_default) = match self {
            Self::MaxFps => (
                "Max FPS",
                "D3DMetal + MSync + AVX, MetalFX on, all logging off. Squeezes every frame.",
                false,
            ),
            Self::Dx12Aaa => (
                "DX12 AAA · D3DMetal",
                "Apple's D3DMetal for DX12/DX11 AAA titles, MetalFX, Metal HUD on.",
                true,
            ),
            Self::Dx11Dxmt => (
                "DX11 · DXMT",
                "Open-source DXMT; frequently the fastest path for DX10/DX11 games.",
                false,
            ),
            Self::Compatibility => (
                "Compatibility",
                "WineD3D, no MSync. Slow but runs the most games; use it to debug.",
                false,
            ),
            Self::Custom => (
                "Custom",
                "Your own backend and environment variables only.",
                false,
            ),
        };
        PresetInfo {
            id: self,
            name,
            description,
            backend: self.backend(),
            hud_default,
            env: self.env(),
        }
    }
}

impl FromStr for Preset {
    type Err = EngineError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|p| p.as_str() == s)
            .ok_or_else(|| EngineError::Invalid(format!("unknown preset `{s}`")))
    }
}

/// Inputs for one launch's environment.
#[derive(Debug, Clone)]
pub struct EnvRequest<'a> {
    pub prefix: &'a Path,
    pub preset: Preset,
    pub backend: GraphicsBackend,
    pub metal_hud: bool,
    /// Passed through verbatim as `DXMT_CONFIG` (see DXMT's docs for keys).
    pub dxmt_config: Option<&'a str>,
    pub user_overrides: &'a BTreeMap<String, String>,
}

/// Builds the complete Wine environment for a launch. Pure and deterministic, so it is unit-tested.
pub fn build_env(req: &EnvRequest<'_>) -> BTreeMap<String, String> {
    let backend = req.preset.effective_backend(req.backend);
    let mut env = BTreeMap::new();
    let prefix = req.prefix.to_string_lossy().into_owned();

    env.insert("WINEPREFIX".into(), prefix.clone());
    env.insert("WINEDEBUG".into(), "-all".into());
    env.insert("WINEDLLOVERRIDES".into(), backend.dll_overrides().into());

    for (k, v) in req.preset.env() {
        env.insert(k.into(), v.into());
    }
    env.insert(
        "MTL_HUD_ENABLED".into(),
        if req.metal_hud { "1" } else { "0" }.into(),
    );
    if let Some(config) = req.dxmt_config.filter(|c| !c.trim().is_empty()) {
        env.insert("DXMT_CONFIG".into(), config.trim().into());
    }
    for (k, v) in req.user_overrides {
        let key = k.trim();
        if !key.is_empty() {
            env.insert(key.to_owned(), v.clone());
        }
    }
    // The prefix is owned by the bottle. A stray override would write into another bottle.
    env.insert("WINEPREFIX".into(), prefix);
    env
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn request<'a>(
        prefix: &'a Path,
        preset: Preset,
        overrides: &'a BTreeMap<String, String>,
    ) -> EnvRequest<'a> {
        EnvRequest {
            prefix,
            preset,
            backend: GraphicsBackend::Dxvk,
            metal_hud: false,
            dxmt_config: None,
            user_overrides: overrides,
        }
    }

    #[test]
    fn preset_forces_backend_and_vars() {
        let prefix = PathBuf::from("/b/elden");
        let none = BTreeMap::new();
        let env = build_env(&request(&prefix, Preset::Dx12Aaa, &none));
        assert_eq!(env["WINEPREFIX"], "/b/elden");
        assert_eq!(
            env["WINEDLLOVERRIDES"],
            GraphicsBackend::D3dmetal.dll_overrides()
        );
        assert_eq!(env["WINEMSYNC"], "1");
        assert_eq!(env["ROSETTA_ADVERTISE_AVX"], "1");
        assert_eq!(env["D3DM_ENABLE_METALFX"], "1");
        assert_eq!(env["MTL_HUD_ENABLED"], "0");
    }

    #[test]
    fn custom_keeps_game_backend() {
        let prefix = PathBuf::from("/b/x");
        let none = BTreeMap::new();
        let env = build_env(&request(&prefix, Preset::Custom, &none));
        assert_eq!(env["WINEDLLOVERRIDES"], "d3d9,d3d10core,d3d11,dxgi=n,b");
        assert!(!env.contains_key("WINEMSYNC"));
        assert_eq!(env["WINEDEBUG"], "-all");
    }

    #[test]
    fn precedence_user_wins_but_prefix_is_pinned() {
        let prefix = PathBuf::from("/b/mine");
        let overrides = BTreeMap::from([
            ("WINEMSYNC".to_string(), "0".to_string()),
            ("WINEPREFIX".to_string(), "/b/someone-else".to_string()),
            ("DXVK_HUD".to_string(), "fps".to_string()),
            ("  ".to_string(), "ignored".to_string()),
        ]);
        let mut req = request(&prefix, Preset::MaxFps, &overrides);
        req.metal_hud = true;
        req.dxmt_config = Some("  d3d11.preferredMaxFrameRate=60  ");
        let env = build_env(&req);
        assert_eq!(env["WINEMSYNC"], "0");
        assert_eq!(env["WINEPREFIX"], "/b/mine");
        assert_eq!(env["DXVK_HUD"], "fps");
        assert_eq!(env["MTL_HUD_ENABLED"], "1");
        assert_eq!(env["DXMT_CONFIG"], "d3d11.preferredMaxFrameRate=60");
        assert!(!env.contains_key(""));
    }

    #[test]
    fn round_trips_through_strings() {
        for p in Preset::ALL {
            assert_eq!(p.as_str().parse::<Preset>().unwrap(), p);
            assert_eq!(
                serde_json::to_value(p).unwrap(),
                serde_json::json!(p.as_str())
            );
        }
        for b in GraphicsBackend::ALL {
            assert_eq!(b.as_str().parse::<GraphicsBackend>().unwrap(), b);
            assert_eq!(
                serde_json::to_value(b).unwrap(),
                serde_json::json!(b.as_str())
            );
        }
        assert!("vulkan".parse::<GraphicsBackend>().is_err());
    }
}
