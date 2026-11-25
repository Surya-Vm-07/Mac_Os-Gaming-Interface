use std::path::PathBuf;

use aether_engine::{ArtworkKind, Game, GamePatch, NewGame};

use super::{blocking, CmdResult, EngineState};

#[tauri::command]
pub async fn list_games(engine: EngineState<'_>) -> CmdResult<Vec<Game>> {
    blocking(&engine, |e| e.games()).await
}

#[tauri::command]
pub async fn add_game(engine: EngineState<'_>, game: NewGame) -> CmdResult<Game> {
    blocking(&engine, move |e| e.add_game(game)).await
}

#[tauri::command]
pub async fn update_game(engine: EngineState<'_>, id: String, patch: GamePatch) -> CmdResult<Game> {
    blocking(&engine, move |e| e.update_game(&id, patch)).await
}

#[tauri::command]
pub async fn delete_game(engine: EngineState<'_>, id: String) -> CmdResult<()> {
    blocking(&engine, move |e| e.delete_game(&id)).await
}

#[tauri::command]
pub async fn set_artwork(
    engine: EngineState<'_>,
    id: String,
    kind: ArtworkKind,
    source: PathBuf,
) -> CmdResult<Game> {
    blocking(&engine, move |e| e.set_artwork(&id, kind, &source)).await
}

/// Imports Windows games installed with the `legendary` Epic Games CLI.
#[tauri::command]
pub async fn import_epic(engine: EngineState<'_>) -> CmdResult<Vec<Game>> {
    engine.inner().clone().import_epic().await
}
