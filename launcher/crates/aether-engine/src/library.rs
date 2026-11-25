//! SQLite persistence for bottles and games (`library.sqlite3`).
//! Schema changes go through `PRAGMA user_version` migrations; WAL mode keeps reads fast while
//! a session writes playtime.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::{Deserialize, Serialize};

use crate::env::{GraphicsBackend, Preset};
use crate::error::{EngineError, Result};
use crate::paths::now_unix;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bottle {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    /// Base runtime id. The launch picks the flavor (D3DMetal / DXMT) per game.
    pub runtime_id: String,
    pub windows_version: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GameSource {
    Local,
    Steam,
    Epic,
    Gog,
}

impl GameSource {
    fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Steam => "steam",
            Self::Epic => "epic",
            Self::Gog => "gog",
        }
    }

    fn parse(s: &str) -> Self {
        match s {
            "steam" => Self::Steam,
            "epic" => Self::Epic,
            "gog" => Self::Gog,
            _ => Self::Local,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Game {
    pub id: String,
    pub title: String,
    pub exe_path: PathBuf,
    /// Defaults to the exe's folder when `None`.
    pub working_dir: Option<PathBuf>,
    pub bottle_id: Option<String>,
    pub preset: Preset,
    /// Used when `preset` is `Custom`.
    pub backend: GraphicsBackend,
    pub metal_hud: bool,
    pub launch_args: Vec<String>,
    pub env_overrides: BTreeMap<String, String>,
    pub dxmt_config: Option<String>,
    pub cover_path: Option<PathBuf>,
    pub hero_path: Option<PathBuf>,
    pub favorite: bool,
    pub source: GameSource,
    /// Store id: Epic app name, Steam app id, GOG product id.
    pub external_id: Option<String>,
    pub added_at: i64,
    pub last_played_at: Option<i64>,
    pub playtime_seconds: i64,
}

impl Game {
    pub fn effective_backend(&self) -> GraphicsBackend {
        self.preset.effective_backend(self.backend)
    }
}

/// Input for `add_game`. Everything except title and exe has a sensible default.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NewGame {
    pub title: String,
    pub exe_path: PathBuf,
    pub working_dir: Option<PathBuf>,
    pub bottle_id: Option<String>,
    pub preset: Option<Preset>,
    pub backend: Option<GraphicsBackend>,
    pub launch_args: Vec<String>,
    pub source: Option<GameSource>,
    pub external_id: Option<String>,
}

/// Partial update: `None` leaves a field unchanged. Nullable fields use `Option<Option<_>>`,
/// where `Some(None)` clears them.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GamePatch {
    pub title: Option<String>,
    pub exe_path: Option<PathBuf>,
    #[serde(with = "double_option")]
    pub working_dir: Option<Option<PathBuf>>,
    #[serde(with = "double_option")]
    pub bottle_id: Option<Option<String>>,
    pub preset: Option<Preset>,
    pub backend: Option<GraphicsBackend>,
    pub metal_hud: Option<bool>,
    pub launch_args: Option<Vec<String>>,
    pub env_overrides: Option<BTreeMap<String, String>>,
    #[serde(with = "double_option")]
    pub dxmt_config: Option<Option<String>>,
    #[serde(with = "double_option")]
    pub cover_path: Option<Option<PathBuf>>,
    #[serde(with = "double_option")]
    pub hero_path: Option<Option<PathBuf>>,
    pub favorite: Option<bool>,
}

/// Distinguishes "field absent" (`None`) from "field: null" (`Some(None)`) in JSON patches.
mod double_option {
    use serde::{Deserialize, Deserializer};

    pub fn deserialize<'de, T, D>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
    where
        T: Deserialize<'de>,
        D: Deserializer<'de>,
    {
        Option::<T>::deserialize(deserializer).map(Some)
    }
}

