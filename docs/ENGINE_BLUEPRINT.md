# Project Aether: Technical Blueprint & Starter Code

This document contains the core schemas, hardware tiering matrix, Swift 6 data models, and the Phase 1 D3DMetal launch script needed to bootstrap development.

---

## 1. Apple Silicon Hardware Tiering Matrix
The `MacHardwareProfiler` classifies the host Mac into one of four tiers to predict 60 FPS local feasibility:

| Tier | Representative Hardware | Unified RAM | Local AAA Routing Policy |
| :--- | :--- | :--- | :--- |
| **Tier 1 (Entry)** | M1 / M2 / M3 Base | 8 GB | Route heavy DX12 AAA to **Cloud**. Allow Indie/DX11 locally. |
| **Tier 2 (Mid)** | M1–M4 Base (16GB+) / M1 Pro | 16–24 GB | Local **720p/1080p + MetalFX** for optimized AAA; Cloud for unoptimized titles. |
| **Tier 3 (High)** | M2–M4 Pro / M1–M2 Max | 24–36 GB | Local **1080p/1440p 60 FPS** via D3DMetal as primary engine. |
| **Tier 4 (Ultra)** | M3–M4 Max / Ultra | 48 GB+ | Local **1440p/4K 60+ FPS** via D3DMetal; Cloud only for kernel anti-cheat. |

---

## 2. Per-Game Optimization Manifest (`game_profiles.json`)
Store community-tested flags in JSON so users never manually edit Wine environment variables.

```json
{
  "schema_version": "1.0",
  "profiles": [
    {
      "id": "cyberpunk-2077",
      "title": "Cyberpunk 2077",
      "steam_app_id": "1091500",
      "has_kernel_anticheat": false,
      "native_macos_available": true,
      "min_local_tier": 2,
      "preferred_engine": "native",
      "local_translation": {
        "backend": "d3dmetal",
        "windows_version": "win10",
        "env_vars": {
          "WINEESYNC": "1",
          "WINEMSYNC": "1",
          "D3DM_ENABLE_METALFX": "1",
          "MTL_HUD_ENABLED": "1"
        },
        "launch_args": ["--launcher-skip", "-skipStartScreen"]
      },
      "cloud_fallback": {
        "geforce_now_id": "cyberpunk_2077_steam",
        "moonlight_app_name": "Cyberpunk 2077"
      }
    },
    {
      "id": "valorant",
      "title": "VALORANT",
      "steam_app_id": null,
      "has_kernel_anticheat": true,
      "anticheat_name": "Riot Vanguard",
      "native_macos_available": false,
      "min_local_tier": 99,
      "preferred_engine": "cloud",
      "local_translation": null,
      "cloud_fallback": {
        "geforce_now_id": null,
        "moonlight_app_name": "VALORANT"
      }
    }
  ]
}
```

---

## 3. Core Swift 6 Data Models (`Models.swift`)

```swift
import Foundation

public enum ExecutionEngine: String, Codable, Sendable {
    case native = "NATIVE"
    case localTranslation = "METAL_LOCAL"
    case cloudStream = "CLOUD_60FPS"
}

public enum TranslationBackend: String, Codable, Sendable {
    case d3dmetal
    case dxvk
}

public struct MacHardwareProfile: Sendable {
    public let chipName: String
    public let totalMemoryGB: Int
    public let gpuCoreCount: Int
    public let tier: Int // 1 to 4
}

public struct LocalTranslationConfig: Codable, Sendable {
    public let backend: TranslationBackend
    public let windowsVersion: String
    public let envVars: [String: String]
    public let launchArgs: [String]
}

public struct CloudFallbackConfig: Codable, Sendable {
    public let geforceNowID: String?
    public let moonlightAppName: String?
}

public struct GameProfile: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let steamAppID: String?
    public let hasKernelAnticheat: Bool
    public let anticheatName: String?
    public let nativeMacosAvailable: Bool
    public let minLocalTier: Int
    public let preferredEngine: ExecutionEngine
    public let localTranslation: LocalTranslationConfig?
    public let cloudFallback: CloudFallbackConfig?
}

public struct RoutingDecision: Sendable {
    public let engine: ExecutionEngine
    public let reason: String
    public let allowLocalOverride: Bool
}
```

---

## 4. Phase 1 Wine + D3DMetal Launcher Script (`launch_d3dmetal.sh`)
This script validates the bottle path, injects D3DMetal & MSYNC flags, and launches a Windows executable cleanly while forwarding logs to the Swift `BottleEngine`.

```bash
#!/bin/zsh
set -euo pipefail

# Usage: ./launch_d3dmetal.sh <BOTTLE_PATH> <WINE_BIN> <D3DMETAL_LIB_DIR> <EXE_PATH> [HUD_ENABLED] [ARGS...]

BOTTLE_PATH="$1"
WINE_BIN="$2"
D3DMETAL_LIB_DIR="$3"
EXE_PATH="$4"
HUD_ENABLED="${5:-1}"
shift 5 || true

if [[ ! -f "$EXE_PATH" ]]; then
  echo "[AETHER ERROR] Executable not found: $EXE_PATH" >&2
  exit 1
fi

# Ensure bottle directory exists
mkdir -p "$BOTTLE_PATH"

# Core Wine & Apple D3DMetal Environment
export WINEPREFIX="$BOTTLE_PATH"
export WINEARCH="win64"
export WINEMSYNC="1"
export WINEESYNC="1"
export D3DM_ENABLE_METALFX="1"
export MTL_HUD_ENABLED="$HUD_ENABLED"
export DYLD_FALLBACK_LIBRARY_PATH="${D3DMETAL_LIB_DIR}:${DYLD_FALLBACK_LIBRARY_PATH:-}"

# Suppress noisy Wine debug logs for maximum frame pacing
export WINEDEBUG="-all"

echo "[AETHER] Initializing bottle at: $WINEPREFIX"
echo "[AETHER] Launching: $EXE_PATH (Metal HUD: $HUD_ENABLED)"

# Run via Rosetta 2 (x86_64) for Windows binary translation
exec arch -x86_64 "$WINE_BIN" "$EXE_PATH" "$@"
```

---

## 5. Controller Navigation Pattern (`GamepadManager.swift` Concept)
To keep SwiftUI responsive to controllers without fighting macOS's default keyboard focus:
1. Observe `Notification.Name.GCControllerDidConnect` and `GCControllerDidDisconnect`.
2. Bind `controller.extendedGamepad?.dpad` and `leftThumbstick` to an `@Observable` `GamepadNavigationState` class.
3. Implement a lightweight debounce (150ms) on analog stick input so navigating the game grid feels crisp and mechanical, like a console dashboard.
4. Map `buttonA` to Launch/Select, `buttonB` to Back, and `buttonHome` (or `buttonMenu`) to toggle `isQuickDrawerPresented`.