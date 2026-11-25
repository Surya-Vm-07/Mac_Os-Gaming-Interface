//! First-launch environment checks for the setup wizard.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Serialize;

use crate::components;
use crate::error::{EngineError, Result};
use crate::runtime::{Runtime, RuntimeFlavor, RuntimeStore};

const ROSETTA_RUNTIME: &str = "/Library/Apple/usr/libexec/oah/libRosettaRuntime";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemReport {
    pub os: String,
    pub arch: String,
    pub apple_silicon: bool,
    pub macos_version: Option<String>,
    /// Required: every Windows game runs as x86_64 under Rosetta 2.
    pub rosetta_installed: bool,
    /// Informational only. Aether never needs Homebrew.
    pub homebrew_path: Option<PathBuf>,
    pub runtimes: Vec<Runtime>,
    pub has_base_runtime: bool,
    pub d3dmetal_ready: bool,
    pub dxmt_ready: bool,
    pub dxvk_ready: bool,
    /// GPTK `lib` folders found on mounted volumes / in ~/Downloads, ready to import.
    pub gptk_candidates: Vec<PathBuf>,
    /// True when the minimum to play is in place: Rosetta and one base runtime.
    pub ready: bool,
}

pub fn system_report(store: &RuntimeStore, dxvk_ready: bool, home: &Path) -> Result<SystemReport> {
    let runtimes = store.list()?;
    let has = |flavor: RuntimeFlavor| runtimes.iter().any(|r| r.manifest.flavor == flavor);
    let apple_silicon = cfg!(all(target_os = "macos", target_arch = "aarch64"));
    let rosetta_installed = Path::new(ROSETTA_RUNTIME).exists();
    let has_base_runtime = has(RuntimeFlavor::Base);

    Ok(SystemReport {
        os: std::env::consts::OS.to_owned(),
        arch: std::env::consts::ARCH.to_owned(),
        apple_silicon,
        macos_version: macos_version(),
        rosetta_installed,
        homebrew_path: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .iter()
            .map(PathBuf::from)
            .find(|p| p.is_file()),
        has_base_runtime,
        d3dmetal_ready: has(RuntimeFlavor::D3dmetal),
        dxmt_ready: has(RuntimeFlavor::Dxmt),
        dxvk_ready,
        gptk_candidates: components::detect_gptk_candidates(home),
        ready: rosetta_installed && has_base_runtime,
        runtimes,
    })
}

fn macos_version() -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let output = Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// Installs Rosetta 2 without the Terminal: macOS shows its standard administrator password
/// prompt through `osascript`.
pub fn install_rosetta() -> Result<()> {
    if Path::new(ROSETTA_RUNTIME).exists() {
        return Ok(());
    }
    if !cfg!(target_os = "macos") {
        return Err(EngineError::Invalid(
            "Rosetta 2 only exists on macOS".into(),
        ));
    }
    let script = r#"do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges"#;
    let output = Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(script)
        .output()
        .map_err(|e| EngineError::io("run osascript", e))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(EngineError::Command {
            command: "softwareupdate --install-rosetta".into(),
            status: output.status.code().unwrap_or(-1),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        })
    }
}
