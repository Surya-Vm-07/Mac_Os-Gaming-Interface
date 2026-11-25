//! Spawns Windows games through Wine, streams their output, tracks session lifetime and kills
//! hung sessions cleanly.
//!
//! Lifecycle: `Started` → `Log`… → `Exited` (the launched process) → `Idle` (`wineserver -w`
//! returned, so every process in the bottle is gone). Launchers that spawn the real game and exit
//! therefore do not end the session early.
//!
//! Kill: SIGTERM to the process group → grace period → `wineserver -k` (all clients in the prefix)
//! → SIGKILL to the group.

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncRead, BufReader};
use tokio::process::Command;

use crate::error::{EngineError, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LogStream {
    Stdout,
    Stderr,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "type")]
pub enum RunEvent {
    #[serde(rename_all = "camelCase")]
    Started { session_id: String, pid: u32 },
    #[serde(rename_all = "camelCase")]
    Log { stream: LogStream, line: String },
    /// The launched Wine process ended. `signal` is set when it was killed.
    #[serde(rename_all = "camelCase")]
    Exited {
        code: Option<i32>,
        signal: Option<i32>,
    },
    /// The bottle is idle: every Wine process in the prefix has exited. Always the last event.
    #[serde(rename_all = "camelCase")]
    Idle { duration_secs: u64 },
}

pub type EventSink = Arc<dyn Fn(RunEvent) + Send + Sync + 'static>;

/// Fully resolved command line and environment for one launch.
#[derive(Debug, Clone)]
pub struct LaunchSpec {
    pub game_id: String,
    pub wine: PathBuf,
    pub wineserver: PathBuf,
    pub prefix: PathBuf,
    pub program: PathBuf,
    pub args: Vec<String>,
    pub working_dir: PathBuf,
    pub env: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub session_id: String,
    pub game_id: String,
    pub pid: u32,
    pub prefix: PathBuf,
    pub started_unix: i64,
    pub killing: bool,
}

struct SessionHandle {
    info: SessionInfo,
    wineserver: PathBuf,
}

/// Longest line forwarded to the UI (Wine's trace output can be enormous).
const MAX_LINE: usize = 8 * 1024;

#[derive(Clone, Default)]
pub struct Runner {
    sessions: Arc<Mutex<HashMap<String, SessionHandle>>>,
}

impl Runner {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn sessions(&self) -> Vec<SessionInfo> {
        let sessions = self.sessions.lock().expect("sessions lock");
        let mut list: Vec<SessionInfo> = sessions.values().map(|h| h.info.clone()).collect();
        list.sort_by_key(|s| s.started_unix);
        list
    }

    pub fn is_game_running(&self, game_id: &str) -> bool {
        self.sessions
            .lock()
            .expect("sessions lock")
            .values()
            .any(|h| h.info.game_id == game_id)
    }

