//! JSON records in SQLite.

use std::path::Path;
use std::sync::Mutex;

use promptly_vault::model::Collection;
use rusqlite::{params, Connection, OptionalExtension};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("database error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("could not create {0}: {1}")]
    Io(String, std::io::Error),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub id: String,
    pub json: String,
    pub updated_at: String,
}

pub struct Store {
    conn: Mutex<Connection>,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS records (
    col        TEXT NOT NULL,
    id         TEXT NOT NULL,
    json       TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (col, id)
);
CREATE TABLE IF NOT EXISTS settings (
    key        TEXT PRIMARY KEY,
    json       TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
";

fn col_name(col: Collection) -> &'static str {
    match col {
        Collection::Hosts => "hosts",
        Collection::Groups => "groups",
        Collection::Identities => "identities",
        Collection::Secrets => "secrets",
        Collection::Snippets => "snippets",
        Collection::KnownHosts => "known_hosts",
        Collection::Themes => "themes",
        Collection::Settings => "settings",
        Collection::Devices => "devices",
    }
}

fn now() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default()
}

impl Store {
    /// Open or create the database at `path`.
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| StoreError::Io(parent.display().to_string(), e))?;
        }
        let conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Self, StoreError> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self, StoreError> {
        conn.execute_batch(SCHEMA)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn list(&self, col: Collection) -> Result<Vec<Record>, StoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT id, json, updated_at FROM records WHERE col = ?1 ORDER BY updated_at DESC, id",
        )?;
        let rows = stmt.query_map(params![col_name(col)], |r| {
            Ok(Record {
                id: r.get(0)?,
                json: r.get(1)?,
                updated_at: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    pub fn get(&self, col: Collection, id: &str) -> Result<Option<Record>, StoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT id, json, updated_at FROM records WHERE col = ?1 AND id = ?2",
        )?;
        Ok(stmt
            .query_row(params![col_name(col), id], |r| {
                Ok(Record {
                    id: r.get(0)?,
                    json: r.get(1)?,
                    updated_at: r.get(2)?,
                })
            })
            .optional()?)
    }

    /// Insert or replace.
    pub fn put(&self, col: Collection, id: &str, json: &str) -> Result<(), StoreError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO records (col, id, json, updated_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(col, id) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at",
            params![col_name(col), id, json, now()],
        )?;
        Ok(())
    }

    pub fn delete(&self, col: Collection, id: &str) -> Result<bool, StoreError> {
        let conn = self.conn.lock().unwrap();
        let n = conn.execute(
            "DELETE FROM records WHERE col = ?1 AND id = ?2",
            params![col_name(col), id],
        )?;
        Ok(n > 0)
    }

    pub fn setting_get(&self, key: &str) -> Result<Option<String>, StoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached("SELECT json FROM settings WHERE key = ?1")?;
        Ok(stmt.query_row(params![key], |r| r.get(0)).optional()?)
    }

    pub fn setting_set(&self, key: &str, json: &str) -> Result<(), StoreError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO settings (key, json, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at",
            params![key, json, now()],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_round_trip() {
        let s = Store::open_in_memory().unwrap();
        assert!(s.list(Collection::Hosts).unwrap().is_empty());
        s.put(Collection::Hosts, "a", r#"{"label":"one"}"#).unwrap();
        s.put(Collection::Hosts, "b", r#"{"label":"two"}"#).unwrap();
        s.put(Collection::Groups, "g", r#"{"label":"prod"}"#)
            .unwrap();
        assert_eq!(s.list(Collection::Hosts).unwrap().len(), 2);
        assert_eq!(s.list(Collection::Groups).unwrap().len(), 1);

        s.put(Collection::Hosts, "a", r#"{"label":"uno"}"#).unwrap();
        assert_eq!(
            s.get(Collection::Hosts, "a").unwrap().unwrap().json,
            r#"{"label":"uno"}"#
        );
        assert!(s.delete(Collection::Hosts, "a").unwrap());
        assert!(!s.delete(Collection::Hosts, "a").unwrap());
        assert_eq!(s.list(Collection::Hosts).unwrap().len(), 1);
    }

    #[test]
    fn settings_round_trip() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.setting_get("theme").unwrap(), None);
        s.setting_set("theme", r#""dark""#).unwrap();
        s.setting_set("theme", r#""light""#).unwrap();
        assert_eq!(
            s.setting_get("theme").unwrap().as_deref(),
            Some(r#""light""#)
        );
    }

    #[test]
    fn opens_a_file_and_creates_parents() {
        let dir = std::env::temp_dir().join(format!("promptly-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let s = Store::open(&dir.join("deep").join("promptly.db")).unwrap();
        s.put(Collection::Snippets, "x", "{}").unwrap();
        drop(s);
        let again = Store::open(&dir.join("deep").join("promptly.db")).unwrap();
        assert_eq!(again.list(Collection::Snippets).unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
