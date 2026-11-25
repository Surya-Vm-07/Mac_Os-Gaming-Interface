//! Tauri IPC commands. Each one is a thin adapter over `aether_engine::Engine`:
//! async work is awaited directly, blocking work (file copies, osascript) goes to the blocking
//! pool so the IPC thread never stalls. Streaming progress and logs use `tauri::ipc::Channel`.

pub mod bottles;
pub mod games;
pub mod sessions;
pub mod setup;

use std::sync::Arc;

use aether_engine::{Engine, EngineError};
use tauri::State;

pub type EngineState<'a> = State<'a, Arc<Engine>>;
pub type CmdResult<T> = Result<T, EngineError>;

/// Runs blocking engine work on Tauri's blocking pool.
pub async fn blocking<T, F>(engine: &EngineState<'_>, f: F) -> CmdResult<T>
where
    T: Send + 'static,
    F: FnOnce(&Engine) -> CmdResult<T> + Send + 'static,
{
    let engine = engine.inner().clone();
    tauri::async_runtime::spawn_blocking(move || f(&engine))
        .await
        .map_err(|e| EngineError::Invalid(format!("background task failed: {e}")))?
}
