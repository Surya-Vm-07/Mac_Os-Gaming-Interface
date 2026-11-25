//! `Engine`: the single facade the Tauri layer talks to. It owns the paths, the runtime store, the
//! SQLite library, the process runner and telemetry, and orchestrates multi-step operations
//! (setup downloads, bottle lifecycle, launching).

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::process::Command;

use crate::components;
use crate::download::{self, DownloadProgress};
use crate::env::{build_env, EnvRequest, GraphicsBackend};
use crate::error::{EngineError, IoContext, Result};
use crate::fsutil;
use crate::library::{Bottle, Game, GamePatch, GameSource, Library, NewGame};
use crate::paths::{now_unix, slugify, AppPaths};
use crate::process::{self, EventSink, LaunchSpec, RunEvent, Runner, SessionInfo};
use crate::runtime::{Runtime, RuntimeFlavor, RuntimeStore};
use crate::stores;
use crate::system::{self, SystemReport};
use crate::telemetry::{Telemetry, TelemetrySnapshot};

pub const WINDOWS_VERSIONS: [&str; 6] = ["win11", "win10", "win81", "win8", "win7", "winxp"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ArtworkKind {
    Cover,
    Hero,
}

pub struct Engine {
    paths: AppPaths,
    home: PathBuf,
    runtimes: RuntimeStore,
    library: Arc<Mutex<Library>>,
    runner: Runner,
    telemetry: Mutex<Telemetry>,
    http: reqwest::Client,
}

impl Engine {
    pub fn open(paths: AppPaths, home: PathBuf) -> Result<Self> {
        paths.ensure()?;
        Ok(Self {
            runtimes: RuntimeStore::new(paths.clone()),
            library: Arc::new(Mutex::new(Library::open(&paths.database())?)),
            runner: Runner::new(),
            telemetry: Mutex::new(Telemetry::new(paths.runtimes())),
            http: download::http_client()?,
            paths,
            home,
        })
    }

    pub fn paths(&self) -> &AppPaths {
        &self.paths
    }

    fn db<T>(&self, f: impl FnOnce(&Library) -> Result<T>) -> Result<T> {
        let library = self
            .library
            .lock()
            .map_err(|_| EngineError::Invalid("library lock poisoned".into()))?;
        f(&library)
    }

    // MARK: - Setup wizard

    pub fn system_report(&self) -> Result<SystemReport> {
        system::system_report(
            &self.runtimes,
            components::installed_dxvk(&self.paths).is_some(),
            &self.home,
        )
    }

    pub fn install_rosetta(&self) -> Result<()> {
        system::install_rosetta()
    }

    pub fn runtimes(&self) -> Result<Vec<Runtime>> {
        self.runtimes.list()
    }

    /// Downloads and registers the latest free Wine Staging build as a base runtime.
    pub async fn install_wine(
        &self,
        progress: &mut (dyn FnMut(DownloadProgress) + Send),
    ) -> Result<Runtime> {
        let (asset, staging) =
            components::fetch_release(&self.paths, &self.http, &download::WINE_STAGING, progress)
                .await?;
        progress(DownloadProgress::Installing);
        let target = self.runtimes.new_base_dir("Wine Staging", &asset.version());
        let result = (|| {
            if target.exists() {
                std::fs::remove_dir_all(&target).at("remove", &target)?;
            }
            std::fs::rename(&staging, &target).at("move runtime into", &target)?;
            self.runtimes
                .register_base(&target, "Wine Staging", &asset.version())
        })();
        let _ = std::fs::remove_dir_all(&staging);
        let runtime = result?;
        progress(DownloadProgress::Done);
        Ok(runtime)
    }

    /// Imports Apple's D3DMetal from the user's GPTK folder into `<base>+d3dmetal`.
    pub fn import_gptk(&self, base_id: &str, gptk_path: &Path) -> Result<Runtime> {
        let base = self.runtimes.get(base_id)?;
        components::install_d3dmetal(&self.runtimes, &base, gptk_path)
    }

    pub async fn install_dxmt(
        &self,
        base_id: &str,
        progress: &mut (dyn FnMut(DownloadProgress) + Send),
    ) -> Result<Runtime> {
        let base = self.runtimes.get(base_id)?;
        let (_, staging) =
            components::fetch_release(&self.paths, &self.http, &download::DXMT, progress).await?;
        progress(DownloadProgress::Installing);
        let result = components::install_dxmt_from_dir(&self.runtimes, &base, &staging);
        let _ = std::fs::remove_dir_all(&staging);
        progress(DownloadProgress::Done);
        result
    }

    pub async fn install_dxvk(
        &self,
        progress: &mut (dyn FnMut(DownloadProgress) + Send),
    ) -> Result<PathBuf> {
        let (asset, staging) =
            components::fetch_release(&self.paths, &self.http, &download::DXVK_MACOS, progress)
                .await?;
        progress(DownloadProgress::Installing);
        let result = components::install_dxvk_from_dir(&self.paths, &staging, &asset.version());
        let _ = std::fs::remove_dir_all(&staging);
        progress(DownloadProgress::Done);
        result
    }

    pub fn delete_runtime(&self, id: &str) -> Result<()> {
        let in_use: Vec<String> = self
            .db(|l| l.list_bottles())?
            .into_iter()
            .filter(|b| b.runtime_id == id)
            .map(|b| b.name)
            .collect();
        if !in_use.is_empty() {
            return Err(EngineError::Invalid(format!(
                "runtime is used by bottle(s): {}",
                in_use.join(", ")
            )));
        }
        self.runtimes.delete(id)
    }

    // MARK: - Bottles

    pub fn bottles(&self) -> Result<Vec<Bottle>> {
        self.db(|l| l.list_bottles())
    }

    /// Creates and initialises a Wine prefix (`wineboot --init`, then the Windows version).
    /// Mono/Gecko install prompts are suppressed so creation never blocks on a dialog.
    pub async fn create_bottle(
        &self,
        name: &str,
        runtime_id: &str,
        windows_version: &str,
    ) -> Result<Bottle> {
        let name = name.trim();
        if name.is_empty() {
            return Err(EngineError::Invalid("bottle name is required".into()));
        }
        if !WINDOWS_VERSIONS.contains(&windows_version) {
            return Err(EngineError::Invalid(format!(
                "unsupported Windows version `{windows_version}`"
            )));
        }
        let runtime = self.runtimes.get(runtime_id)?;
        if runtime.manifest.flavor != RuntimeFlavor::Base {
            return Err(EngineError::Invalid(
                "bottles are created on a base runtime; graphics stacks are picked per game".into(),
            ));
        }

        let id = uuid::Uuid::new_v4().to_string();
        let path = self
            .paths
            .bottles()
            .join(format!("{}-{}", slugify(name), &id[..8]));
        std::fs::create_dir_all(&path).at("create bottle", &path)?;

        let init = async {
            wine_tool(&runtime, &path, &["wineboot", "--init"]).await?;
            wine_tool(&runtime, &path, &["winecfg", "-v", windows_version]).await?;
            process::Runner::kill_prefix(&runtime.wineserver(), &path)
                .await
                .ok();
            Ok::<_, EngineError>(())
        };
        if let Err(error) = tokio::time::timeout(Duration::from_secs(600), init)
            .await
            .unwrap_or_else(|_| {
                Err(EngineError::Invalid(
                    "bottle initialisation timed out after 10 minutes".into(),
                ))
            })
        {
            let _ = std::fs::remove_dir_all(&path);
            return Err(error);
        }

        let bottle = Bottle {
            id,
            name: name.to_owned(),
            path,
            runtime_id: runtime_id.to_owned(),
            windows_version: windows_version.to_owned(),
            created_at: now_unix(),
        };
        self.db(|l| l.insert_bottle(&bottle))?;
        Ok(bottle)
    }

    /// Instant APFS clone of a bottle, e.g. a pre-configured "clean Win10 + DXVK" template.
    pub fn clone_bottle(&self, id: &str, new_name: &str) -> Result<Bottle> {
        let source = self.db(|l| l.get_bottle(id))?;
        if self
            .runner
            .sessions()
            .iter()
            .any(|s| s.prefix == source.path)
        {
            return Err(EngineError::Invalid(
                "stop the game running in this bottle before cloning it".into(),
            ));
        }
        let new_id = uuid::Uuid::new_v4().to_string();
        let path = self
            .paths
            .bottles()
            .join(format!("{}-{}", slugify(new_name), &new_id[..8]));
        fsutil::clone_tree(&source.path, &path)?;
        let bottle = Bottle {
            id: new_id,
            name: new_name.trim().to_owned(),
            path,
            created_at: now_unix(),
            ..source
        };
        if let Err(e) = self.db(|l| l.insert_bottle(&bottle)) {
            let _ = std::fs::remove_dir_all(&bottle.path);
            return Err(e);
        }
        Ok(bottle)
    }

    pub async fn delete_bottle(&self, id: &str) -> Result<()> {
        let bottle = self.db(|l| l.get_bottle(id))?;
        let in_use = self.db(|l| l.games_in_bottle(id))?;
        if in_use > 0 {
            return Err(EngineError::Invalid(format!(
                "{in_use} game(s) still use this bottle; move or remove them first"
            )));
        }
        if let Ok(runtime) = self.runtimes.get(&bottle.runtime_id) {
            Runner::kill_prefix(&runtime.wineserver(), &bottle.path)
                .await
                .ok();
        }
        if bottle.path.starts_with(self.paths.bottles()) && bottle.path.exists() {
            std::fs::remove_dir_all(&bottle.path).at("delete bottle", &bottle.path)?;
        }
        self.db(|l| l.delete_bottle_row(id))
    }

    /// Kills every Wine process in a bottle (hung `wineserver`, orphaned launchers).
    pub async fn kill_bottle(&self, id: &str) -> Result<()> {
        let bottle = self.db(|l| l.get_bottle(id))?;
        let runtime = self.runtimes.get(&bottle.runtime_id)?;
        Runner::kill_prefix(&runtime.wineserver(), &bottle.path).await
    }

    // MARK: - Games

    pub fn games(&self) -> Result<Vec<Game>> {
        self.db(|l| l.list_games())
    }

    pub fn add_game(&self, new: NewGame) -> Result<Game> {
        if let Some(bottle_id) = &new.bottle_id {
            self.db(|l| l.get_bottle(bottle_id))?;
        }
        self.db(|l| l.add_game(new))
    }

    pub fn update_game(&self, id: &str, patch: GamePatch) -> Result<Game> {
        self.db(|l| l.update_game(id, patch))
    }

    pub fn delete_game(&self, id: &str) -> Result<()> {
        if self.runner.is_game_running(id) {
            return Err(EngineError::Invalid(
                "stop the game before removing it".into(),
            ));
        }
        self.db(|l| l.delete_game(id))
    }

    /// Copies a user-picked image into the app's artwork folder, so the library survives the
    /// original file moving and the webview only ever reads from one asset scope.
    pub fn set_artwork(&self, game_id: &str, kind: ArtworkKind, source: &Path) -> Result<Game> {
        let ext = source
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("img")
            .to_ascii_lowercase();
        if !["png", "jpg", "jpeg", "webp", "avif", "gif"].contains(&ext.as_str()) {
            return Err(EngineError::Invalid(format!(
                "unsupported image type `.{ext}`"
            )));
        }
        let suffix = match kind {
            ArtworkKind::Cover => "cover",
            ArtworkKind::Hero => "hero",
        };
        let dest = self
            .paths
            .artwork()
            .join(format!("{game_id}-{suffix}-{}.{ext}", now_unix()));
        std::fs::copy(source, &dest).at("copy artwork to", &dest)?;
        let previous = self.db(|l| l.get_game(game_id))?;
        let patch = match kind {
            ArtworkKind::Cover => GamePatch {
                cover_path: Some(Some(dest)),
                ..Default::default()
            },
            ArtworkKind::Hero => GamePatch {
                hero_path: Some(Some(dest)),
                ..Default::default()
            },
        };
        let game = self.db(|l| l.update_game(game_id, patch))?;
        let old = match kind {
            ArtworkKind::Cover => previous.cover_path,
            ArtworkKind::Hero => previous.hero_path,
        };
        if let Some(old) = old.filter(|p| p.starts_with(self.paths.artwork())) {
            let _ = std::fs::remove_file(old);
        }
        Ok(game)
    }

    /// Imports Windows games installed with `legendary` that are not in the library yet.
    pub async fn import_epic(&self) -> Result<Vec<Game>> {
        let tools = stores::detect_store_tools(&self.home);
        let bin = tools.legendary.ok_or_else(|| {
            EngineError::Missing("legendary (Epic Games CLI) is not installed".into())
        })?;
        let installs = stores::legendary_installed(&bin).await?;
        let mut added = Vec::new();
        for install in installs {
            if self
                .db(|l| l.find_by_external(GameSource::Epic, &install.app_name))?
                .is_some()
            {
                continue;
            }
            added.push(self.db(|l| {
                l.add_game(NewGame {
                    title: install.title.clone(),
                    exe_path: install.executable.clone(),
                    working_dir: Some(install.install_path.clone()),
                    source: Some(GameSource::Epic),
                    external_id: Some(install.app_name.clone()),
                    ..Default::default()
                })
            })?);
        }
        Ok(added)
    }

    pub fn store_tools(&self) -> stores::StoreTools {
        stores::detect_store_tools(&self.home)
    }

    // MARK: - Launching

    /// Resolves bottle, runtime flavor, DLLs and environment, then starts the game.
    /// Playtime and last-played are recorded automatically.
    pub async fn launch_game(&self, game_id: &str, sink: EventSink) -> Result<SessionInfo> {
        let game = self.db(|l| l.get_game(game_id))?;
        let bottle_id = game.bottle_id.clone().ok_or_else(|| {
            EngineError::Invalid(format!("assign a bottle to {} first", game.title))
        })?;
        let bottle = self.db(|l| l.get_bottle(&bottle_id))?;
        let backend = game.effective_backend();
        let runtime = self.runtimes.resolve(&bottle.runtime_id, backend)?;

        if backend == GraphicsBackend::Dxvk {
            let dxvk = components::installed_dxvk(&self.paths).ok_or_else(|| {
                EngineError::Missing(
                    "DXVK is not installed. Open Bottles → Graphics stacks.".into(),
                )
            })?;
            components::sync_dxvk_into_prefix(&dxvk, &bottle.path)?;
        }

        let (program, mut args, mut working_dir) =
            (game.exe_path.clone(), Vec::new(), game.working_dir.clone());
        let mut program = program;
        if game.source == GameSource::Epic {
            if let (Some(bin), Some(app)) = (
                stores::detect_store_tools(&self.home).legendary,
                game.external_id.as_deref(),
            ) {
                // Epic online titles need fresh auth parameters on every launch.
                if let Ok(launch) = stores::legendary_launch(&bin, app).await {
                    program = launch.executable;
                    args = launch.args;
                    working_dir = launch.working_dir.or(working_dir);
                }
            }
        }
        args.extend(game.launch_args.iter().cloned());

        if !program.is_file() {
            return Err(EngineError::NotFound(format!(
                "game executable {}",
                program.display()
            )));
        }
        let working_dir = working_dir
            .filter(|d| d.is_dir())
            .or_else(|| program.parent().map(Path::to_path_buf))
            .unwrap_or_else(|| self.home.clone());

        let env = build_env(&EnvRequest {
            prefix: &bottle.path,
            preset: game.preset,
            backend: game.backend,
            metal_hud: game.metal_hud,
            dxmt_config: game.dxmt_config.as_deref(),
            user_overrides: &game.env_overrides,
        });

        let spec = LaunchSpec {
            game_id: game.id.clone(),
            wine: runtime.wine_binary(),
            wineserver: runtime.wineserver(),
            prefix: bottle.path.clone(),
            program,
            args,
            working_dir,
            env,
        };

        // Wrap the caller's sink: record playtime when the bottle goes idle.
        let library = self.library.clone();
        let id = game.id.clone();
        let recording_sink: EventSink = Arc::new(move |event: RunEvent| {
            if let RunEvent::Idle { duration_secs } = &event {
                if let Ok(lib) = library.lock() {
                    let _ = lib.add_playtime(&id, *duration_secs as i64);
                }
            }
            sink(event);
        });

        let session = self.runner.launch(spec, recording_sink).await?;
        self.db(|l| l.mark_launched(&game.id, now_unix()))?;
        Ok(session)
    }

    /// Runs any Windows program inside a bottle: installers, `winecfg`, `regedit`, `explorer`.
    pub async fn run_in_bottle(
        &self,
        bottle_id: &str,
        program: &str,
        args: Vec<String>,
        sink: EventSink,
    ) -> Result<SessionInfo> {
        let bottle = self.db(|l| l.get_bottle(bottle_id))?;
        let runtime = self.runtimes.get(&bottle.runtime_id)?;
        let program_path = PathBuf::from(program);
        let working_dir = program_path
            .parent()
            .filter(|p| p.is_dir())
            .map(Path::to_path_buf)
            .unwrap_or_else(|| self.home.clone());
        let env = build_env(&EnvRequest {
            prefix: &bottle.path,
            preset: crate::env::Preset::Compatibility,
            backend: GraphicsBackend::Wined3d,
            metal_hud: false,
            dxmt_config: None,
            user_overrides: &Default::default(),
        });
        self.runner
            .launch(
                LaunchSpec {
                    game_id: format!("bottle:{bottle_id}:{program}"),
                    wine: runtime.wine_binary(),
                    wineserver: runtime.wineserver(),
                    prefix: bottle.path,
                    program: program_path,
                    args,
                    working_dir,
                    env,
                },
                sink,
            )
            .await
    }

    pub async fn kill_session(&self, session_id: &str) -> Result<()> {
        self.runner.kill(session_id, Duration::from_secs(5)).await
    }

    pub fn sessions(&self) -> Vec<SessionInfo> {
        self.runner.sessions()
    }

    pub fn telemetry(&self) -> Result<TelemetrySnapshot> {
        let mut telemetry = self
            .telemetry
            .lock()
            .map_err(|_| EngineError::Invalid("telemetry lock poisoned".into()))?;
        Ok(telemetry.sample())
    }
}

/// Runs a Wine built-in tool (wineboot, winecfg, …) in a prefix and waits for it.
async fn wine_tool(runtime: &Runtime, prefix: &Path, args: &[&str]) -> Result<()> {
    let output = Command::new(runtime.wine_binary())
        .args(args)
        .env_clear()
        .envs(process::base_process_env())
        .env("WINEPREFIX", prefix)
        .env("WINEDEBUG", "-all")
        .env("WINEDLLOVERRIDES", "mscoree,mshtml=")
        .stdin(Stdio::null())
        .output()
        .await
        .map_err(|e| EngineError::io(format!("run {}", runtime.wine_binary().display()), e))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(EngineError::Command {
            command: format!("wine {}", args.join(" ")),
            status: output.status.code().unwrap_or(-1),
            stderr: String::from_utf8_lossy(&output.stderr)
                .lines()
                .rev()
                .take(12)
                .collect::<Vec<_>>()
                .join("\n"),
        })
    }
}