    /// Spawns the game. Returns once the process is running; events continue asynchronously.
    pub async fn launch(&self, spec: LaunchSpec, sink: EventSink) -> Result<SessionInfo> {
        if self.is_game_running(&spec.game_id) {
            return Err(EngineError::Invalid("this game is already running".into()));
        }
        if !spec.wine.is_file() {
            return Err(EngineError::Missing(format!(
                "Wine binary {}",
                spec.wine.display()
            )));
        }

        let mut command = Command::new(&spec.wine);
        command
            .arg(&spec.program)
            .args(&spec.args)
            .env_clear()
            .envs(base_process_env())
            .envs(&spec.env)
            .current_dir(&spec.working_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // Own process group: one signal reaches Wine and everything it forks.
            .process_group(0)
            .kill_on_drop(false);

        let mut child = command
            .spawn()
            .map_err(|e| EngineError::io(format!("spawn {}", spec.wine.display()), e))?;
        let pid = child
            .id()
            .ok_or_else(|| EngineError::Invalid("game exited before it could be tracked".into()))?;
        let session_id = uuid::Uuid::new_v4().to_string();
        let info = SessionInfo {
            session_id: session_id.clone(),
            game_id: spec.game_id.clone(),
            pid,
            prefix: spec.prefix.clone(),
            started_unix: crate::paths::now_unix(),
            killing: false,
        };
        self.sessions.lock().expect("sessions lock").insert(
            session_id.clone(),
            SessionHandle {
                info: info.clone(),
                wineserver: spec.wineserver.clone(),
            },
        );

        sink(RunEvent::Started {
            session_id: session_id.clone(),
            pid,
        });

        if let Some(out) = child.stdout.take() {
            tokio::spawn(pump(out, LogStream::Stdout, sink.clone()));
        }
        if let Some(err) = child.stderr.take() {
            tokio::spawn(pump(err, LogStream::Stderr, sink.clone()));
        }

        let sessions = self.sessions.clone();
        let started = Instant::now();
        tokio::spawn(async move {
            let status = child.wait().await;
            let (code, signal) = match status {
                Ok(status) => {
                    use std::os::unix::process::ExitStatusExt;
                    (status.code(), status.signal())
                }
                Err(_) => (None, None),
            };
            sink(RunEvent::Exited { code, signal });

            // Wait for every process in the prefix (child launchers, the real game, services).
            let _ = wineserver(&spec.wineserver, &spec.prefix, &["-w"]).await;

            sessions.lock().expect("sessions lock").remove(&session_id);
            sink(RunEvent::Idle {
                duration_secs: started.elapsed().as_secs(),
            });
        });

        Ok(info)
    }

    /// Stops a session and everything in its bottle.
    pub async fn kill(&self, session_id: &str, grace: Duration) -> Result<()> {
        let (pid, prefix, wineserver_bin) = {
            let mut sessions = self.sessions.lock().expect("sessions lock");
            let handle = sessions
                .get_mut(session_id)
                .ok_or_else(|| EngineError::NotFound(format!("session `{session_id}`")))?;
            handle.info.killing = true;
            (
                handle.info.pid,
                handle.info.prefix.clone(),
                handle.wineserver.clone(),
            )
        };
        let pgid = pid as libc::pid_t;

        // 1. Polite: lets games flush saves and Wine tear down windows.
        signal_group(pgid, libc::SIGTERM);
        let deadline = Instant::now() + grace;
        while Instant::now() < deadline && process_alive(pgid) {
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        // 2. Every Wine client in this prefix, including re-parented children outside our group.
        let _ = wineserver(&wineserver_bin, &prefix, &["-k"]).await;
        // 3. Last resort.
        if process_alive(pgid) {
            signal_group(pgid, libc::SIGKILL);
        }
        Ok(())
    }

    /// Kills whatever is running in a prefix, whether or not this launcher started it
    /// (e.g. a hung `wineserver` left over from a crash). Used by the bottle manager.
    pub async fn kill_prefix(
        wineserver_bin: &std::path::Path,
        prefix: &std::path::Path,
    ) -> Result<()> {
        wineserver(wineserver_bin, prefix, &["-k"]).await
    }
}

/// Minimal inherited environment: the parent app's own variables (Tauri/WebKit internals,
/// DYLD paths) must not leak into Wine.
pub(crate) fn base_process_env() -> Vec<(String, String)> {
    [
        "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL",
    ]
    .iter()
    .filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), v)))
    .chain(std::iter::once((
        "PATH".to_string(),
        "/usr/bin:/bin:/usr/sbin:/sbin".to_string(),
    )))
    .collect()
}

async fn pump<R: AsyncRead + Unpin>(reader: R, stream: LogStream, sink: EventSink) {
    let mut reader = BufReader::new(reader);
    let mut buf = Vec::with_capacity(512);
    loop {
        buf.clear();
        match reader.read_until(b'\n', &mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                while matches!(buf.last(), Some(b'\n' | b'\r')) {
                    buf.pop();
                }
                buf.truncate(MAX_LINE);
                sink(RunEvent::Log {
                    stream,
                    line: String::from_utf8_lossy(&buf).into_owned(),
                });
            }
        }
    }
}

async fn wineserver(bin: &std::path::Path, prefix: &std::path::Path, args: &[&str]) -> Result<()> {
    if !bin.is_file() {
        return Err(EngineError::Missing(format!(
            "wineserver {}",
            bin.display()
        )));
    }
    let status = Command::new(bin)
        .args(args)
        .env_clear()
        .envs(base_process_env())
        .env("WINEPREFIX", prefix)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .map_err(|e| EngineError::io("run wineserver", e))?;
    if status.success() {
        Ok(())
    } else {
        Err(EngineError::Command {
            command: format!("wineserver {}", args.join(" ")),
            status: status.code().unwrap_or(-1),
            stderr: String::new(),
        })
    }
}

fn signal_group(pgid: libc::pid_t, signal: libc::c_int) {
    // Negative pid = whole process group. Errors (already gone) are expected and ignored.
    unsafe {
        libc::kill(-pgid, signal);
    }
}

