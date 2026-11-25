use std::path::PathBuf;

use aether_engine::{
    DownloadProgress, Preset, PresetInfo, Runtime, StoreTools, SystemReport, TelemetrySnapshot,
    WINDOWS_VERSIONS,
};
use tauri::ipc::Channel;

use super::{blocking, CmdResult, EngineState};

#[tauri::command]
pub async fn system_report(engine: EngineState<'_>) -> CmdResult<SystemReport> {
    blocking(&engine, |e| e.system_report()).await
}

/// Shows the macOS administrator prompt and installs Rosetta 2.
#[tauri::command]
pub async fn install_rosetta(engine: EngineState<'_>) -> CmdResult<()> {
    blocking(&engine, |e| e.install_rosetta()).await
}

#[tauri::command]
pub async fn list_runtimes(engine: EngineState<'_>) -> CmdResult<Vec<Runtime>> {
    blocking(&engine, |e| e.runtimes()).await
}

#[tauri::command]
pub async fn install_wine(
    engine: EngineState<'_>,
    on_progress: Channel<DownloadProgress>,
) -> CmdResult<Runtime> {
    let engine = engine.inner().clone();
    let mut progress = move |p: DownloadProgress| {
        let _ = on_progress.send(p);
    };
    engine.install_wine(&mut progress).await
}

#[tauri::command]
pub async fn import_gptk(
    engine: EngineState<'_>,
    base_runtime_id: String,
    gptk_path: PathBuf,
) -> CmdResult<Runtime> {
    blocking(&engine, move |e| {
        e.import_gptk(&base_runtime_id, &gptk_path)
    })
    .await
}

#[tauri::command]
pub async fn install_dxmt(
    engine: EngineState<'_>,
    base_runtime_id: String,
    on_progress: Channel<DownloadProgress>,
) -> CmdResult<Runtime> {
    let engine = engine.inner().clone();
    let mut progress = move |p: DownloadProgress| {
        let _ = on_progress.send(p);
    };
    engine.install_dxmt(&base_runtime_id, &mut progress).await
}

#[tauri::command]
pub async fn install_dxvk(
    engine: EngineState<'_>,
    on_progress: Channel<DownloadProgress>,
) -> CmdResult<PathBuf> {
    let engine = engine.inner().clone();
    let mut progress = move |p: DownloadProgress| {
        let _ = on_progress.send(p);
    };
    engine.install_dxvk(&mut progress).await
}

#[tauri::command]
pub async fn delete_runtime(engine: EngineState<'_>, id: String) -> CmdResult<()> {
    blocking(&engine, move |e| e.delete_runtime(&id)).await
}

#[tauri::command]
pub fn presets() -> Vec<PresetInfo> {
    Preset::ALL.into_iter().map(Preset::info).collect()
}

#[tauri::command]
pub fn windows_versions() -> Vec<&'static str> {
    WINDOWS_VERSIONS.to_vec()
}

#[tauri::command]
pub fn store_tools(engine: EngineState<'_>) -> StoreTools {
    engine.store_tools()
}

#[tauri::command]
pub async fn telemetry(engine: EngineState<'_>) -> CmdResult<TelemetrySnapshot> {
    blocking(&engine, |e| e.telemetry()).await
}