const MIGRATIONS: &[&str] = &[
    // v1
    r#"
    CREATE TABLE bottles (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        path            TEXT NOT NULL UNIQUE,
        runtime_id      TEXT NOT NULL,
        windows_version TEXT NOT NULL DEFAULT 'win10',
        created_at      INTEGER NOT NULL
    );
    CREATE TABLE games (
        id               TEXT PRIMARY KEY,
        title            TEXT NOT NULL,
        exe_path         TEXT NOT NULL,
        working_dir      TEXT,
        bottle_id        TEXT REFERENCES bottles(id) ON DELETE RESTRICT,
        preset           TEXT NOT NULL DEFAULT 'dx12-aaa',
        backend          TEXT NOT NULL DEFAULT 'd3dmetal',
        metal_hud        INTEGER NOT NULL DEFAULT 0,
        launch_args      TEXT NOT NULL DEFAULT '[]',
        env_overrides    TEXT NOT NULL DEFAULT '{}',
        dxmt_config      TEXT,
        cover_path       TEXT,
        hero_path        TEXT,
        favorite         INTEGER NOT NULL DEFAULT 0,
        source           TEXT NOT NULL DEFAULT 'local',
        external_id      TEXT,
        added_at         INTEGER NOT NULL,
        last_played_at   INTEGER,
        playtime_seconds INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX games_bottle ON games(bottle_id);
    CREATE UNIQUE INDEX games_external ON games(source, external_id) WHERE external_id IS NOT NULL;
    "#,
];

pub struct Library {
    conn: Connection,
}

impl Library {
    pub fn open(path: &Path) -> Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        let mut library = Self { conn };
        library.migrate()?;
        Ok(library)
    }

    fn migrate(&mut self) -> Result<()> {
        let current: usize = self
            .conn
            .pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))?
            as usize;
        if current > MIGRATIONS.len() {
            return Err(EngineError::Invalid(format!(
                "library database is newer (v{current}) than this app supports (v{}); update Aether Launcher",
                MIGRATIONS.len()
            )));
        }
        for (index, sql) in MIGRATIONS.iter().enumerate().skip(current) {
            let tx = self.conn.transaction()?;
            tx.execute_batch(sql)?;
            tx.pragma_update(None, "user_version", (index + 1) as i64)?;
            tx.commit()?;
        }
        Ok(())
    }

    // MARK: Bottles

    pub fn insert_bottle(&self, bottle: &Bottle) -> Result<()> {
        self.conn.execute(
            "INSERT INTO bottles (id, name, path, runtime_id, windows_version, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![bottle.id, bottle.name, path_str(&bottle.path), bottle.runtime_id, bottle.windows_version, bottle.created_at],
        )?;
        Ok(())
    }

    pub fn list_bottles(&self) -> Result<Vec<Bottle>> {
        let mut stmt = self.conn.prepare("SELECT id, name, path, runtime_id, windows_version, created_at FROM bottles ORDER BY name COLLATE NOCASE")?;
        let rows = stmt.query_map([], bottle_from_row)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn get_bottle(&self, id: &str) -> Result<Bottle> {
        self.conn
            .query_row(
                "SELECT id, name, path, runtime_id, windows_version, created_at FROM bottles WHERE id = ?1",
                [id],
                bottle_from_row,
            )
            .optional()?
            .ok_or_else(|| EngineError::NotFound(format!("bottle `{id}`")))
    }

    pub fn update_bottle(
        &self,
        id: &str,
        name: Option<&str>,
        runtime_id: Option<&str>,
        windows_version: Option<&str>,
    ) -> Result<Bottle> {
        let changed = self.conn.execute(
            "UPDATE bottles SET name = COALESCE(?2, name), runtime_id = COALESCE(?3, runtime_id), windows_version = COALESCE(?4, windows_version) WHERE id = ?1",
            params![id, name, runtime_id, windows_version],
        )?;
        if changed == 0 {
            return Err(EngineError::NotFound(format!("bottle `{id}`")));
        }
        self.get_bottle(id)
    }

    pub fn games_in_bottle(&self, bottle_id: &str) -> Result<i64> {
        Ok(self.conn.query_row(
            "SELECT COUNT(*) FROM games WHERE bottle_id = ?1",
            [bottle_id],
            |r| r.get(0),
        )?)
    }

    pub fn delete_bottle_row(&self, id: &str) -> Result<()> {
        let in_use = self.games_in_bottle(id)?;
        if in_use > 0 {
            return Err(EngineError::Invalid(format!(
                "{in_use} game(s) still use this bottle; move or remove them first"
            )));
        }
        self.conn
            .execute("DELETE FROM bottles WHERE id = ?1", [id])?;
        Ok(())
    }

    // MARK: Games

    pub fn add_game(&self, new: NewGame) -> Result<Game> {
        if new.title.trim().is_empty() {
            return Err(EngineError::Invalid("game title is required".into()));
        }
        if new.exe_path.as_os_str().is_empty() {
            return Err(EngineError::Invalid("game executable is required".into()));
        }
        let preset = new.preset.unwrap_or(Preset::Dx12Aaa);
        let game = Game {
            id: uuid::Uuid::new_v4().to_string(),
            title: new.title.trim().to_owned(),
            exe_path: new.exe_path,
            working_dir: new.working_dir,
            bottle_id: new.bottle_id,
            preset,
            backend: new
                .backend
                .or(preset.backend())
                .unwrap_or(GraphicsBackend::D3dmetal),
            metal_hud: preset.info().hud_default,
            launch_args: new.launch_args,
            env_overrides: BTreeMap::new(),
            dxmt_config: None,
            cover_path: None,
            hero_path: None,
            favorite: false,
            source: new.source.unwrap_or(GameSource::Local),
            external_id: new.external_id,
            added_at: now_unix(),
            last_played_at: None,
            playtime_seconds: 0,
        };
        self.conn.execute(
            "INSERT INTO games (id, title, exe_path, working_dir, bottle_id, preset, backend, metal_hud, launch_args,
                                env_overrides, dxmt_config, cover_path, hero_path, favorite, source, external_id, added_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)",
            params![
                game.id,
                game.title,
                path_str(&game.exe_path),
                game.working_dir.as_deref().map(path_str),
                game.bottle_id,
                game.preset.as_str(),
                game.backend.as_str(),
                game.metal_hud,
                serde_json::to_string(&game.launch_args)?,
                serde_json::to_string(&game.env_overrides)?,
                game.dxmt_config,
                game.cover_path.as_deref().map(path_str),
                game.hero_path.as_deref().map(path_str),
                game.favorite,
                game.source.as_str(),
                game.external_id,
                game.added_at,
            ],
        )?;
        Ok(game)
    }

    pub fn get_game(&self, id: &str) -> Result<Game> {
        self.conn
            .query_row(&format!("{GAME_SELECT} WHERE id = ?1"), [id], game_from_row)
            .optional()?
            .ok_or_else(|| EngineError::NotFound(format!("game `{id}`")))
    }

    pub fn find_by_external(&self, source: GameSource, external_id: &str) -> Result<Option<Game>> {
        Ok(self
            .conn
            .query_row(
                &format!("{GAME_SELECT} WHERE source = ?1 AND external_id = ?2"),
                params![source.as_str(), external_id],
                game_from_row,
            )
            .optional()?)
    }

    /// Favorites first, then most recently played, then title.
    pub fn list_games(&self) -> Result<Vec<Game>> {
        let mut stmt = self.conn.prepare(&format!(
            "{GAME_SELECT} ORDER BY favorite DESC, COALESCE(last_played_at, 0) DESC, title COLLATE NOCASE"
        ))?;
        let rows = stmt.query_map([], game_from_row)?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn update_game(&self, id: &str, patch: GamePatch) -> Result<Game> {
        let mut game = self.get_game(id)?;
        if let Some(v) = patch.title {
            if v.trim().is_empty() {
                return Err(EngineError::Invalid("game title cannot be empty".into()));
            }
            game.title = v.trim().to_owned();
        }
        if let Some(v) = patch.exe_path {
            game.exe_path = v;
        }
        if let Some(v) = patch.working_dir {
            game.working_dir = v;
        }
        if let Some(v) = patch.bottle_id {
            game.bottle_id = v;
        }
        if let Some(v) = patch.preset {
            game.preset = v;
            if let Some(backend) = v.backend() {
                game.backend = backend;
            }
        }
        if let Some(v) = patch.backend {
            game.backend = v;
        }
        if let Some(v) = patch.metal_hud {
            game.metal_hud = v;
        }
        if let Some(v) = patch.launch_args {
            game.launch_args = v;
        }
        if let Some(v) = patch.env_overrides {
            game.env_overrides = v;
        }
        if let Some(v) = patch.dxmt_config {
            game.dxmt_config = v;
        }
        if let Some(v) = patch.cover_path {
            game.cover_path = v;
        }
        if let Some(v) = patch.hero_path {
            game.hero_path = v;
        }
        if let Some(v) = patch.favorite {
            game.favorite = v;
        }

        self.conn.execute(
            "UPDATE games SET title = ?2, exe_path = ?3, working_dir = ?4, bottle_id = ?5, preset = ?6, backend = ?7,
                              metal_hud = ?8, launch_args = ?9, env_overrides = ?10, dxmt_config = ?11,
                              cover_path = ?12, hero_path = ?13, favorite = ?14
             WHERE id = ?1",
            params![
                game.id,
                game.title,
                path_str(&game.exe_path),
                game.working_dir.as_deref().map(path_str),
                game.bottle_id,
                game.preset.as_str(),
                game.backend.as_str(),
                game.metal_hud,
                serde_json::to_string(&game.launch_args)?,
                serde_json::to_string(&game.env_overrides)?,
                game.dxmt_config,
                game.cover_path.as_deref().map(path_str),
                game.hero_path.as_deref().map(path_str),
                game.favorite,
            ],
        )?;
        Ok(game)
    }

    pub fn delete_game(&self, id: &str) -> Result<()> {
        if self.conn.execute("DELETE FROM games WHERE id = ?1", [id])? == 0 {
            return Err(EngineError::NotFound(format!("game `{id}`")));
        }
        Ok(())
    }

    pub fn mark_launched(&self, id: &str, at: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE games SET last_played_at = ?2 WHERE id = ?1",
            params![id, at],
        )?;
        Ok(())
    }

    pub fn add_playtime(&self, id: &str, seconds: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE games SET playtime_seconds = playtime_seconds + ?2 WHERE id = ?1",
            params![id, seconds.max(0)],
        )?;
        Ok(())
    }
}

