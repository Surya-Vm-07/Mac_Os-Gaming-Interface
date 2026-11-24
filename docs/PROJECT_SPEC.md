# Project Aether: Hybrid macOS AAA Gaming Interface
**Version:** 1.0 (Blueprint)  
**Target Platform:** macOS 15+ (Apple Silicon M1–M4/M5 Series)  
**Primary Stack:** Swift 6, SwiftUI, Metal, GameController, Wine + Apple D3DMetal (GPTK), WebRTC/Moonlight  

---

## 1. Executive Summary
**Project Aether** is a native, controller-first visual gaming orchestrator for macOS. Its goal is to deliver a seamless, console-like 60 FPS AAA gaming experience by abstracting away the complexity of macOS compatibility layers. 

Instead of relying on a single virtualization method, Aether acts as a **3-Engine Router** that automatically inspects the user's Apple Silicon hardware and the target game's requirements (DirectX version, shader complexity, kernel anti-cheat) to route each launch to the optimal backend:
1. **Native macOS Engine:** Direct execution of Apple Silicon native binaries.
2. **Local Translation Engine:** Automated Wine bottle orchestration with Apple's **D3DMetal (Game Porting Toolkit)** and DXVK/MoltenVK fallbacks.
3. **Cloud / Remote Streaming Engine:** Borderless, low-latency streaming (Moonlight/Sunshine or WebRTC cloud providers like GeForce NOW) for kernel anti-cheat titles or games exceeding the local Mac's GPU tier.

---

## 2. Core System Architecture

```text
+-------------------------------------------------------------------+
|                     AETHER VISUAL SHELL (SwiftUI)                 |
|  [Game Grid]   [Hero Banner]   [Quick Drawer]   [Telemetry HUD]   |
+-------------------------------------------------------------------+
         |                     |                         |
         v                     v                         v
+-----------------+   +-----------------+      +--------------------+
| Input Manager   |   | 3-Engine Router |      | Library & Metadata |
| (GCController)  |   | (Decision Core) |      | (SteamGridDB/IGDB) |
+-----------------+   +-----------------+      +--------------------+
                               |
          +--------------------+--------------------+
          |                    |                    |
          v                    v                    v
+-------------------+ +-----------------+ +-------------------+
|  Native Launcher  | |  Bottle Manager | |  Stream Wrapper   |
|  (NSWorkspace /   | |  (Wine + GPTK / | |  (Moonlight-Core  |
|   Steam CLI)      | |   D3DMetal /    | |   or WKWebView    |
|                   | |   MSYNC)        | |   WebRTC Client)  |
+-------------------+ +-----------------+ +-------------------+
```

### Key Architectural Requirements
* **Non-Sandboxed macOS App:** App Sandbox must be disabled (`com.apple.security.app-sandbox = false`) so the orchestrator can spawn Wine processes, read external Steam/Epic manifests, manage external SSD game directories, and set environment variables.
* **Ultra-Low Memory Footprint:** Built purely in Swift/SwiftUI (no Electron) to keep idle RAM usage under 150 MB and suspend UI rendering completely while a game is active.
* **Automatic Process Cleanup:** Tracks child PIDs of Wine/wineserver processes to ensure hung Windows games can be cleanly terminated via the Quick-Access Drawer without leaving zombie processes.

---

## 3. The 3-Engine Routing Logic
When a user selects **Play** on any game, the Decision Engine evaluates the following hierarchy:

1. **Check Native Availability:** Is an official Apple Silicon macOS binary installed? -> *Route to Native Engine (Triggers macOS Game Mode).*
2. **Check Kernel Anti-Cheat:** Does the game require Windows kernel-level anti-cheat (e.g., Riot Vanguard, Ricochet, BattlEye/EAC without Wine support)? -> *Force route to Cloud/Remote Stream Engine.*
3. **Evaluate Hardware Tier vs. Game Demand:**
   * Query local Mac specs (`sysctl` chip model, GPU core count, unified memory).
   * Compare against the game's `min_local_tier` in its JSON profile.
   * If hardware meets the 60 FPS threshold (with MetalFX/FSR upscaling) -> *Route to Local Translation Engine (Wine + D3DMetal).*
   * If hardware falls below threshold -> *Offer Cloud Stream (default) or Local Low-Spec override.*

