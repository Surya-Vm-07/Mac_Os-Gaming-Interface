//! # aether-engine
//!
//! The $0 Windows-games-on-Apple-Silicon core behind Aether Launcher:
//! free Wine Staging runtimes, D3DMetal / DXMT / DXVK graphics stacks, isolated bottles,
//! a SQLite library and a process runner with clean teardown. No Tauri dependency, so
//! everything here is unit-tested on plain Unix.

pub mod components;
pub mod download;
pub mod engine;
pub mod env;
pub mod error;
pub mod fsutil;
pub mod library;
pub mod paths;
pub mod process;
pub mod runtime;
pub mod stores;
pub mod system;
pub mod telemetry;

pub use download::DownloadProgress;
pub use engine::{ArtworkKind, Engine, WINDOWS_VERSIONS};
pub use env::{GraphicsBackend, Preset, PresetInfo};
pub use error::{EngineError, Result};
pub use library::{Bottle, Game, GamePatch, GameSource, NewGame};
pub use paths::AppPaths;
pub use process::{EventSink, LogStream, RunEvent, SessionInfo};
pub use runtime::{Runtime, RuntimeFlavor};
pub use stores::StoreTools;
pub use system::SystemReport;
pub use telemetry::TelemetrySnapshot;