fn process_alive(pgid: libc::pid_t) -> bool {
    // Signal 0 checks for existence. Any member of the group still alive counts.
    unsafe { libc::kill(-pgid, 0) == 0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn script(dir: &std::path::Path, name: &str, body: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, body).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn spec(dir: &std::path::Path, wine_body: &str) -> LaunchSpec {
        LaunchSpec {
            game_id: "g1".into(),
            wine: script(dir, "wine", wine_body),
            wineserver: script(dir, "wineserver", "#!/bin/sh\nexit 0\n"),
            prefix: dir.join("prefix"),
            program: PathBuf::from("C:\\game.exe"),
            args: vec!["-dx12".into(), "two words".into()],
            working_dir: dir.to_path_buf(),
            env: BTreeMap::from([("WINEMSYNC".into(), "1".into())]),
        }
    }

    fn collector() -> (
        EventSink,
        Arc<Mutex<Vec<RunEvent>>>,
        tokio::sync::mpsc::UnboundedReceiver<()>,
    ) {
        let events = Arc::new(Mutex::new(Vec::new()));
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let sink_events = events.clone();
        let sink: EventSink = Arc::new(move |e| {
            let idle = matches!(e, RunEvent::Idle { .. });
            sink_events.lock().unwrap().push(e);
            if idle {
                let _ = tx.send(());
            }
        });
        (sink, events, rx)
    }

    #[tokio::test]
    async fn streams_logs_env_and_exit_code() {
        let tmp = tempfile::tempdir().unwrap();
        let body = "#!/bin/sh\necho \"exe=$1 arg2=$3 msync=$WINEMSYNC prefix-leak=${DYLD_LIBRARY_PATH:-none}\"\necho oops >&2\nprintf 'no newline'\nexit 7\n";
        let runner = Runner::new();
        let (sink, events, mut idle) = collector();
        std::env::set_var("DYLD_LIBRARY_PATH", "/should/not/leak");
        let info = runner.launch(spec(tmp.path(), body), sink).await.unwrap();
        assert!(runner.is_game_running("g1"));
        tokio::time::timeout(Duration::from_secs(10), idle.recv())
            .await
            .unwrap();

        let events = events.lock().unwrap().clone();
        assert_eq!(
            events.first(),
            Some(&RunEvent::Started {
                session_id: info.session_id.clone(),
                pid: info.pid
            })
        );
        assert!(events.contains(&RunEvent::Log {
            stream: LogStream::Stdout,
            line: "exe=C:\\game.exe arg2=two words msync=1 prefix-leak=none".into()
        }));
        assert!(events.contains(&RunEvent::Log {
            stream: LogStream::Stderr,
            line: "oops".into()
        }));
        assert!(events.contains(&RunEvent::Log {
            stream: LogStream::Stdout,
            line: "no newline".into()
        }));
        assert!(events.contains(&RunEvent::Exited {
            code: Some(7),
            signal: None
        }));
        assert!(matches!(events.last(), Some(RunEvent::Idle { .. })));
        assert!(!runner.is_game_running("g1"));
    }

    #[tokio::test]
    async fn kill_terminates_hung_game_and_its_children() {
        let tmp = tempfile::tempdir().unwrap();
        // A "game" that ignores nothing and forks a child, the shape of a launcher plus game.
        let body = "#!/bin/sh\nsleep 300 &\necho started\nwait\n";
        let runner = Runner::new();
        let (sink, events, mut idle) = collector();
        let info = runner.launch(spec(tmp.path(), body), sink).await.unwrap();
        assert!(
            runner
                .launch(spec(tmp.path(), body), Arc::new(|_| {}))
                .await
                .is_err(),
            "one session per game"
        );

        tokio::time::sleep(Duration::from_millis(300)).await;
        runner
            .kill(&info.session_id, Duration::from_secs(2))
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(10), idle.recv())
            .await
            .unwrap();

        let events = events.lock().unwrap().clone();
        assert!(
            events.contains(&RunEvent::Exited {
                code: None,
                signal: Some(libc::SIGTERM)
            }),
            "{events:?}"
        );
        assert!(
            !process_alive(info.pid as libc::pid_t),
            "process group fully gone"
        );
        assert!(runner.sessions().is_empty());
    }

    #[tokio::test]
    async fn missing_wine_is_actionable() {
        let tmp = tempfile::tempdir().unwrap();
        let mut s = spec(tmp.path(), "#!/bin/sh\n");
        s.wine = tmp.path().join("nope/wine");
        let err = Runner::new().launch(s, Arc::new(|_| {})).await.unwrap_err();
        assert!(matches!(err, EngineError::Missing(_)));
    }
}
