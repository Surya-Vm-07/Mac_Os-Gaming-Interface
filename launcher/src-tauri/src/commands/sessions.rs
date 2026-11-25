use std::sync::Arc;

use aether_engine::{RunEvent, SessionInfo};
use tauri::ipc::Channel;

use super::{CmdResult, EngineState};

/// Launches a game. `on_event` receives `started`, `log`, `exited` and finally `idle`, which fires
/// once every process in the bottle has exited. Playtime is recorded automatically.
#[tauri::command]
pub async fn launch_game(
    engine: EngineState<'_>,
    id: String,
    on_event: Channel<RunEvent>,
) -> CmdResult<SessionInfo> {
    let sink = Arc::new(move |event: RunEvent| {
        let _ = on_event.send(event);
    });
    engine.inner().clone().launch_game(&id, sink).await
}

/// SIGTERM → 5 s grace → `wineserver -k` → SIGKILL.
#[tauri::command]
pub async fn kill_session(engine: EngineState<'_>, session_id: String) -> CmdResult<()> {
    engine.inner().clone().kill_session(&session_id).await
}

#[tauri::command]
pub fn list_sessions(engine: EngineState<'_>) -> Vec<SessionInfo> {
    engine.sessions()
}
