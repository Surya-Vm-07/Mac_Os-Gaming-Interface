# Project Aether

A native, controller-first gaming orchestrator for Apple Silicon Macs. It routes each game to
**Native**, **Local Wine + D3DMetal**, or **Cloud/Remote streaming**.

- Product spec: [`docs/PROJECT_SPEC.md`](docs/PROJECT_SPEC.md)
- Engine blueprint: [`docs/ENGINE_BLUEPRINT.md`](docs/ENGINE_BLUEPRINT.md)

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 1 | Hardware profiler, models, router, manifest loader, BottleEngine, CLI | **Implemented, awaiting first macOS build** |
| 2 | SwiftUI shell, library scanner, artwork | Not started |
| 3 | GCController focus engine, Quick Overlay Drawer | Not started |
| 4 | Streaming engine | Not started |

## Requirements

- macOS 15+ on Apple Silicon
- Xcode 16+ (Swift 6 toolchain, Swift Testing)
- Rosetta 2: `softwareupdate --install-rosetta --agree-to-license`
- A GPTK-compatible Wine build (`wine64` + `wineserver`) and the D3DMetal libraries from Apple's
  Game Porting Toolkit (`redist/lib/external`)

## Build and test

```bash
swift build
```

```bash
swift test
```

Two `BottleEngine` tests spawn real processes, using fake `wine64` / `wineserver` shell scripts.
They are skipped automatically when Rosetta 2 is not installed.

## Phase 1 CLI

```bash
swift run aether hw
```

```bash
swift run aether profiles
```

```bash
swift run aether route cyberpunk-2077 --exe "/Volumes/SSD/Games/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe"
```

```bash
swift run aether launch \
  --wine /path/to/wine/bin/wine64 \
  --d3dmetal /path/to/gptk/redist/lib/external \
  --exe "/Volumes/SSD/Games/Game/game.exe" \
  --profile cyberpunk-2077
```

Press Ctrl-C to run a clean teardown: SIGTERM, a 5 s grace period, `wineserver -k` for the whole
prefix, then SIGKILL as a last resort.

## Layout

```text
Package.swift                         Swift 6 package (AetherCore lib, aether CLI, tests)
App/Aether.entitlements               Non-sandboxed entitlements for the Phase 2 app target
App/Info-Additions.plist              Info.plist keys (Games category, GameController)
Sources/AetherCore/
  Models/                             ExecutionEngine, GameProfile, HardwareProfile, RoutingDecision, BottleConfig
  Core/Hardware/MacHardwareProfiler   sysctlbyname + IORegistry → Tier 1–4
  Core/Routing/EngineRouter           3-engine decision core (pure)
  Core/Routing/GameManifestLoader     bundled + user JSON profiles, merged by id
  Core/Engines/BottleEngine           actor: spawn, log stream, wineserver-aware lifecycle
  Resources/Profiles/game_profiles.json
  Resources/Scripts/launch_d3dmetal.sh
Sources/AetherCLI/                    Phase 1 proof-of-concept CLI
Tests/AetherCoreTests/                Swift Testing suites
```

## App target setup (Phase 2)

SwiftPM cannot produce a signed `.app` with entitlements, so the SwiftUI shell gets an Xcode app
target that links `AetherCore`:

1. In Xcode, choose **File → New → Project → macOS → App**. Name it `Aether`, set Interface to
   SwiftUI and Language to Swift. Save it in `App/`.
2. Choose **File → Add Package Dependencies → Add Local…**, pick the repo root, then link `AetherCore`.
3. Under **Signing & Capabilities**, remove **App Sandbox** and keep **Hardened Runtime**. Set
   *Code Signing Entitlements* to `App/Aether.entitlements`.
4. Merge `App/Info-Additions.plist` into the target's Info.plist.
5. Set **Swift Language Version** to Swift 6 and the deployment target to macOS 15.0.
