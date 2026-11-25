// TypeScript mirrors of the Rust types (serde camelCase). Keep in sync with crates/aether-engine.

export type GraphicsBackend = "d3dmetal" | "dxmt" | "dxvk" | "wined3d";
export type Preset = "max-fps" | "dx12-aaa" | "dx11-dxmt" | "compatibility" | "custom";
export type RuntimeFlavor = "base" | "d3dmetal" | "dxmt";
export type GameSource = "local" | "steam" | "epic" | "gog";
export type ArtworkKind = "cover" | "hero";

export interface Runtime {
  id: string;
  name: string;
  version: string;
  flavor: RuntimeFlavor;
  baseId: string | null;
  wineRoot: string;
  installedAt: number;
  dir: string;
}

export interface SystemReport {
  os: string;
  arch: string;
  appleSilicon: boolean;
  macosVersion: string | null;
  rosettaInstalled: boolean;
  homebrewPath: string | null;
  runtimes: Runtime[];
  hasBaseRuntime: boolean;
  d3dmetalReady: boolean;
  dxmtReady: boolean;
  dxvkReady: boolean;
  gptkCandidates: string[];
  ready: boolean;
}

export type DownloadProgress =
  | { phase: "resolving" }
  | { phase: "downloading"; received: number; total: number | null }
  | { phase: "extracting" }
  | { phase: "installing" }
  | { phase: "done" };

export interface Bottle {
  id: string;
  name: string;
  path: string;
  runtimeId: string;
  windowsVersion: string;
  createdAt: number;
}

export interface Game {
  id: string;
  title: string;
  exePath: string;
  workingDir: string | null;
  bottleId: string | null;
  preset: Preset;
  backend: GraphicsBackend;
  metalHud: boolean;
  launchArgs: string[];
  envOverrides: Record<string, string>;
  dxmtConfig: string | null;
  coverPath: string | null;
  heroPath: string | null;
  favorite: boolean;
  source: GameSource;
  externalId: string | null;
  addedAt: number;
  lastPlayedAt: number | null;
  playtimeSeconds: number;
}

export interface NewGame {
  title: string;
  exePath: string;
  workingDir?: string | null;
  bottleId?: string | null;
  preset?: Preset;
  backend?: GraphicsBackend;
  launchArgs?: string[];
  source?: GameSource;
  externalId?: string | null;
}

/** Absent key = unchanged; `null` on nullable fields = clear. */
export interface GamePatch {
  title?: string;
  exePath?: string;
  workingDir?: string | null;
  bottleId?: string | null;
  preset?: Preset;
  backend?: GraphicsBackend;
  metalHud?: boolean;
  launchArgs?: string[];
  envOverrides?: Record<string, string>;
  dxmtConfig?: string | null;
  coverPath?: string | null;
  heroPath?: string | null;
  favorite?: boolean;
}

export interface PresetInfo {
  id: Preset;
  name: string;
  description: string;
  backend: GraphicsBackend | null;
  hudDefault: boolean;
  env: Record<string, string>;
}

export interface SessionInfo {
  sessionId: string;
  gameId: string;
  pid: number;
  prefix: string;
  startedUnix: number;
  killing: boolean;
}

export type RunEvent =
  | { type: "started"; sessionId: string; pid: number }
  | { type: "log"; stream: "stdout" | "stderr"; line: string }
  | { type: "exited"; code: number | null; signal: number | null }
  | { type: "idle"; durationSecs: number };

export interface TelemetrySnapshot {
  memoryUsedBytes: number;
  memoryTotalBytes: number;
  swapUsedBytes: number;
  cpuPercent: number;
  gpuPercent: number | null;
  wineProcesses: number;
  wineMemoryBytes: number;
}

export interface StoreTools {
  legendary: string | null;
  gogdl: string | null;
}

export const BACKEND_LABEL: Record<GraphicsBackend, string> = {
  d3dmetal: "D3DMetal",
  dxmt: "DXMT",
  dxvk: "DXVK",
  wined3d: "WineD3D",
};
