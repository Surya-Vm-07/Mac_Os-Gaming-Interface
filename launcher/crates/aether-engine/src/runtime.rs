//! Wine runtimes: free Gcenx builds extracted under `runtimes/`, plus *derived* runtimes that layer
//! one graphics stack on top (an APFS clone of the base plus overlay files).
//!
//! Why derive instead of patching one runtime: D3DMetal and DXMT both ship their own
//! `d3d11.dll` / `dxgi.dll` builtins. One runtime per stack keeps per-game backend switching
//! conflict-free, and an APFS clone costs almost no disk.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::env::GraphicsBackend;
use crate::error::{EngineError, IoContext, Result};
use crate::fsutil;
use crate::paths::{now_unix, slugify, AppPaths};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeFlavor {
    /// Plain Wine: WineD3D and DXVK games run here.
    Base,
    /// Base + Apple GPTK `D3DMetal.framework` and its builtin DLLs.
    D3dmetal,
    /// Base + DXMT unix/PE modules.
    Dxmt,
}

impl RuntimeFlavor {
    /// The runtime flavor a backend needs.
    pub fn for_backend(backend: GraphicsBackend) -> Self {
        match backend {
            GraphicsBackend::D3dmetal => Self::D3dmetal,
            GraphicsBackend::Dxmt => Self::Dxmt,
            GraphicsBackend::Dxvk | GraphicsBackend::Wined3d => Self::Base,
        }
    }

    fn suffix(self) -> &'static str {
        match self {
            Self::Base => "",
            Self::D3dmetal => "d3dmetal",
            Self::Dxmt => "dxmt",
        }
    }
}

/// Persisted as `runtimes/<id>/runtime.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeManifest {
    pub id: String,
    pub name: String,
    pub version: String,
    pub flavor: RuntimeFlavor,
    /// For derived runtimes: the base runtime id.
    pub base_id: Option<String>,
    /// Directory containing `bin/wine`, relative to the runtime directory.
    pub wine_root: PathBuf,
    pub installed_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Runtime {
    #[serde(flatten)]
    pub manifest: RuntimeManifest,
    pub dir: PathBuf,
}

impl Runtime {
    pub fn id(&self) -> &str {
        &self.manifest.id
    }

    pub fn wine_root(&self) -> PathBuf {
        self.dir.join(&self.manifest.wine_root)
    }

    /// Older builds ship `wine64`; new-WoW64 builds (Wine 9+) ship a single `wine`.
    pub fn wine_binary(&self) -> PathBuf {
        let bin = self.wine_root().join("bin");
        let wine64 = bin.join("wine64");
        if wine64.is_file() {
            wine64
        } else {
            bin.join("wine")
        }
    }

    pub fn wineserver(&self) -> PathBuf {
        self.wine_root().join("bin").join("wineserver")
    }

    pub fn lib_dir(&self) -> PathBuf {
        self.wine_root().join("lib")
    }
}

pub const MANIFEST_FILE: &str = "runtime.json";

#[derive(Debug, Clone)]
pub struct RuntimeStore {
    paths: AppPaths,
}

impl RuntimeStore {
    pub fn new(paths: AppPaths) -> Self {
        Self { paths }
    }

