# Aether Launcher (Tauri)

A $0 Windows-game launcher for Apple Silicon: free Wine Staging runtimes, per-game
**D3DMetal / DXMT / DXVK / WineD3D** backends, isolated bottles, a SQLite library, and a process
runner that cleans up hung `wineserver`s. No CrossOver, no Parallels, no Homebrew.

| Phase | Scope | State |
| --- | --- | --- |
| 1 | Workspace, `Cargo.toml`, `package.json`, Tauri config, Tailwind tokens | Done |
| 2 | Rust engine + Tauri commands + typed IPC client + setup wizard screen | Done: 26 tests, clippy `-D warnings` clean, frontend builds |
| 3 | Full UI: rail, hero, grid, game config, bottle manager, live console, telemetry bar | Next |
| 4 | Bundle and sign `.app` / `.dmg` | Commands below |

## Layout

```text
launcher/
├── Cargo.toml                      workspace (engine + Tauri app)
├── crates/aether-engine/           pure Rust core, no Tauri; unit-tested on any Unix
│   └── src/
│       ├── engine.rs               Engine facade: setup, bottles, games, launching
│       ├── env.rs                  backends, presets, WINE* / MTL_HUD / DXMT_CONFIG env builder
│       ├── runtime.rs              base + derived (APFS-cloned) runtimes per graphics stack
│       ├── components.rs           GPTK import, DXMT overlay, DXVK per-bottle DLLs
│       ├── download.rs             GitHub latest-release resolver + streaming download
│       ├── process.rs              spawn, log streaming, wineserver -w lifetime, group kill
│       ├── library.rs              SQLite (WAL, migrations): bottles + games
│       ├── telemetry.rs            unified memory, CPU, GPU (AGX), Wine process stats
│       ├── stores.rs               legendary (Epic) import + launch params; gogdl detection
│       ├── system.rs               Rosetta / Homebrew / runtime detection; Rosetta install
│       ├── fsutil.rs               cp -c clone, ditto merge, tar extract
│       └── paths.rs                ~/Library/Application Support/Aether Launcher layout
├── src-tauri/                      Tauri v2 shell: commands/{setup,bottles,games,sessions}.rs
├── src/                            React 19 + TS (strict) + Tailwind v4 + Framer Motion
│   ├── styles/tokens.css           design tokens (@theme)
│   ├── lib/{types,ipc,motion}.ts   typed command client, shared motion constants
│   └── features/SetupWizard.tsx    first-launch engine setup
└── package.json
```

## How the $0 stack fits together

- **Wine**: the latest `wine-staging-*-osx64.tar.xz` from Gcenx/macOS_Wine_builds, downloaded
  straight from GitHub. Runs under Rosetta 2, with no quarantine prompt.
- **D3DMetal**: Apple's license forbids redistributing it, so the wizard *imports* it from your own
  free Game Porting Toolkit download (developer.apple.com/games) into a derived runtime.
- **DXMT / DXVK**: open source, downloaded from 3Shain/dxmt and Gcenx/DXVK-macOS.
- Backend switching is per game, with no conflicts: D3DMetal and DXMT each get their own
  copy-on-write APFS clone of the base runtime; DXVK DLLs are synced into the bottle at launch.

## Run it (macOS, Apple Silicon)

Install the Rust toolchain:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Install the JavaScript dependencies (Node 20+ and pnpm):

```bash
cd launcher && pnpm install
```

Run the Rust engine's tests:

```bash
cargo test --workspace
```

Start the app in development mode:

```bash
pnpm tauri dev
```

Bundle a release `.app` and `.dmg` (output in `target/aarch64-apple-darwin/release/bundle/`):

```bash
pnpm app:build
```