const GAME_SELECT: &str = "SELECT id, title, exe_path, working_dir, bottle_id, preset, backend, metal_hud, launch_args,
    env_overrides, dxmt_config, cover_path, hero_path, favorite, source, external_id, added_at, last_played_at,
    playtime_seconds FROM games";

fn path_str(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn bottle_from_row(row: &Row<'_>) -> rusqlite::Result<Bottle> {
    Ok(Bottle {
        id: row.get(0)?,
        name: row.get(1)?,
        path: PathBuf::from(row.get::<_, String>(2)?),
        runtime_id: row.get(3)?,
        windows_version: row.get(4)?,
        created_at: row.get(5)?,
    })
}

fn game_from_row(row: &Row<'_>) -> rusqlite::Result<Game> {
    fn json<T: serde::de::DeserializeOwned + Default>(raw: String) -> T {
        serde_json::from_str(&raw).unwrap_or_default()
    }
    Ok(Game {
        id: row.get(0)?,
        title: row.get(1)?,
        exe_path: PathBuf::from(row.get::<_, String>(2)?),
        working_dir: row.get::<_, Option<String>>(3)?.map(PathBuf::from),
        bottle_id: row.get(4)?,
        preset: row.get::<_, String>(5)?.parse().unwrap_or(Preset::Custom),
        backend: row
            .get::<_, String>(6)?
            .parse()
            .unwrap_or(GraphicsBackend::Wined3d),
        metal_hud: row.get(7)?,
        launch_args: json(row.get(8)?),
        env_overrides: json(row.get(9)?),
        dxmt_config: row.get(10)?,
        cover_path: row.get::<_, Option<String>>(11)?.map(PathBuf::from),
        hero_path: row.get::<_, Option<String>>(12)?.map(PathBuf::from),
        favorite: row.get(13)?,
        source: GameSource::parse(&row.get::<_, String>(14)?),
        external_id: row.get(15)?,
        added_at: row.get(16)?,
        last_played_at: row.get(17)?,
        playtime_seconds: row.get(18)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bottle(lib: &Library, id: &str) -> Bottle {
        let b = Bottle {
            id: id.into(),
            name: format!("Bottle {id}"),
            path: PathBuf::from(format!("/bottles/{id}")),
            runtime_id: "wine-10".into(),
            windows_version: "win10".into(),
            created_at: 1,
        };
        lib.insert_bottle(&b).unwrap();
        b
    }

    #[test]
    fn game_crud_and_patch_semantics() {
        let lib = Library::open_in_memory().unwrap();
        let b = bottle(&lib, "b1");
        let game = lib
            .add_game(NewGame {
                title: "  Cyberpunk 2077 ".into(),
                exe_path: "/g/Cyberpunk2077.exe".into(),
                bottle_id: Some(b.id.clone()),
                launch_args: vec!["--launcher-skip".into()],
                ..Default::default()
            })
            .unwrap();
        assert_eq!(game.title, "Cyberpunk 2077");
        assert_eq!(game.preset, Preset::Dx12Aaa);
        assert_eq!(game.backend, GraphicsBackend::D3dmetal);
        assert!(game.metal_hud, "DX12 AAA preset defaults the HUD on");
        assert_eq!(lib.get_game(&game.id).unwrap(), game);

        // Partial patch + explicit null.
        let patch: GamePatch = serde_json::from_value(serde_json::json!({
            "preset": "dx11-dxmt",
            "favorite": true,
            "envOverrides": {"DXMT_LOG_LEVEL": "info"},
            "dxmtConfig": "d3d11.preferredMaxFrameRate=60",
            "coverPath": "/art/c.png"
        }))
        .unwrap();
        let updated = lib.update_game(&game.id, patch).unwrap();
        assert_eq!(
            updated.backend,
            GraphicsBackend::Dxmt,
            "preset switch follows its backend"
        );
        assert!(updated.favorite);
        assert_eq!(updated.env_overrides["DXMT_LOG_LEVEL"], "info");
        assert_eq!(updated.title, "Cyberpunk 2077", "absent fields untouched");

        let clear: GamePatch =
            serde_json::from_value(serde_json::json!({"coverPath": null, "dxmtConfig": null}))
                .unwrap();
        let cleared = lib.update_game(&game.id, clear).unwrap();
        assert_eq!(cleared.cover_path, None);
        assert_eq!(cleared.dxmt_config, None);
        assert_eq!(
            lib.get_game(&game.id).unwrap(),
            cleared,
            "round-trips through SQLite"
        );

        lib.mark_launched(&game.id, 500).unwrap();
        lib.add_playtime(&game.id, 3600).unwrap();
        lib.add_playtime(&game.id, -5).unwrap(); // clamped
        let played = lib.get_game(&game.id).unwrap();
        assert_eq!(
            (played.last_played_at, played.playtime_seconds),
            (Some(500), 3600)
        );

        assert!(lib
            .add_game(NewGame {
                title: " ".into(),
                exe_path: "/x.exe".into(),
                ..Default::default()
            })
            .is_err());
        lib.delete_game(&game.id).unwrap();
        assert!(matches!(
            lib.get_game(&game.id),
            Err(EngineError::NotFound(_))
        ));
    }

    #[test]
    fn ordering_favorites_then_recent() {
        let lib = Library::open_in_memory().unwrap();
        let add = |t: &str| {
            lib.add_game(NewGame {
                title: t.into(),
                exe_path: "/x.exe".into(),
                ..Default::default()
            })
            .unwrap()
        };
        let a = add("Alpha");
        let b = add("Bravo");
        let c = add("Charlie");
        lib.mark_launched(&a.id, 10).unwrap();
        lib.mark_launched(&b.id, 20).unwrap();
        lib.update_game(
            &c.id,
            GamePatch {
                favorite: Some(true),
                ..Default::default()
            },
        )
        .unwrap();
        let titles: Vec<_> = lib
            .list_games()
            .unwrap()
            .into_iter()
            .map(|g| g.title)
            .collect();
        assert_eq!(titles, ["Charlie", "Bravo", "Alpha"]);
    }

    #[test]
    fn bottle_delete_is_blocked_while_in_use() {
        let lib = Library::open_in_memory().unwrap();
        let b = bottle(&lib, "b1");
        let game = lib
            .add_game(NewGame {
                title: "G".into(),
                exe_path: "/g.exe".into(),
                bottle_id: Some(b.id.clone()),
                ..Default::default()
            })
            .unwrap();
        assert!(lib
            .delete_bottle_row(&b.id)
            .unwrap_err()
            .to_string()
            .contains("1 game"));
        lib.delete_game(&game.id).unwrap();
        lib.delete_bottle_row(&b.id).unwrap();
        assert!(lib.list_bottles().unwrap().is_empty());
    }

    #[test]
    fn migrations_are_idempotent_on_disk() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("library.sqlite3");
        {
            let lib = Library::open(&path).unwrap();
            lib.add_game(NewGame {
                title: "Kept".into(),
                exe_path: "/k.exe".into(),
                ..Default::default()
            })
            .unwrap();
        }
        let reopened = Library::open(&path).unwrap();
        assert_eq!(reopened.list_games().unwrap().len(), 1);
    }
}
