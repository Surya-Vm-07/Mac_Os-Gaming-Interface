use std::sync::Arc;

use aether_engine::{Bottle, RunEvent, SessionInfo};
use tauri::ipc::Channel;

use super::{blocking, CmdResult, EngineState};

#[tauri::command]
pub async fn list_bottles(engine: EngineState<'_>) -> CmdResult<Vec<Bottle>> {
    blocking(&engine, |e| e.bottles()).await
}

#[tauri::command]
pub async fn create_bottle(
    engine: EngineState<'_>,
    name: String,
    runtime_id: String,
    windows_version: String,
) -> CmdResult<Bottle> {
    engine
        .inner()
        .clone()
        .create_bottle(&name, &runtime_id, &windows_version)
        .await
}

#[tauri::command]
pub async fn clone_bottle(engine: EngineState<'_>, id: String, name: String) -> CmdResult<Bottle> {
    blocking(&engine, move |e| e.clone_bottle(&id, &name)).await
}

#[tauri::command]
pub async fn delete_bottle(engine: EngineState<'_>, id: String) -> CmdResult<()> {
    engine.inner().clone().delete_bottle(&id).await
}

/// Force-kills everything running in a bottle (hung wineserver, orphaned launchers).
#[tauri::command]
pub async fn kill_bottle(engine: EngineState<'_>, id: String) -> CmdResult<()> {
    engine.inner().clone().kill_bottle(&id).await
}

/// Runs an installer or Wine tool (`winecfg`, `regedit`, `explorer`) inside a bottle, streaming
/// its output to the console drawer.
#[tauri::command]
pub async fn run_in_bottle(
    engine: EngineState<'_>,
    bottle_id: String,
    program: String,
    args: Vec<String>,
    on_event: Channel<RunEvent>,
) -> CmdResult<SessionInfo> {
    let sink = Arc::new(move |event: RunEvent| {
        let _ = on_event.send(event);
    });
    engine
        .inner()
        .clone()
        .run_in_bottle(&bottle_id, &program, args, sink)
        .await
}
