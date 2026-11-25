//! Free component downloads from GitHub releases. Assets are chosen by regex against the latest
//! release, so new upstream versions are picked up without code changes.
//!
//! Files downloaded by this client carry no `com.apple.quarantine` attribute (only browsers and
//! other LSQuarantine-aware apps add it), so Gatekeeper never prompts for the Wine binaries.

use std::path::{Path, PathBuf};

use regex::Regex;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;

use crate::error::{EngineError, IoContext, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseSource {
    pub id: &'static str,
    pub label: &'static str,
    /// `owner/repo` on GitHub.
    pub repo: &'static str,
    /// Regex matched against asset file names.
    pub asset_pattern: &'static str,
}

/// Gcenx's macOS Wine Staging builds (x86_64; run under Rosetta 2).
pub const WINE_STAGING: ReleaseSource = ReleaseSource {
    id: "wine-staging",
    label: "Wine Staging (Gcenx macOS build)",
    repo: "Gcenx/macOS_Wine_builds",
    asset_pattern: r"^wine-staging-[\d.]+-osx64\.tar\.xz$",
};

/// DXMT: Metal-based D3D10/11 implementation for Wine.
pub const DXMT: ReleaseSource = ReleaseSource {
    id: "dxmt",
    label: "DXMT",
    repo: "3Shain/dxmt",
    asset_pattern: r"^dxmt-.*\.tar\.gz$",
};

/// DXVK patched for macOS / MoltenVK.
pub const DXVK_MACOS: ReleaseSource = ReleaseSource {
    id: "dxvk",
    label: "DXVK (macOS)",
    repo: "Gcenx/DXVK-macOS",
    asset_pattern: r"^dxvk-macOS-.*\.tar\.gz$",
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedAsset {
    pub tag: String,
    pub name: String,
    pub url: String,
    pub size: u64,
}

impl ResolvedAsset {
    /// "wine-staging-10.4-osx64.tar.xz" with tag "v10.4" → "10.4".
    pub fn version(&self) -> String {
        self.tag.trim_start_matches(['v', 'V']).to_owned()
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase", tag = "phase")]
pub enum DownloadProgress {
    Resolving,
    Downloading { received: u64, total: Option<u64> },
    Extracting,
    Installing,
    Done,
}

#[derive(Deserialize)]
struct GhRelease {
    tag_name: String,
    assets: Vec<GhAsset>,
}

#[derive(Deserialize)]
struct GhAsset {
    name: String,
    browser_download_url: String,
    size: u64,
}

/// HTTP client with a generic product user agent (GitHub's API rejects requests without one).
pub fn http_client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .user_agent(concat!("AetherLauncher/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(std::time::Duration::from_secs(15))
        .build()?)
}

/// Picks the asset matching `source.asset_pattern` from a release JSON payload.
pub fn select_asset(source: &ReleaseSource, release_json: &[u8]) -> Result<ResolvedAsset> {
    let release: GhRelease = serde_json::from_slice(release_json)?;
    let pattern =
        Regex::new(source.asset_pattern).map_err(|e| EngineError::Invalid(e.to_string()))?;
    release
        .assets
        .into_iter()
        .find(|a| pattern.is_match(&a.name))
        .map(|a| ResolvedAsset {
            tag: release.tag_name.clone(),
            name: a.name,
            url: a.browser_download_url,
            size: a.size,
        })
        .ok_or_else(|| {
            EngineError::NotFound(format!(
                "{} asset in latest {} release",
                source.label, source.repo
            ))
        })
}

pub async fn resolve_latest(
    client: &reqwest::Client,
    source: &ReleaseSource,
) -> Result<ResolvedAsset> {
    let url = format!(
        "https://api.github.com/repos/{}/releases/latest",
        source.repo
    );
    let response = client
        .get(url)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await?
        .error_for_status()?;
    select_asset(source, &response.bytes().await?)
}

/// Streams `url` to `dest` (via `dest.part`, renamed on success), reporting progress.
pub async fn download_to(
    client: &reqwest::Client,
    url: &str,
    dest: &Path,
    mut progress: impl FnMut(DownloadProgress),
) -> Result<PathBuf> {
    let partial = dest.with_extension("part");
    let mut response = client.get(url).send().await?.error_for_status()?;
    let total = response.content_length();
    let mut file = tokio::fs::File::create(&partial)
        .await
        .at("create", &partial)?;
    let mut received: u64 = 0;
    let mut last_report = 0u64;
    progress(DownloadProgress::Downloading { received, total });

    while let Some(chunk) = response.chunk().await? {
        file.write_all(&chunk).await.at("write", &partial)?;
        received += chunk.len() as u64;
        // Report every 512 KiB, so a 200 MB runtime is not ~50k IPC messages.
        if received - last_report >= 512 * 1024 {
            last_report = received;
            progress(DownloadProgress::Downloading { received, total });
        }
    }
    file.flush().await.at("flush", &partial)?;
    drop(file);
    if let Some(expected) = total {
        if received != expected {
            let _ = tokio::fs::remove_file(&partial).await;
            return Err(EngineError::Invalid(format!(
                "download truncated: {received} of {expected} bytes"
            )));
        }
    }
    tokio::fs::rename(&partial, dest).await.at("rename", dest)?;
    progress(DownloadProgress::Downloading { received, total });
    Ok(dest.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_matching_assets() {
        let json = br#"{
            "tag_name": "v10.4",
            "assets": [
                {"name": "wine-devel-10.4-osx64.tar.xz", "browser_download_url": "https://x/devel", "size": 1},
                {"name": "wine-staging-10.4-osx64.tar.xz", "browser_download_url": "https://x/staging", "size": 2},
                {"name": "wine-staging-10.4-osx64.tar.xz.sha256", "browser_download_url": "https://x/sha", "size": 3}
            ]
        }"#;
        let asset = select_asset(&WINE_STAGING, json).unwrap();
        assert_eq!(asset.url, "https://x/staging");
        assert_eq!(asset.version(), "10.4");

        let none = br#"{"tag_name":"v1","assets":[{"name":"readme.txt","browser_download_url":"u","size":1}]}"#;
        assert!(matches!(
            select_asset(&WINE_STAGING, none),
            Err(EngineError::NotFound(_))
        ));
    }

    #[test]
    fn patterns_compile_and_match_known_names() {
        assert!(Regex::new(DXMT.asset_pattern)
            .unwrap()
            .is_match("dxmt-v0.60-builtin.tar.gz"));
        assert!(Regex::new(DXVK_MACOS.asset_pattern)
            .unwrap()
            .is_match("dxvk-macOS-async-v1.10.3-20230507.tar.gz"));
    }
}
