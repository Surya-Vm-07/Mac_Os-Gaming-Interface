//! Aether Launcher: Tauri v2 shell over `aether-engine`.

mod commands;

use std::sync::Arc;

use aether_engine::{AppPaths, Engine};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let home = dirs::home_dir().expect("no home directory");
    // ~/Library/Application Support/Aether Launcher (what the setup wizard and docs refer to).
    let root = dirs::data_dir()
        .unwrap_or_else(|| home.join("Library/Application Support"))
        .join(AppPaths::APP_DIR_NAME);
    let engine = match Engine::open(AppPaths::new(root.clone()), home) {
        Ok(engine) => Arc::new(engine),
        Err(error) => {
            eprintln!(
                "Aether Launcher could not open its data folder {}: {error}",
                root.display()
            );
            std::process::exit(1);
        }
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(engine)
        .invoke_handler(tauri::generate_handler![
            // setup & system
            commands::setup::system_report,
            commands::setup::install_rosetta,
            commands::setup::list_runtimes,
            commands::setup::install_wine,
            commands::setup::import_gptk,
            commands::setup::install_dxmt,
            commands::setup::install_dxvk,
            commands::setup::delete_runtime,
            commands::setup::presets,
            commands::setup::windows_versions,
            commands::setup::store_tools,
            commands::setup::telemetry,
            // bottles
            commands::bottles::list_bottles,
            commands::bottles::create_bottle,
            commands::bottles::clone_bottle,
            commands::bottles::delete_bottle,
            commands::bottles::kill_bottle,
            commands::bottles::run_in_bottle,
            // library
            commands::games::list_games,
            commands::games::add_game,
            commands::games::update_game,
            commands::games::delete_game,
            commands::games::set_artwork,
            commands::games::import_epic,
            // sessions
            commands::sessions::launch_game,
            commands::sessions::kill_session,
            commands::sessions::list_sessions,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Aether Launcher");
}
