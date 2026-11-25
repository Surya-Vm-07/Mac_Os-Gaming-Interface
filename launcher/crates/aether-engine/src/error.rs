use std::path::PathBuf;

/// Every fallible engine operation returns this. It serializes as a plain message string so
/// Tauri commands can return it straight to the UI.
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("{context}: {source}")]
    Io {
        context: String,
        #[source]
        source: std::io::Error,
    },
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("network error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("{0} not found")]
    NotFound(String),
    #[error("{0}")]
    Invalid(String),
    #[error("missing prerequisite: {0}")]
    Missing(String),
    #[error("`{command}` failed (exit {status}): {stderr}")]
    Command {
        command: String,
        status: i32,
        stderr: String,
    },
}

pub type Result<T> = std::result::Result<T, EngineError>;

impl EngineError {
    pub fn io(context: impl Into<String>, source: std::io::Error) -> Self {
        Self::Io {
            context: context.into(),
            source,
        }
    }

    pub fn io_at(action: &str, path: &std::path::Path, source: std::io::Error) -> Self {
        Self::Io {
            context: format!("{action} {}", path.display()),
            source,
        }
    }
}

impl serde::Serialize for EngineError {
    fn serialize<S: serde::Serializer>(
        &self,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_string())
    }
}

/// Small helper so `fs` calls carry the path in their error message.
pub(crate) trait IoContext<T> {
    fn at(self, action: &str, path: impl Into<PathBuf>) -> Result<T>;
}

impl<T> IoContext<T> for std::io::Result<T> {
    fn at(self, action: &str, path: impl Into<PathBuf>) -> Result<T> {
        let path = path.into();
        self.map_err(|e| EngineError::io_at(action, &path, e))
    }
}
