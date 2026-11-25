// Typed client for every Tauri command in src-tauri/src/commands. Errors reject with the engine's
// message string. Streaming commands take a callback and wire up a tauri `Channel` internally.

import { Channel, convertFileSrc, invoke } from "@tauri-apps/api/core";
import type {
  ArtworkKind,
  Bottle,
  DownloadProgress,
  Game,
  GamePatch,
  NewGame,
  PresetInfo,
  RunEvent,
  Runtime,
  SessionInfo,
  StoreTools,
  SystemReport,
  TelemetrySnapshot,
} from "./types";

function channel<T>(onMessage: (message: T) => void): Channel<T> {
  const ch = new Channel<T>();
  ch.onmessage = onMessage;
  return ch;
}

export const api = {
  // Setup & system
  systemReport: () => invoke<SystemReport>("system_report"),
  installRosetta: () => invoke<void>("install_rosetta"),
  listRuntimes: () => invoke<Runtime[]>("list_runtimes"),
  installWine: (onProgress: (p: DownloadProgress) => void) =>
    invoke<Runtime>("install_wine", { onProgress: channel(onProgress) }),
  importGptk: (baseRuntimeId: string, gptkPath: string) =>
    invoke<Runtime>("import_gptk", { baseRuntimeId, gptkPath }),
  installDxmt: (baseRuntimeId: string, onProgress: (p: DownloadProgress) => void) =>
    invoke<Runtime>("install_dxmt", { baseRuntimeId, onProgress: channel(onProgress) }),
  installDxvk: (onProgress: (p: DownloadProgress) => void) =>
    invoke<string>("install_dxvk", { onProgress: channel(onProgress) }),
  deleteRuntime: (id: string) => invoke<void>("delete_runtime", { id }),
  presets: () => invoke<PresetInfo[]>("presets"),
  windowsVersions: () => invoke<string[]>("windows_versions"),
  storeTools: () => invoke<StoreTools>("store_tools"),
  telemetry: () => invoke<TelemetrySnapshot>("telemetry"),

  // Bottles
  listBottles: () => invoke<Bottle[]>("list_bottles"),
  createBottle: (name: string, runtimeId: string, windowsVersion: string) =>
    invoke<Bottle>("create_bottle", { name, runtimeId, windowsVersion }),
  cloneBottle: (id: string, name: string) => invoke<Bottle>("clone_bottle", { id, name }),
  deleteBottle: (id: string) => invoke<void>("delete_bottle", { id }),
  killBottle: (id: string) => invoke<void>("kill_bottle", { id }),
  runInBottle: (bottleId: string, program: string, args: string[], onEvent: (e: RunEvent) => void) =>
    invoke<SessionInfo>("run_in_bottle", { bottleId, program, args, onEvent: channel(onEvent) }),

  // Library
  listGames: () => invoke<Game[]>("list_games"),
  addGame: (game: NewGame) => invoke<Game>("add_game", { game }),
  updateGame: (id: string, patch: GamePatch) => invoke<Game>("update_game", { id, patch }),
  deleteGame: (id: string) => invoke<void>("delete_game", { id }),
  setArtwork: (id: string, kind: ArtworkKind, source: string) => invoke<Game>("set_artwork", { id, kind, source }),
  importEpic: () => invoke<Game[]>("import_epic"),

  // Sessions
  launchGame: (id: string, onEvent: (e: RunEvent) => void) =>
    invoke<SessionInfo>("launch_game", { id, onEvent: channel(onEvent) }),
  killSession: (sessionId: string) => invoke<void>("kill_session", { sessionId }),
  listSessions: () => invoke<SessionInfo[]>("list_sessions"),
};

/** Local artwork path → URL the webview can load (asset protocol, scoped in tauri.conf.json). */
export const assetUrl = (path: string | null): string | null => (path ? convertFileSrc(path) : null);

export function errorMessage(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  return JSON.stringify(error);
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(0)} KB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(0)} MB`;
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
}
