//! Graphics stacks layered onto Wine:
//! - **D3DMetal**: imported from the user's own Game Porting Toolkit download (Apple's license
//!   does not permit redistributing it, so it is never downloaded here).
//! - **DXMT**: open source; downloaded and overlaid into a derived runtime.
//! - **DXVK**: open source; kept as a component and synced into each bottle as native DLLs.

use std::path::{Path, PathBuf};

use crate::download::{self, DownloadProgress, ReleaseSource};
use crate::error::{EngineError, IoContext, Result};
use crate::fsutil;
use crate::paths::AppPaths;
use crate::runtime::{Runtime, RuntimeFlavor, RuntimeStore};

/// Locates the GPTK `lib` directory (the one containing `external/D3DMetal.framework`) anywhere
/// under `search_root`: the mounted DMG, the extracted folder, or its `redist` directory.
pub fn find_gptk_lib(search_root: &Path) -> Option<PathBuf> {
    fsutil::find_dir(search_root, 6, |p| {
        p.file_name().is_some_and(|n| n == "lib")
            && p.join("external").join("D3DMetal.framework").is_dir()
    })
}

/// Common places a user has the toolkit: mounted DMG volumes, and GPTK-named folders directly
/// inside ~/Downloads. Only toolkit-named entries are searched, so a huge Downloads folder is
/// never walked.
pub fn detect_gptk_candidates(home: &Path) -> Vec<PathBuf> {
    let looks_like_gptk = |p: &Path| {
        let name = p
            .file_name()
            .map(|n| n.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        name.contains("game porting")
            || name.contains("evaluation environment")
            || name.contains("gptk")
    };
    let children = |dir: &Path| -> Vec<PathBuf> {
        std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .collect()
    };
    let mut roots: Vec<PathBuf> = children(Path::new("/Volumes"))
        .into_iter()
        .filter(|p| looks_like_gptk(p))
        .collect();
    roots.extend(
        children(&home.join("Downloads"))
            .into_iter()
            .filter(|p| p.is_dir() && looks_like_gptk(p)),
    );
    let mut found: Vec<PathBuf> = roots
        .into_iter()
        .filter_map(|r| find_gptk_lib(&r))
        .collect();
    found.dedup();
    found
}

/// Builds `<base>+d3dmetal`: a clone of `base` with the GPTK `lib` tree merged over its `lib`.
/// That brings in `external/D3DMetal.framework`, `external/libd3dshared.dylib`, and the D3DMetal
/// builtin `d3d11/d3d12/dxgi` PE modules under `wine/`.
pub fn install_d3dmetal(
    store: &RuntimeStore,
    base: &Runtime,
    gptk_source: &Path,
) -> Result<Runtime> {
    let gptk_lib = find_gptk_lib(gptk_source).ok_or_else(|| {
        EngineError::Invalid(format!(
            "no Game Porting Toolkit found in {} (expected …/lib/external/D3DMetal.framework). \
             Download the toolkit from developer.apple.com/games (free Apple Developer login) and pick its folder.",
            gptk_source.display()
        ))
    })?;
    store.derive(base, RuntimeFlavor::D3dmetal, "D3DMetal", |lib| {
        fsutil::merge_tree(&gptk_lib, lib)
    })
}

/// Builds `<base>+dxmt` from an extracted DXMT release. DXMT ships a `lib/wine`-shaped tree
/// (`x86_64-unix/winemetal.so`, `x86_64-windows/*.dll`, …); we find the directory that holds those
/// arch folders and merge it into the runtime's `lib/wine`.
pub fn install_dxmt_from_dir(
    store: &RuntimeStore,
    base: &Runtime,
    extracted: &Path,
) -> Result<Runtime> {
    let arch_root = fsutil::find_dir(extracted, 6, |p| {
        p.join("x86_64-windows").is_dir() || p.join("x86_64-unix").is_dir()
    })
    .ok_or_else(|| {
        EngineError::Invalid("DXMT archive has no x86_64-windows / x86_64-unix directory".into())
    })?;
    store.derive(base, RuntimeFlavor::Dxmt, "DXMT", |lib| {
        let wine_lib = lib.join("wine");
        if !wine_lib.is_dir() {
            return Err(EngineError::Invalid(format!(
                "runtime has no lib/wine directory ({})",
                wine_lib.display()
            )));
        }
        fsutil::merge_tree(&arch_root, &wine_lib)
    })
}

/// Downloads the latest release of `source` and extracts it into a fresh temp directory under
/// `downloads/`. Returns that directory; the caller deletes it when done.
pub async fn fetch_release(
    paths: &AppPaths,
    client: &reqwest::Client,
    source: &ReleaseSource,
    progress: &mut (dyn FnMut(DownloadProgress) + Send),
) -> Result<(download::ResolvedAsset, PathBuf)> {
    progress(DownloadProgress::Resolving);
    let asset = download::resolve_latest(client, source).await?;
    let archive = paths.downloads().join(&asset.name);
    download::download_to(client, &asset.url, &archive, &mut *progress).await?;

    progress(DownloadProgress::Extracting);
    let staging =
        paths
            .downloads()
            .join(format!("{}-{}", source.id, uuid::Uuid::new_v4().simple()));
    let extract = {
        let archive = archive.clone();
        let staging = staging.clone();
        tokio::task::spawn_blocking(move || fsutil::extract_archive(&archive, &staging))
    };
    let result = extract
        .await
        .map_err(|e| EngineError::Invalid(format!("extract task failed: {e}")))?;
    let _ = tokio::fs::remove_file(&archive).await;
    result?;
    Ok((asset, staging))
}

// MARK: - DXVK (per-bottle native DLLs)

pub const DXVK_DLLS: [&str; 4] = ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"];

/// Stores an extracted DXVK release as `components/dxvk/<version>/{x64,x32}`.
pub fn install_dxvk_from_dir(paths: &AppPaths, extracted: &Path, version: &str) -> Result<PathBuf> {
    let root = fsutil::find_dir(extracted, 5, |p| p.join("x64").join("d3d11.dll").is_file())
        .ok_or_else(|| EngineError::Invalid("DXVK archive has no x64/d3d11.dll".into()))?;
    let dest = paths.components().join("dxvk").join(version);
    if dest.exists() {
        std::fs::remove_dir_all(&dest).at("remove", &dest)?;
    }
    std::fs::create_dir_all(&dest).at("create directory", &dest)?;
    for arch in ["x64", "x32"] {
        let src = root.join(arch);
        if src.is_dir() {
            fsutil::merge_tree(&src, &dest.join(arch))?;
        }
    }
    Ok(dest)
}

/// Newest installed DXVK component, if any.
pub fn installed_dxvk(paths: &AppPaths) -> Option<PathBuf> {
    let dir = paths.components().join("dxvk");
    let mut versions: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    versions.sort();
    versions.pop()
}

/// Copies DXVK's DLLs into a bottle: 64-bit → `system32`, 32-bit → `syswow64`.
/// Skips files whose size already matches, so repeated launches cost nothing.
pub fn sync_dxvk_into_prefix(dxvk_dir: &Path, prefix: &Path) -> Result<()> {
    let windows = prefix.join("drive_c").join("windows");
    for (arch, target) in [("x64", "system32"), ("x32", "syswow64")] {
        let src_dir = dxvk_dir.join(arch);
        let dst_dir = windows.join(target);
        if !src_dir.is_dir() || !dst_dir.is_dir() {
            continue;
        }
        for dll in DXVK_DLLS {
            let src = src_dir.join(dll);
            if !src.is_file() {
                continue;
            }
            let dst = dst_dir.join(dll);
            let same = match (std::fs::metadata(&src), std::fs::metadata(&dst)) {
                (Ok(a), Ok(b)) => a.len() == b.len(),
                _ => false,
            };
            if !same {
                std::fs::copy(&src, &dst).at("copy", &dst)?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::tests::fake_wine_tree;
    use std::fs;

    fn setup() -> (tempfile::TempDir, AppPaths, RuntimeStore, Runtime) {
        let tmp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(tmp.path().join("app"));
        paths.ensure().unwrap();
        let store = RuntimeStore::new(paths.clone());
        let dir = store.new_base_dir("Wine", "10");
        fake_wine_tree(&dir, "#!/bin/sh\n");
        let base = store.register_base(&dir, "Wine", "10").unwrap();
        (tmp, paths, store, base)
    }

    #[test]
    fn d3dmetal_import_from_nested_gptk_folder() {
        let (tmp, _paths, store, base) = setup();
        let gptk = tmp.path().join("Game Porting Toolkit 2.1/redist/lib");
        fs::create_dir_all(gptk.join("external/D3DMetal.framework/Versions/A")).unwrap();
        fs::write(gptk.join("external/libd3dshared.dylib"), b"dylib").unwrap();
        fs::create_dir_all(gptk.join("wine/x86_64-windows")).unwrap();
        fs::write(
            gptk.join("wine/x86_64-windows/d3d12.dll"),
            b"d3dmetal d3d12",
        )
        .unwrap();

        let derived =
            install_d3dmetal(&store, &base, &tmp.path().join("Game Porting Toolkit 2.1")).unwrap();
        assert!(derived
            .lib_dir()
            .join("external/D3DMetal.framework")
            .is_dir());
        assert!(derived
            .lib_dir()
            .join("external/libd3dshared.dylib")
            .is_file());
        assert!(derived
            .lib_dir()
            .join("wine/x86_64-windows/d3d12.dll")
            .is_file());
        assert!(!base.lib_dir().join("external").exists());

        let err = install_d3dmetal(&store, &base, &tmp.path().join("nothing-here")).unwrap_err();
        assert!(err.to_string().contains("no Game Porting Toolkit"));
    }

    #[test]
    fn dxmt_overlay_into_lib_wine() {
        let (tmp, _paths, store, base) = setup();
        let extracted = tmp.path().join("dxmt-x/dxmt-v0.60");
        fs::create_dir_all(extracted.join("x86_64-unix")).unwrap();
        fs::write(extracted.join("x86_64-unix/winemetal.so"), b"so").unwrap();
        fs::create_dir_all(extracted.join("x86_64-windows")).unwrap();
        fs::write(extracted.join("x86_64-windows/d3d11.dll"), b"dxmt d3d11").unwrap();

        let derived = install_dxmt_from_dir(&store, &base, &tmp.path().join("dxmt-x")).unwrap();
        assert_eq!(
            fs::read(derived.lib_dir().join("wine/x86_64-windows/d3d11.dll")).unwrap(),
            b"dxmt d3d11"
        );
        assert!(derived
            .lib_dir()
            .join("wine/x86_64-unix/winemetal.so")
            .is_file());
    }

    #[test]
    fn dxvk_component_and_prefix_sync() {
        let (tmp, paths, _store, _base) = setup();
        let extracted = tmp.path().join("dxvk-x/dxvk-macOS-1.10.3");
        for arch in ["x64", "x32"] {
            fs::create_dir_all(extracted.join(arch)).unwrap();
            for dll in DXVK_DLLS {
                fs::write(extracted.join(arch).join(dll), format!("{arch}-{dll}")).unwrap();
            }
        }
        let component =
            install_dxvk_from_dir(&paths, &tmp.path().join("dxvk-x"), "1.10.3").unwrap();
        assert_eq!(installed_dxvk(&paths).unwrap(), component);

        let prefix = tmp.path().join("prefix");
        for d in ["system32", "syswow64"] {
            fs::create_dir_all(prefix.join("drive_c/windows").join(d)).unwrap();
        }
        sync_dxvk_into_prefix(&component, &prefix).unwrap();
        assert_eq!(
            fs::read_to_string(prefix.join("drive_c/windows/system32/d3d11.dll")).unwrap(),
            "x64-d3d11.dll"
        );
        assert_eq!(
            fs::read_to_string(prefix.join("drive_c/windows/syswow64/dxgi.dll")).unwrap(),
            "x32-dxgi.dll"
        );
    }
}
