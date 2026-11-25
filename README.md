# Project Aether

A native, controller-first game launcher for Apple Silicon Macs. It routes each game to
**Native**, **Local Wine + D3DMetal**, or **Cloud streaming**, and streams cloud services inside
its own window.

**Business model:** a paid launcher app. Users pay for Aether; they bring their own cloud
subscriptions (Xbox Game Pass Ultimate, GeForce NOW) and their own games. Aether hosts no games
and needs no servers.

- Product spec: [`docs/PROJECT_SPEC.md`](docs/PROJECT_SPEC.md)
- Engine blueprint: [`docs/ENGINE_BLUEPRINT.md`](docs/ENGINE_BLUEPRINT.md)

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 1 | Hardware profiler, models, router, manifest loader, BottleEngine, CLI | Done (builds and tests green on macOS) |
| 2 | SwiftUI shell, library scanner, artwork | Implemented (user-confirmed) |
| 3 | GCController focus engine, Quick Overlay Drawer | Done (builds and runs on macOS) |
| 4 | Launcher redesign (sidebar, game page), Cloud hub + in-app streaming | **Implemented, awaiting macOS build** |
| 4b | Local Windows games via setup-wizard runtimes: per-game presets (Max FPS, DX12 AAA, DX11 DXMT, Compatibility), auto bottles, DXVK sync | **Implemented, awaiting macOS build** |
| 5a | Native Engine Setup page in Swift; unified cool palette, no glows; real native-launch errors | **Implemented, awaiting macOS build** |
| 5b | Way back to Home from every screen (stream exit bar, Back to Library, drawer row, ‹ Home); Bottles page: run installers, add installed games, stop, delete | **Implemented, awaiting macOS build** |
| 5c | One-click play from banner, covers and tiles; Play auto-installs Rosetta/Wine/DXMT/DXVK and falls back from D3DMetal; launch spinners | **Implemented, awaiting macOS build** |
| 5d | Delete `launcher/`, licensing, Settings | Next |

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

## Windows games (local, $0)

**Swift is the app.** `launcher/` (Tauri) is a temporary reference and setup wizard, until its
features are ported here. Both share `~/Library/Application Support/Aether Launcher`:

1. Open **Engine Setup** in the sidebar (⌘3) and install Rosetta, Wine Staging, DXMT, DXVK and
   optionally D3DMetal (from your own free Game Porting Toolkit download). Runtimes the Tauri
   wizard already installed are picked up as they are.
2. Drop a Windows game folder (or a single `.exe`) into `~/Documents/Aether Games`.
3. In Aether, open the game, pick a **Performance Preset**, and press Play. The first launch creates
   the game's bottle (20–60 s).

## Run the shell (Phase 2)

```bash
swift run AetherApp
```

Layout: a sidebar (search, Home, Cloud Gaming, full game list) and the main page (Home grid,
game page, or Cloud hub). Press ← at the content's left edge to enter the sidebar; → or Ⓐ goes back.

| Action | Controller | Keyboard |
| --- | --- | --- |
| Move focus | D-pad / left stick | Arrow keys |
| Open game page / activate | Ⓐ / Cross | Return, Space |
| Quick play (or set default service in Cloud hub) | Ⓧ / Square | Shift+Return |
| Rescan (or open native app in Cloud hub) | Ⓨ / Triangle | ⌘R |
| Back | Ⓑ / Circle | Esc |
| Quick Access drawer (End Stream lives here) | Home / Guide / PS, or Menu | ⇧⌘G |
| Search | — | ⌘F |
| Home / Cloud Gaming | — | ⌘1 / ⌘2 |
| End cloud stream | — | ⇧⌘W |

### Cloud streaming

Cloud Gaming opens the service's web client in a borderless in-app player. Your login persists,
pop-up sign-ins work, and the service's fullscreen button works. Games routed to the cloud
(kernel anti-cheat, or above this Mac's tier) open their service with a "search for <title>" hint.
While streaming, the library is unmounted and artwork is dropped; the controller goes to the page
through the browser's Gamepad API, and Home opens the drawer.

The Quick Access drawer shows live CPU, GPU, RAM, swap, memory pressure and thermals (sampled
only while it is open). It also toggles the Metal HUD (applies to the next Wine launch), switches
the audio output, and force-quits the active game. The Home button works while a game is in front:
Aether comes forward with the drawer, and "Return to Game" hands focus back. While another app is
frontmost, Aether ignores every controller input except Home.

To launch Windows games from the UI before the Settings screen exists:

```bash
AETHER_WINE=/path/to/wine64 AETHER_D3DMETAL=/path/to/gptk/redist/lib/external swift run AetherApp
```

### Artwork

Without a key, Steam games use Steam's public CDN. For everything else, add a free SteamGridDB API
key (steamgriddb.com → Preferences → API). It is stored in the login Keychain:

```bash
swift run aether set-artwork-key YOUR_KEY
```

Artwork is cached in `~/Library/Caches/Aether/Artwork`. The UI decodes it at display size into a
capped in-memory cache, and drops that cache when a game launches or Aether goes to the background.

## Phase 1 CLI

```bash
swift run aether hw
```

```bash
swift run aether profiles
```

```bash
swift run aether scan --artwork
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
  Core/Input/GridNavigator            pure grid focus math (keyboard now, gamepad in Phase 3)
  Services/VDF                        Valve KeyValues parser
  Services/LibraryScanner             Steam libraries (incl. Wine-prefix Steam), Games apps, custom folders
  Services/ArtworkFetcher             SteamGridDB + Steam CDN → disk cache (file URLs only)
  Services/SecretStore                Keychain-backed API keys
  Resources/Profiles/game_profiles.json
  Resources/Scripts/launch_d3dmetal.sh
Sources/AetherUI/                     Theme, ExecutionBadge, GameCardView, ImagePipeline, LibraryHomeView, LibraryViewModel
Sources/AetherApp/                    SwiftPM dev host for the SwiftUI shell
Sources/AetherCLI/                    Phase 1 proof-of-concept CLI
Tests/AetherCoreTests/                Swift Testing suites
```

## Signed app target (when you are ready to distribute)

SwiftPM cannot produce a signed `.app` with entitlements, so the SwiftUI shell gets an Xcode app
target that links `AetherUI`:

1. In Xcode, choose **File → New → Project → macOS → App**. Name it `Aether`, set Interface to
   SwiftUI and Language to Swift. Save it in `App/`.
2. Choose **File → Add Package Dependencies → Add Local…**, pick the repo root, then link `AetherUI`.
   Use `Sources/AetherApp/AetherApp.swift` as the app's entry point.
3. Under **Signing & Capabilities**, remove **App Sandbox** and keep **Hardened Runtime**. Set
   *Code Signing Entitlements* to `App/Aether.entitlements`.
4. Merge `App/Info-Additions.plist` into the target's Info.plist.
5. Set **Swift Language Version** to Swift 6 and the deployment target to macOS 15.0.
