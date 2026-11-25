use std::path::{Path, PathBuf};

use crate::error::{IoContext, Result};

/// On-disk layout under `~/Library/Application Support/Aether Launcher`:
///
/// ```text
/// runtimes/<id>/runtime.json + extracted Wine     (base and derived runtimes)
/// bottles/<slug>-<id8>/                           (Wine prefixes)
/// components/dxvk/<version>/{x64,x32}/*.dll       (per-bottle native DLL sets)
/// artwork/<game-id>-{cover,hero}.<ext>
/// downloads/                                      (partial downloads, cleaned after extract)
/// logs/<game-id>.log                              (last session log per game)
/// library.sqlite3
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppPaths {
    root: PathBuf,
}

impl AppPaths {
    pub const APP_DIR_NAME: &'static str = "Aether Launcher";

    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn runtimes(&self) -> PathBuf {
        self.root.join("runtimes")
    }
    pub fn bottles(&self) -> PathBuf {
        self.root.join("bottles")
    }
    pub fn components(&self) -> PathBuf {
        self.root.join("components")
    }
    pub fn artwork(&self) -> PathBuf {
        self.root.join("artwork")
    }
    pub fn downloads(&self) -> PathBuf {
        self.root.join("downloads")
    }
    pub fn logs(&self) -> PathBuf {
        self.root.join("logs")
    }
    pub fn database(&self) -> PathBuf {
        self.root.join("library.sqlite3")
    }

    /// Creates every directory. Idempotent; call once at startup.
    pub fn ensure(&self) -> Result<()> {
        for dir in [
            self.root.clone(),
            self.runtimes(),
            self.bottles(),
            self.components(),
            self.artwork(),
            self.downloads(),
            self.logs(),
        ] {
            std::fs::create_dir_all(&dir).at("create directory", &dir)?;
        }
        Ok(())
    }
}

/// Lowercase ASCII slug for folder names: "Elden Ring: Nightreign" → "elden-ring-nightreign".
pub fn slugify(input: &str) -> String {
    let mut slug = String::with_capacity(input.len());
    let mut last_dash = true;
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch.to_ascii_lowercase());
            last_dash = false;
        } else if !last_dash {
            slug.push('-');
            last_dash = true;
        }
    }
    while slug.ends_with('-') {
        slug.pop();
    }
    if slug.is_empty() {
        "untitled".into()
    } else {
        slug.chars().take(48).collect()
    }
}

pub fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs() {
        assert_eq!(slugify("Elden Ring: Nightreign"), "elden-ring-nightreign");
        assert_eq!(slugify("  --Hades II--  "), "hades-ii");
        assert_eq!(slugify("名前"), "untitled");
    }

    #[test]
    fn ensure_creates_layout() {
        let tmp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(tmp.path().join("Aether Launcher"));
        paths.ensure().unwrap();
        paths.ensure().unwrap(); // idempotent
        for dir in [
            paths.runtimes(),
            paths.bottles(),
            paths.components(),
            paths.artwork(),
            paths.downloads(),
            paths.logs(),
        ] {
            assert!(dir.is_dir(), "{} missing", dir.display());
        }
    }
}