---

## 4. UI/UX Design Specification

### Aesthetic Direction
* **Theme:** Deep obsidian background (`#0A0B0E`), subtle translucent glassmorphic cards (`ultraThinMaterial`), high-contrast electric cyan/amber execution badges.
* **Typography:** SF Pro Display (bold, tight tracking for hero titles) and SF Mono (for telemetry, FPS counters, and engine flags).
* **Motion:** 120Hz ProMotion spring animations for card focus scaling; instant background hero crossfades when navigating the library.

### Navigation & Controller-First UX
* **Zero-Mouse Requirement:** Every view must be navigable via Xbox, DualSense, or Nintendo Pro controllers using Apple's `GameController` framework.
* **Execution Badges:** Every game card displays a clear pill badge:
  * `NATIVE` (Emerald)
  * `METAL LOCAL` (Cyan)
  * `CLOUD 60FPS` (Violet)
* **Quick-Access Overlay Drawer:** Triggered by the controller Home/Guide button (or `Cmd + Shift + G`). Allows users to:
  * Toggle Apple's Metal Performance HUD (`MTL_HUD_ENABLED`).
  * Switch audio output devices.
  * View live CPU/GPU thermal state and memory pressure.
  * Force-quit the active game/Wine bottle.

---

## 5. Recommended Project Folder Structure

```text
Aether/
├── AetherApp.swift                 # App entry point, WindowGroup & menu bar setup
├── Core/
│   ├── Hardware/
│   │   └── MacHardwareProfiler.swift   # Detects M-series chip, RAM, thermal state
│   ├── Routing/
│   │   ├── EngineRouter.swift          # 3-Engine decision logic
│   │   └── GameManifestLoader.swift    # Parses local & remote JSON game profiles
│   ├── Engines/
│   │   ├── NativeEngine.swift          # Direct macOS / Steam launcher
│   │   ├── BottleEngine.swift          # Wine + D3DMetal process orchestrator
│   │   └── StreamEngine.swift          # Moonlight / WebRTC borderless view controller
│   └── Input/
│       └── GamepadManager.swift        # GCController listener & focus bridge
├── Models/
│   ├── GameItem.swift
│   ├── GameProfile.swift
│   └── BottleConfig.swift
├── Services/
│   ├── LibraryScanner.swift            # Scans Steam VDF, local apps, custom folders
│   └── ArtworkFetcher.swift            # SteamGridDB / IGDB API client + disk cache
├── UI/
│   ├── Components/
│   │   ├── GameCardView.swift
│   │   ├── ExecutionBadge.swift
│   │   └── QuickOverlayDrawer.swift
│   ├── Screens/
│   │   ├── LibraryHomeView.swift
│   │   ├── GameDetailView.swift
│   │   ├── StreamPlayerView.swift
│   │   └── SettingsView.swift
│   └── Theme/
│       └── AetherTheme.swift
└── Resources/
    ├── Profiles/                       # Bundled per-game JSON optimization profiles
    └── Scripts/
        └── launch_d3dmetal.sh          # Phase 1 Wine/GPTK bootstrapper
```

---

## 6. Phased Development Roadmap
* **Phase 1: Core Engine & CLI Proof-of-Concept** — Hardware profiler, JSON manifest parser, and working `BottleEngine` that launches a Windows `.exe` via Wine + D3DMetal with Metal HUD enabled.
* **Phase 2: Visual Shell & Library Scanner** — SwiftUI console-style interface, Steam/local directory scanning, and SteamGridDB artwork caching.
* **Phase 3: Controller Navigation & Auto-Config** — Full `GCController` focus engine, per-game optimization profiles, and the Quick-Access Overlay Drawer.
* **Phase 4: Hybrid Cloud & Remote Streaming** — Integrated borderless streaming view for Moonlight/Sunshine and cloud gaming services with native gamepad passthrough.