//! File-system operations that must preserve symlinks, permissions and bundle structure
//! (Wine runtimes and `D3DMetal.framework` are full of symlinks). Done with the system tools.

use std::path::{Path, PathBuf};
use std::process::Command;

use walkdir::WalkDir;

use crate::error::{EngineError, IoContext, Result};

fn run(mut cmd: Command, label: &str) -> Result<()> {
    let output = cmd
        .output()
        .map_err(|e| EngineError::io(format!("spawn {label}"), e))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(EngineError::Command {
            command: label.to_owned(),
            status: output.status.code().unwrap_or(-1),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        })
    }
}

/// Copies directory `src` to a **new** path `dst`.
/// macOS: `cp -c` uses APFS `clonefile(2)`, an instant, zero-space copy-on-write clone of a
/// whole Wine runtime or prefix. Falls back to a regular copy on other file systems.
pub fn clone_tree(src: &Path, dst: &Path) -> Result<()> {
    if dst.exists() {
        return Err(EngineError::Invalid(format!(
            "{} already exists",
            dst.display()
        )));
    }
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent).at("create directory", parent)?;
    }
    if cfg!(target_os = "macos") {
        let mut clone = Command::new("/bin/cp");
        clone.arg("-cR").arg(src).arg(dst);
        if run(clone, "cp -cR").is_ok() {
            return Ok(());
        }
        let _ = std::fs::remove_dir_all(dst); // partial clone; retry as a plain copy
    }
    let mut copy = Command::new("cp");
    copy.arg("-a").arg(src).arg(dst);
    run(copy, "cp -a")
}

/// Merges the *contents* of `src` into `dst`, overwriting files and keeping everything else.
/// Used to layer GPTK / DXMT files onto a runtime. macOS: `ditto`, which preserves symlinks,
/// resource forks and framework layout.
pub fn merge_tree(src: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst).at("create directory", dst)?;
    if cfg!(target_os = "macos") {
        let mut ditto = Command::new("/usr/bin/ditto");
        ditto.arg(src).arg(dst);
        return run(ditto, "ditto");
    }
    let mut copy = Command::new("cp");
    copy.arg("-a").arg(format!("{}/.", src.display())).arg(dst);
    run(copy, "cp -a")
}

/// Extracts a `.tar.xz` / `.tar.gz` / `.tar.zst` with the system `tar` (bsdtar on macOS detects
/// the compression itself).
pub fn extract_archive(archive: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst).at("create directory", dst)?;
    let mut tar = Command::new("tar");
    tar.arg("-xf").arg(archive).arg("-C").arg(dst);
    run(tar, "tar -xf")
}

/// First directory under `root` (breadth-first, up to `max_depth`) for which `predicate` is true.
pub fn find_dir(
    root: &Path,
    max_depth: usize,
    predicate: impl Fn(&Path) -> bool,
) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = WalkDir::new(root)
        .max_depth(max_depth)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_dir())
        .map(|e| e.into_path())
        .filter(|p| predicate(p))
        .collect();
    // Shallowest match wins, then lexical order for determinism.
    candidates.sort_by(|a, b| {
        a.components()
            .count()
            .cmp(&b.components().count())
            .then_with(|| a.cmp(b))
    });
    candidates.into_iter().next()
}

/// Recursively sums file sizes (for showing bottle and runtime disk usage).
pub fn dir_size(root: &Path) -> u64 {
    WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter_map(|e| e.metadata().ok())
        .map(|m| m.len())
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn clone_and_merge_preserve_tree_and_symlinks() {
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("src");
        fs::create_dir_all(src.join("lib/wine")).unwrap();
        fs::write(src.join("lib/wine/a.dll"), b"original").unwrap();
        std::os::unix::fs::symlink("wine/a.dll", src.join("lib/link.dll")).unwrap();

        let dst = tmp.path().join("dst");
        clone_tree(&src, &dst).unwrap();
        assert_eq!(fs::read(dst.join("lib/wine/a.dll")).unwrap(), b"original");
        assert!(fs::symlink_metadata(dst.join("lib/link.dll"))
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(clone_tree(&src, &dst).is_err(), "must refuse to clobber");

        let overlay = tmp.path().join("overlay");
        fs::create_dir_all(overlay.join("wine")).unwrap();
        fs::write(overlay.join("wine/a.dll"), b"patched").unwrap();
        fs::write(overlay.join("wine/new.dll"), b"new").unwrap();
        merge_tree(&overlay, &dst.join("lib")).unwrap();
        assert_eq!(fs::read(dst.join("lib/wine/a.dll")).unwrap(), b"patched");
        assert_eq!(fs::read(dst.join("lib/wine/new.dll")).unwrap(), b"new");
        assert_eq!(
            fs::read(src.join("lib/wine/a.dll")).unwrap(),
            b"original",
            "source untouched"
        );
    }

    #[test]
    fn find_dir_prefers_shallowest() {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir_all(tmp.path().join("a/b/target")).unwrap();
        fs::create_dir_all(tmp.path().join("z/target")).unwrap();
        let found = find_dir(tmp.path(), 5, |p| {
            p.file_name().is_some_and(|n| n == "target")
        })
        .unwrap();
        assert!(found.ends_with("z/target"));
    }
}
