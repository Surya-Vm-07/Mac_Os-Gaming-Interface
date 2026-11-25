//! Optional store integrations through their open-source CLIs.
//! - Epic via `legendary`: import installed Windows games, and at launch fetch the auth/launch
//!   parameters Epic's online games need.
//! - GOG via `gogdl`: detection only for now. gogdl has no "list installed" command; installs are
//!   tracked by the frontend that drives it (e.g. Heroic). Import comes with the store screen.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokio::process::Command;

use crate::error::{EngineError, Result};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreTools {
    pub legendary: Option<PathBuf>,
    pub gogdl: Option<PathBuf>,
}

pub fn detect_store_tools(home: &Path) -> StoreTools {
    StoreTools {
        legendary: find_tool("legendary", home),
        gogdl: find_tool("gogdl", home),
    }
}

fn find_tool(name: &str, home: &Path) -> Option<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    dirs.extend([
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        home.join(".local/bin"),
    ]);
    dirs.into_iter().map(|d| d.join(name)).find(|p| p.is_file())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EpicInstall {
    pub app_name: String,
    pub title: String,
    pub install_path: PathBuf,
    pub executable: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EpicLaunch {
    pub executable: PathBuf,
    pub args: Vec<String>,
    pub working_dir: Option<PathBuf>,
}

#[derive(Deserialize)]
struct LegendaryInstalled {
    app_name: String,
    title: String,
    install_path: PathBuf,
    executable: String,
    #[serde(default)]
    platform: Option<String>,
}

/// Parses `legendary list-installed --json`, keeping Windows installs only.
pub fn parse_installed(json: &[u8]) -> Result<Vec<EpicInstall>> {
    let installed: Vec<LegendaryInstalled> = serde_json::from_slice(json)?;
    Ok(installed
        .into_iter()
        .filter(|g| {
            g.platform
                .as_deref()
                .is_none_or(|p| p.eq_ignore_ascii_case("windows"))
        })
        .map(|g| EpicInstall {
            executable: g
                .install_path
                .join(g.executable.trim_start_matches(['/', '\\'])),
            app_name: g.app_name,
            title: g.title,
            install_path: g.install_path,
        })
        .collect())
}

/// Parses `legendary launch <app> --json`. Lenient: unknown or missing keys become empty, so
/// small legendary version changes do not break launching.
pub fn parse_launch(json: &[u8]) -> Result<EpicLaunch> {
    let value: serde_json::Value = serde_json::from_slice(json)?;
    let string = |key: &str| value.get(key).and_then(|v| v.as_str()).map(str::to_owned);
    let list = |key: &str| -> Vec<String> {
        value
            .get(key)
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    };
    let exe = string("game_executable")
        .ok_or_else(|| EngineError::Invalid("legendary returned no game_executable".into()))?;
    let game_dir = string("game_directory").map(PathBuf::from);
    let executable = match (&game_dir, Path::new(&exe).is_absolute()) {
        (Some(dir), false) => dir.join(&exe),
        _ => PathBuf::from(&exe),
    };
    let mut args = list("game_parameters");
    args.extend(list("egl_parameters"));
    args.extend(list("user_parameters"));
    Ok(EpicLaunch {
        executable,
        args,
        working_dir: string("working_directory").map(PathBuf::from).or(game_dir),
    })
}

async fn run_json(bin: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let output = Command::new(bin)
        .args(args)
        .output()
        .await
        .map_err(|e| EngineError::io("run legendary", e))?;
    if !output.status.success() {
        return Err(EngineError::Command {
            command: format!("legendary {}", args.join(" ")),
            status: output.status.code().unwrap_or(-1),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    Ok(output.stdout)
}

pub async fn legendary_installed(bin: &Path) -> Result<Vec<EpicInstall>> {
    parse_installed(&run_json(bin, &["list-installed", "--json"]).await?)
}

pub async fn legendary_launch(bin: &Path, app_name: &str) -> Result<EpicLaunch> {
    parse_launch(&run_json(bin, &["launch", app_name, "--json", "--skip-version-check"]).await?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installed_filters_mac_builds_and_joins_paths() {
        let json = br#"[
            {"app_name":"Fortnite","title":"Fortnite","install_path":"/Games/Fortnite","executable":"FortniteGame/Binaries/Win64/FortniteLauncher.exe","platform":"Windows"},
            {"app_name":"Mac1","title":"Mac Game","install_path":"/Games/Mac","executable":"Mac.app","platform":"Mac"},
            {"app_name":"Old","title":"Old Format","install_path":"/Games/Old","executable":"/Old.exe"}
        ]"#;
        let games = parse_installed(json).unwrap();
        assert_eq!(games.len(), 2);
        assert_eq!(
            games[0].executable,
            PathBuf::from("/Games/Fortnite/FortniteGame/Binaries/Win64/FortniteLauncher.exe")
        );
        assert_eq!(games[1].executable, PathBuf::from("/Games/Old/Old.exe"));
    }

    #[test]
    fn launch_params_merge_in_order() {
        let json = br#"{
            "game_executable": "Binaries/Win64/Game.exe",
            "game_directory": "/Games/G",
            "game_parameters": ["-epicapp=G"],
            "egl_parameters": ["-AUTH_PASSWORD=x", "-epicenv=Prod"],
            "user_parameters": ["-windowed"],
            "unknown_future_key": 1
        }"#;
        let launch = parse_launch(json).unwrap();
        assert_eq!(
            launch.executable,
            PathBuf::from("/Games/G/Binaries/Win64/Game.exe")
        );
        assert_eq!(
            launch.args,
            [
                "-epicapp=G",
                "-AUTH_PASSWORD=x",
                "-epicenv=Prod",
                "-windowed"
            ]
        );
        assert_eq!(launch.working_dir, Some(PathBuf::from("/Games/G")));
        assert!(parse_launch(b"{}").is_err());
    }
}