    pub fn list(&self) -> Result<Vec<Runtime>> {
        let dir = self.paths.runtimes();
        let mut runtimes = Vec::new();
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(runtimes),
            Err(e) => return Err(EngineError::io_at("read", &dir, e)),
        };
        for entry in entries.flatten() {
            let manifest_path = entry.path().join(MANIFEST_FILE);
            let Ok(bytes) = std::fs::read(&manifest_path) else {
                continue;
            };
            let Ok(manifest) = serde_json::from_slice::<RuntimeManifest>(&bytes) else {
                continue;
            };
            runtimes.push(Runtime {
                manifest,
                dir: entry.path(),
            });
        }
        runtimes.sort_by(|a, b| {
            b.manifest
                .installed_at
                .cmp(&a.manifest.installed_at)
                .then_with(|| a.id().cmp(b.id()))
        });
        Ok(runtimes)
    }

    pub fn get(&self, id: &str) -> Result<Runtime> {
        self.list()?
            .into_iter()
            .find(|r| r.id() == id)
            .ok_or_else(|| EngineError::NotFound(format!("runtime `{id}`")))
    }

    /// The runtime to launch a `backend` game with, given the bottle's base runtime.
    pub fn resolve(&self, base_id: &str, backend: GraphicsBackend) -> Result<Runtime> {
        let flavor = RuntimeFlavor::for_backend(backend);
        if flavor == RuntimeFlavor::Base {
            return self.get(base_id);
        }
        let derived_id = derived_id(base_id, flavor);
        self.get(&derived_id).map_err(|_| {
            EngineError::Missing(format!(
                "{} is not installed for runtime `{base_id}`. Open Bottles → Graphics stacks and install it.",
                backend.label()
            ))
        })
    }

    /// Finds the Wine root (the directory holding `bin/wine` or `bin/wine64`) inside an extracted archive.
    /// Gcenx app bundles nest it at `Wine Staging.app/Contents/Resources/wine`.
    pub fn find_wine_root(dir: &Path) -> Option<PathBuf> {
        fsutil::find_dir(dir, 6, |p| {
            let bin = p.join("bin");
            (bin.join("wine").is_file() || bin.join("wine64").is_file())
                && bin.join("wineserver").is_file()
        })
    }

    /// Registers an already-extracted Wine tree in `runtime_dir` as a base runtime.
    pub fn register_base(&self, runtime_dir: &Path, name: &str, version: &str) -> Result<Runtime> {
        let wine_root = Self::find_wine_root(runtime_dir).ok_or_else(|| {
            EngineError::Invalid(format!(
                "no Wine installation (bin/wine + bin/wineserver) in {}",
                runtime_dir.display()
            ))
        })?;
        let id = runtime_dir
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .ok_or_else(|| EngineError::Invalid("runtime directory has no name".into()))?;
        let manifest = RuntimeManifest {
            id,
            name: name.to_owned(),
            version: version.to_owned(),
            flavor: RuntimeFlavor::Base,
            base_id: None,
            wine_root: wine_root
                .strip_prefix(runtime_dir)
                .unwrap_or(&wine_root)
                .to_path_buf(),
            installed_at: now_unix(),
        };
        write_manifest(runtime_dir, &manifest)?;
        Ok(Runtime {
            manifest,
            dir: runtime_dir.to_path_buf(),
        })
    }

    /// Directory a new base runtime should be extracted into.
    pub fn new_base_dir(&self, name: &str, version: &str) -> PathBuf {
        self.paths
            .runtimes()
            .join(slugify(&format!("{name}-{version}")))
    }

    /// Clones `base` and runs `overlay` on the clone's Wine `lib` directory. Replaces any existing
    /// derived runtime of the same flavor. If the overlay fails, the half-built clone is removed.
    pub fn derive(
        &self,
        base: &Runtime,
        flavor: RuntimeFlavor,
        label: &str,
        overlay: impl FnOnce(&Path) -> Result<()>,
    ) -> Result<Runtime> {
        if base.manifest.flavor != RuntimeFlavor::Base {
            return Err(EngineError::Invalid(
                "derived runtimes must be built from a base runtime".into(),
            ));
        }
        if flavor == RuntimeFlavor::Base {
            return Err(EngineError::Invalid("cannot derive a base runtime".into()));
        }
        let id = derived_id(base.id(), flavor);
        let dir = self.paths.runtimes().join(&id);
        if dir.exists() {
            std::fs::remove_dir_all(&dir).at("remove old runtime", &dir)?;
        }
        fsutil::clone_tree(&base.dir, &dir)?;

        let mut manifest = base.manifest.clone();
        manifest.id = id;
        manifest.name = format!("{} + {label}", base.manifest.name);
        manifest.flavor = flavor;
        manifest.base_id = Some(base.id().to_owned());
        manifest.installed_at = now_unix();
        let runtime = Runtime {
            manifest,
            dir: dir.clone(),
        };

        if let Err(error) =
            overlay(&runtime.lib_dir()).and_then(|_| write_manifest(&dir, &runtime.manifest))
        {
            let _ = std::fs::remove_dir_all(&dir);
            return Err(error);
        }
        Ok(runtime)
    }

    /// Deletes a runtime and every runtime derived from it.
    pub fn delete(&self, id: &str) -> Result<()> {
        let all = self.list()?;
        let target = all
            .iter()
            .find(|r| r.id() == id)
            .ok_or_else(|| EngineError::NotFound(format!("runtime `{id}`")))?;
        for derived in all
            .iter()
            .filter(|r| r.manifest.base_id.as_deref() == Some(id))
        {
            std::fs::remove_dir_all(&derived.dir).at("remove runtime", &derived.dir)?;
        }
        std::fs::remove_dir_all(&target.dir).at("remove runtime", &target.dir)
    }
}

