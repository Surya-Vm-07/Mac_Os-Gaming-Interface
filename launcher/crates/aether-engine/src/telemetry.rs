//! Live system stats for the telemetry bar: unified memory, CPU, GPU and Wine process count.

use std::path::{Path, PathBuf};

use serde::Serialize;
use sysinfo::{MemoryRefreshKind, ProcessRefreshKind, ProcessesToUpdate, System};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetrySnapshot {
    pub memory_used_bytes: u64,
    pub memory_total_bytes: u64,
    pub swap_used_bytes: u64,
    /// 0–100 across all cores since the previous sample.
    pub cpu_percent: f32,
    /// 0–100 from the Apple GPU driver; `None` where unavailable.
    pub gpu_percent: Option<f32>,
    pub wine_processes: usize,
    /// Resident memory of all Wine processes combined.
    pub wine_memory_bytes: u64,
}

pub struct Telemetry {
    system: System,
    runtimes_dir: PathBuf,
}

impl Telemetry {
    pub fn new(runtimes_dir: impl Into<PathBuf>) -> Self {
        let mut system = System::new();
        system.refresh_cpu_usage(); // baseline so the first real sample has a delta
        Self {
            system,
            runtimes_dir: runtimes_dir.into(),
        }
    }

    /// Call about once per second; CPU usage is measured between calls.
    pub fn sample(&mut self) -> TelemetrySnapshot {
        self.system
            .refresh_memory_specifics(MemoryRefreshKind::nothing().with_ram().with_swap());
        self.system.refresh_cpu_usage();
        self.system.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing()
                .with_memory()
                .with_exe(sysinfo::UpdateKind::OnlyIfNotSet),
        );

        let (wine_processes, wine_memory_bytes) = self
            .system
            .processes()
            .values()
            .filter(|p| {
                is_wine_process(
                    p.name().to_string_lossy().as_ref(),
                    p.exe(),
                    &self.runtimes_dir,
                )
            })
            .fold((0usize, 0u64), |(n, mem), p| (n + 1, mem + p.memory()));

        TelemetrySnapshot {
            memory_used_bytes: self.system.used_memory(),
            memory_total_bytes: self.system.total_memory(),
            swap_used_bytes: self.system.used_swap(),
            cpu_percent: self.system.global_cpu_usage(),
            gpu_percent: gpu_utilization(),
            wine_processes,
            wine_memory_bytes,
        }
    }
}

/// Processes launched from one of our runtimes, or named like Wine's own binaries.
fn is_wine_process(name: &str, exe: Option<&Path>, runtimes_dir: &Path) -> bool {
    if exe.is_some_and(|e| e.starts_with(runtimes_dir)) {
        return true;
    }
    let name = name.to_ascii_lowercase();
    name == "wineserver"
        || name.starts_with("wine64")
        || name == "wine"
        || name.starts_with("wine-preloader")
        || name.ends_with(".exe")
}

/// Reads `Device Utilization %` from the AGXAccelerator IORegistry entry via `ioreg`.
fn gpu_utilization() -> Option<f32> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let output = std::process::Command::new("/usr/sbin/ioreg")
        .args(["-r", "-d", "1", "-w", "0", "-c", "AGXAccelerator"])
        .output()
        .ok()?;
    parse_gpu_utilization(&String::from_utf8_lossy(&output.stdout))
}

fn parse_gpu_utilization(ioreg: &str) -> Option<f32> {
    let key = "\"Device Utilization %\"=";
    let start = ioreg.find(key)? + key.len();
    let digits: String = ioreg[start..]
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse::<f32>().ok().map(|v| v.clamp(0.0, 100.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ioreg_performance_statistics() {
        let sample = r#"| "PerformanceStatistics" = {"In use system memory"=123,"Device Utilization %"=37,"Renderer Utilization %"=35}"#;
        assert_eq!(parse_gpu_utilization(sample), Some(37.0));
        assert_eq!(parse_gpu_utilization("nothing"), None);
    }

    #[test]
    fn identifies_wine_processes() {
        let runtimes = Path::new("/rt");
        assert!(is_wine_process(
            "anything",
            Some(Path::new("/rt/wine-10/bin/wine")),
            runtimes
        ));
        assert!(is_wine_process("wineserver", None, runtimes));
        assert!(is_wine_process("EldenRing.exe", None, runtimes));
        assert!(!is_wine_process(
            "Safari",
            Some(Path::new("/Applications/Safari.app")),
            runtimes
        ));
    }

    #[test]
    fn live_sample_is_sane() {
        let mut t = Telemetry::new("/nonexistent");
        std::thread::sleep(std::time::Duration::from_millis(250));
        let s = t.sample();
        assert!(s.memory_total_bytes > 0 && s.memory_used_bytes <= s.memory_total_bytes);
        assert!((0.0..=100.0).contains(&s.cpu_percent));
    }
}