pub fn derived_id(base_id: &str, flavor: RuntimeFlavor) -> String {
    format!("{base_id}+{}", flavor.suffix())
}

fn write_manifest(dir: &Path, manifest: &RuntimeManifest) -> Result<()> {
    let path = dir.join(MANIFEST_FILE);
    std::fs::write(&path, serde_json::to_vec_pretty(manifest)?).at("write", &path)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    /// A fake Gcenx-style runtime: `<dir>/Wine Staging.app/Contents/Resources/wine/{bin,lib}`.
    pub fn fake_wine_tree(dir: &Path, wine_script: &str) {
        let root = dir.join("Wine Staging.app/Contents/Resources/wine");
        fs::create_dir_all(root.join("bin")).unwrap();
        fs::create_dir_all(root.join("lib/wine/x86_64-windows")).unwrap();
        fs::create_dir_all(root.join("lib/wine/x86_64-unix")).unwrap();
        fs::write(
            root.join("lib/wine/x86_64-windows/d3d11.dll"),
            b"wined3d d3d11",
        )
        .unwrap();
        for (name, body) in [("wine", wine_script), ("wineserver", "#!/bin/sh\nexit 0\n")] {
            let path = root.join("bin").join(name);
            fs::write(&path, body).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    #[test]
    fn register_derive_resolve_delete() {
        let tmp = tempfile::tempdir().unwrap();
        let paths = AppPaths::new(tmp.path());
        paths.ensure().unwrap();
        let store = RuntimeStore::new(paths.clone());

        let dir = store.new_base_dir("Wine Staging", "10.4");
        fake_wine_tree(&dir, "#!/bin/sh\nexit 0\n");
        let base = store.register_base(&dir, "Wine Staging", "10.4").unwrap();
        assert_eq!(base.id(), "wine-staging-10-4");
        assert!(base.wine_binary().ends_with("Resources/wine/bin/wine"));
        assert!(base.wineserver().is_file());

        // D3DMetal not installed yet → actionable error.
        let err = store
            .resolve(base.id(), GraphicsBackend::D3dmetal)
            .unwrap_err()
            .to_string();
        assert!(err.contains("D3DMetal is not installed"), "{err}");
        assert_eq!(
            store.resolve(base.id(), GraphicsBackend::Dxvk).unwrap(),
            base
        );

        let derived = store
            .derive(&base, RuntimeFlavor::D3dmetal, "D3DMetal", |lib| {
                fs::write(lib.join("wine/x86_64-windows/d3d11.dll"), b"d3dmetal d3d11").unwrap();
                Ok(())
            })
            .unwrap();
        assert_eq!(derived.id(), "wine-staging-10-4+d3dmetal");
        assert_eq!(
            store
                .resolve(base.id(), GraphicsBackend::D3dmetal)
                .unwrap()
                .id(),
            derived.id()
        );
        let base_dll = fs::read(base.lib_dir().join("wine/x86_64-windows/d3d11.dll")).unwrap();
        assert_eq!(
            base_dll, b"wined3d d3d11",
            "base runtime must stay untouched"
        );

        // Failed overlay leaves nothing behind.
        let failed = store.derive(&base, RuntimeFlavor::Dxmt, "DXMT", |_| {
            Err(EngineError::Invalid("boom".into()))
        });
        assert!(failed.is_err());
        assert!(!paths
            .runtimes()
            .join(derived_id(base.id(), RuntimeFlavor::Dxmt))
            .exists());

        assert_eq!(store.list().unwrap().len(), 2);
        store.delete(base.id()).unwrap();
        assert!(
            store.list().unwrap().is_empty(),
            "derived runtimes go with their base"
        );
    }
}
