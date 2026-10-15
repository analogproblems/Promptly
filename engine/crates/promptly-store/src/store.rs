//! The local copy of the vault, in SQLite.
//!
//! The store holds the merged [`State`] (every record with a timestamp per
//! field), this device's [`Clock`], the operations not yet pushed, and the
//! sync markers. Everything is kept in memory and written through, so reads
//! never touch the database. Records go in and out as JSON objects in the
//! vault's own format.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Mutex;

use promptly_vault::model::Collection;
use promptly_vault::state::{Field, Record as VaultRecord};
use promptly_vault::{
    Clock, DeviceId, Op, PullReport, State, SyncError, SyncState, Timestamp, Vault,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{Map, Value};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("database error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("could not create {0}: {1}")]
    Io(String, std::io::Error),
    #[error("{0}")]
    InvalidRecord(String),
    #[error("stored data is not valid: {0}")]
    Corrupt(String),
    #[error(transparent)]
    Sync(#[from] SyncError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub id: String,
    pub json: String,
}

struct Inner {
    conn: Connection,
    state: State,
    clock: Clock,
}

pub struct Store {
    inner: Mutex<Inner>,
    device: DeviceId,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS vault_records (
    col     TEXT NOT NULL,
    id      TEXT NOT NULL,
    deleted TEXT,
    fields  TEXT NOT NULL,
    PRIMARY KEY (col, id)
);
CREATE TABLE IF NOT EXISTS pending_ops (
    n  INTEGER PRIMARY KEY AUTOINCREMENT,
    op TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (
    key        TEXT PRIMARY KEY,
    json       TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
";

pub fn col_name(col: Collection) -> &'static str {
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

pub fn col_parse(name: &str) -> Option<Collection> {
    Some(match name {
        "hosts" => Collection::Hosts,
        "groups" => Collection::Groups,
        "identities" => Collection::Identities,
        "secrets" => Collection::Secrets,
        "snippets" => Collection::Snippets,
        "known_hosts" => Collection::KnownHosts,
        "themes" => Collection::Themes,
        "settings" => Collection::Settings,
        "devices" => Collection::Devices,
        _ => return None,
    })
}

fn now() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_default()
}

type FieldsJson = BTreeMap<String, (Value, Timestamp)>;

fn encode_fields(rec: &VaultRecord) -> String {
    let m: FieldsJson = rec
        .fields
        .iter()
        .map(|(k, f)| (k.clone(), (f.value.clone(), f.ts.clone())))
        .collect();
    serde_json::to_string(&m).expect("fields serialise")
}

fn decode_record(deleted: Option<String>, fields: &str) -> Result<VaultRecord, StoreError> {
    let deleted = match deleted {
        Some(s) => Some(serde_json::from_str(&s).map_err(|e| StoreError::Corrupt(e.to_string()))?),
        None => None,
    };
    let m: FieldsJson =
        serde_json::from_str(fields).map_err(|e| StoreError::Corrupt(e.to_string()))?;
    Ok(VaultRecord {
        deleted,
        fields: m
            .into_iter()
            .map(|(k, (value, ts))| (k, Field { value, ts }))
            .collect(),
    })
}

fn meta_get(conn: &Connection, key: &str) -> Result<Option<String>, StoreError> {
    let mut stmt = conn.prepare_cached("SELECT value FROM meta WHERE key = ?1")?;
    Ok(stmt.query_row(params![key], |r| r.get(0)).optional()?)
}

fn meta_set(conn: &Connection, key: &str, value: &str) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
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
        let device = match meta_get(&conn, "device_id")? {
            Some(s) => {
                DeviceId::parse(&s).ok_or_else(|| StoreError::Corrupt("device id".into()))?
            }
            None => {
                let d = DeviceId::generate();
                meta_set(&conn, "device_id", d.as_str())?;
                d
            }
        };
        let counter: u64 = meta_get(&conn, "clock")?
            .map(|s| s.parse().map_err(|_| StoreError::Corrupt("clock".into())))
            .transpose()?
            .unwrap_or(0);
        let mut state = State::new();
        {
            let mut stmt = conn.prepare("SELECT col, id, deleted, fields FROM vault_records")?;
            let rows = stmt.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })?;
            for row in rows {
                let (col, id, deleted, fields) = row?;
                let col = col_parse(&col)
                    .ok_or_else(|| StoreError::Corrupt(format!("collection {col}")))?;
                state.insert_record(col, id, decode_record(deleted, &fields)?);
            }
        }
        let store = Self {
            inner: Mutex::new(Inner {
                conn,
                state,
                clock: Clock::resume(device.clone(), counter),
            }),
            device,
        };
        store.migrate_legacy()?;
        Ok(store)
    }

    /// Records written by the milestone 1 store, before the vault model.
    fn migrate_legacy(&self) -> Result<(), StoreError> {
        let rows: Vec<(String, String, String)> = {
            let inner = self.inner.lock().unwrap();
            let exists: bool = inner.conn.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'records'",
                [],
                |r| r.get::<_, i64>(0).map(|n| n > 0),
            )?;
            if !exists {
                return Ok(());
            }
            let mut stmt = inner.conn.prepare("SELECT col, id, json FROM records")?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        for (col, id, json) in rows {
            if let Some(col) = col_parse(&col) {
                let _ = self.put(col, &id, &json);
            }
        }
        self.inner
            .lock()
            .unwrap()
            .conn
            .execute_batch("DROP TABLE IF EXISTS records")?;
        Ok(())
    }

    pub fn device_id(&self) -> &DeviceId {
        &self.device
    }

    /// The clock's counter, for status and snapshots.
    pub fn clock_counter(&self) -> u64 {
        self.inner.lock().unwrap().clock.counter()
    }

    // ---- Records ---------------------------------------------------------

    fn record_json(fields: &Map<String, Value>) -> String {
        serde_json::to_string(fields).expect("json object serialises")
    }

    /// Every visible record of a collection, by id.
    pub fn list(&self, col: Collection) -> Result<Vec<Record>, StoreError> {
        let inner = self.inner.lock().unwrap();
        Ok(inner
            .state
            .list(col)
            .into_iter()
            .map(|(id, fields)| Record {
                id,
                json: Self::record_json(&fields),
            })
            .collect())
    }

    pub fn get(&self, col: Collection, id: &str) -> Result<Option<Record>, StoreError> {
        let inner = self.inner.lock().unwrap();
        Ok(inner.state.get(col, id).map(|fields| Record {
            id: id.to_string(),
            json: Self::record_json(&fields),
        }))
    }

    /// The newest timestamp a record carries, if it exists at all.
    pub fn newest_ts(&self, col: Collection, id: &str) -> Option<Timestamp> {
        let inner = self.inner.lock().unwrap();
        inner
            .state
            .record(col, id)
            .and_then(|r| r.newest_ts().cloned())
    }

    /// Insert or replace. `json` must be an object. Only the fields that
    /// differ become an operation; returns whether anything changed.
    pub fn put(&self, col: Collection, id: &str, json: &str) -> Result<bool, StoreError> {
        let value: Value = serde_json::from_str(json)
            .map_err(|e| StoreError::InvalidRecord(format!("not valid JSON: {e}")))?;
        let Value::Object(fields) = value else {
            return Err(StoreError::InvalidRecord(
                "a record must be a JSON object".into(),
            ));
        };
        let mut inner = self.inner.lock().unwrap();
        let ts = inner.clock.tick();
        let Some(op) = inner.state.put_diff(col, id, &fields, ts, now()) else {
            return Ok(false);
        };
        inner.state.apply(&op);
        self.persist_op(&mut inner, col, id, &op)?;
        Ok(true)
    }

    pub fn delete(&self, col: Collection, id: &str) -> Result<bool, StoreError> {
        let mut inner = self.inner.lock().unwrap();
        if inner.state.get(col, id).is_none() {
            return Ok(false);
        }
        let op = Op::Del {
            col,
            id: id.to_string(),
            ts: inner.clock.tick(),
            at: now(),
        };
        inner.state.apply(&op);
        self.persist_op(&mut inner, col, id, &op)?;
        Ok(true)
    }

    fn persist_op(
        &self,
        inner: &mut Inner,
        col: Collection,
        id: &str,
        op: &Op,
    ) -> Result<(), StoreError> {
        let rec = inner
            .state
            .record(col, id)
            .cloned()
            .expect("record exists after apply");
        let counter = inner.clock.counter();
        let tx = inner.conn.transaction()?;
        Self::write_record(&tx, col, id, &rec)?;
        tx.execute(
            "INSERT INTO pending_ops (op) VALUES (?1)",
            params![serde_json::to_string(op).expect("op serialises")],
        )?;
        meta_set(&tx, "clock", &counter.to_string())?;
        tx.commit()?;
        Ok(())
    }

    fn write_record(
        conn: &Connection,
        col: Collection,
        id: &str,
        rec: &VaultRecord,
    ) -> Result<(), StoreError> {
        let deleted = rec
            .deleted
            .as_ref()
            .map(|d| serde_json::to_string(d).expect("timestamp serialises"));
        conn.execute(
            "INSERT INTO vault_records (col, id, deleted, fields) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(col, id) DO UPDATE SET deleted = excluded.deleted, fields = excluded.fields",
            params![col_name(col), id, deleted, encode_fields(rec)],
        )?;
        Ok(())
    }

    /// Rewrite every record, the clock and the sync state in one go, after
    /// a pull changed things.
    fn persist_all(inner: &mut Inner, sync: &SyncState) -> Result<(), StoreError> {
        let counter = inner.clock.counter();
        let records: Vec<(Collection, String, VaultRecord)> = inner
            .state
            .records()
            .map(|(c, id, r)| (c, id.to_string(), r.clone()))
            .collect();
        let tx = inner.conn.transaction()?;
        for (col, id, rec) in &records {
            Self::write_record(&tx, *col, id, rec)?;
        }
        meta_set(&tx, "clock", &counter.to_string())?;
        meta_set(
            &tx,
            "sync_state",
            &serde_json::to_string(sync).expect("sync state serialises"),
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Read-only access to the merged state, for exports and the CLI.
    pub fn with_state<R>(&self, f: impl FnOnce(&State) -> R) -> R {
        let inner = self.inner.lock().unwrap();
        f(&inner.state)
    }

    // ---- Settings and metadata (local to this device) -------------------

    pub fn setting_get(&self, key: &str) -> Result<Option<String>, StoreError> {
        let inner = self.inner.lock().unwrap();
        let mut stmt = inner
            .conn
            .prepare_cached("SELECT json FROM settings WHERE key = ?1")?;
        Ok(stmt.query_row(params![key], |r| r.get(0)).optional()?)
    }

    pub fn setting_set(&self, key: &str, json: &str) -> Result<(), StoreError> {
        let inner = self.inner.lock().unwrap();
        inner.conn.execute(
            "INSERT INTO settings (key, json, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at",
            params![key, json, now()],
        )?;
        Ok(())
    }

    /// Small device-local values: the vault configuration, markers.
    pub fn meta_get(&self, key: &str) -> Result<Option<String>, StoreError> {
        let inner = self.inner.lock().unwrap();
        meta_get(&inner.conn, key)
    }

    pub fn meta_set(&self, key: &str, value: &str) -> Result<(), StoreError> {
        let inner = self.inner.lock().unwrap();
        meta_set(&inner.conn, key, value)
    }

    pub fn meta_delete(&self, key: &str) -> Result<(), StoreError> {
        let inner = self.inner.lock().unwrap();
        inner
            .conn
            .execute("DELETE FROM meta WHERE key = ?1", params![key])?;
        Ok(())
    }

    // ---- Sync ------------------------------------------------------------

    pub fn pending_count(&self) -> Result<usize, StoreError> {
        let inner = self.inner.lock().unwrap();
        let n: i64 = inner
            .conn
            .query_row("SELECT COUNT(*) FROM pending_ops", [], |r| r.get(0))?;
        Ok(n as usize)
    }

    fn pending(conn: &Connection) -> Result<(Vec<Op>, i64), StoreError> {
        let mut stmt = conn.prepare("SELECT n, op FROM pending_ops ORDER BY n")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
        let mut ops = Vec::new();
        let mut max = 0;
        for row in rows {
            let (n, op) = row?;
            ops.push(serde_json::from_str(&op).map_err(|e| StoreError::Corrupt(e.to_string()))?);
            max = n;
        }
        Ok((ops, max))
    }

    pub fn sync_state(&self) -> Result<SyncState, StoreError> {
        let inner = self.inner.lock().unwrap();
        Ok(match meta_get(&inner.conn, "sync_state")? {
            Some(s) => serde_json::from_str(&s).map_err(|e| StoreError::Corrupt(e.to_string()))?,
            None => SyncState::default(),
        })
    }

    /// Forget the sync markers, for when the vault is disconnected. The
    /// records and the clock stay.
    pub fn reset_sync_state(&self) -> Result<(), StoreError> {
        self.meta_delete("sync_state")
    }

    /// Apply everything new from other devices; persists what changed.
    pub fn pull(&self, vault: &Vault) -> Result<PullReport, StoreError> {
        let mut inner = self.inner.lock().unwrap();
        let mut sync = match meta_get(&inner.conn, "sync_state")? {
            Some(s) => serde_json::from_str(&s).map_err(|e| StoreError::Corrupt(e.to_string()))?,
            None => SyncState::default(),
        };
        let Inner { state, clock, .. } = &mut *inner;
        let report = vault.pull(&mut sync, state, clock)?;
        Self::persist_all(&mut inner, &sync)?;
        Ok(report)
    }

    /// Write pending operations as the next segment. Returns its number,
    /// or `None` when there was nothing to push.
    pub fn push(&self, vault: &Vault) -> Result<Option<u64>, StoreError> {
        let mut inner = self.inner.lock().unwrap();
        let (ops, max_n) = Self::pending(&inner.conn)?;
        if ops.is_empty() {
            return Ok(None);
        }
        let mut sync = match meta_get(&inner.conn, "sync_state")? {
            Some(s) => serde_json::from_str(&s).map_err(|e| StoreError::Corrupt(e.to_string()))?,
            None => SyncState::default(),
        };
        let seq = vault.push(&mut sync, &ops)?;
        let tx = inner.conn.transaction()?;
        tx.execute("DELETE FROM pending_ops WHERE n <= ?1", params![max_n])?;
        meta_set(
            &tx,
            "sync_state",
            &serde_json::to_string(&sync).expect("sync state serialises"),
        )?;
        tx.commit()?;
        Ok(Some(seq))
    }

    /// Write a snapshot now (`force`), or only once this device's folder
    /// has grown past the limits.
    pub fn compact(&self, vault: &Vault, force: bool) -> Result<bool, StoreError> {
        let inner = self.inner.lock().unwrap();
        let mut sync = match meta_get(&inner.conn, "sync_state")? {
            Some(s) => serde_json::from_str(&s).map_err(|e| StoreError::Corrupt(e.to_string()))?,
            None => SyncState::default(),
        };
        let Inner { state, clock, .. } = &*inner;
        let did = if force {
            vault.write_snapshot(&mut sync, state, clock)?;
            true
        } else {
            vault.maybe_compact(&mut sync, state, clock)?
        };
        if did {
            meta_set(
                &inner.conn,
                "sync_state",
                &serde_json::to_string(&sync).expect("sync state serialises"),
            )?;
        }
        Ok(did)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use promptly_vault::backend::MemoryBackend;
    use promptly_vault::KdfParams;

    #[test]
    fn records_round_trip_and_only_changes_become_operations() {
        let s = Store::open_in_memory().unwrap();
        assert!(s.list(Collection::Hosts).unwrap().is_empty());
        assert!(s
            .put(
                Collection::Hosts,
                "a",
                r#"{"id":"a","label":"one","port":22}"#
            )
            .unwrap());
        assert!(s
            .put(Collection::Hosts, "b", r#"{"id":"b","label":"two"}"#)
            .unwrap());
        assert!(s
            .put(Collection::Groups, "g", r#"{"id":"g","label":"prod"}"#)
            .unwrap());
        assert_eq!(s.list(Collection::Hosts).unwrap().len(), 2);
        assert_eq!(s.list(Collection::Groups).unwrap().len(), 1);
        assert_eq!(s.pending_count().unwrap(), 3);

        assert!(
            !s.put(
                Collection::Hosts,
                "a",
                r#"{"id":"a","label":"one","port":22}"#
            )
            .unwrap(),
            "no change"
        );
        assert_eq!(s.pending_count().unwrap(), 3);
        assert!(s
            .put(
                Collection::Hosts,
                "a",
                r#"{"id":"a","label":"uno","port":22}"#
            )
            .unwrap());
        let got: Value =
            serde_json::from_str(&s.get(Collection::Hosts, "a").unwrap().unwrap().json).unwrap();
        assert_eq!(got["label"], "uno");
        assert_eq!(got["port"], 22);
        let (ops, _) = Store::pending(&s.inner.lock().unwrap().conn).unwrap();
        match &ops[3] {
            Op::Put { fields, .. } => assert_eq!(fields.keys().collect::<Vec<_>>(), ["label"]),
            _ => panic!(),
        }
        assert!(s.delete(Collection::Hosts, "a").unwrap());
        assert!(!s.delete(Collection::Hosts, "a").unwrap());
        assert_eq!(s.list(Collection::Hosts).unwrap().len(), 1);
        assert!(s.put(Collection::Hosts, "nope", "[1,2]").is_err());
    }

    #[test]
    fn settings_and_meta_round_trip() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.setting_get("theme").unwrap(), None);
        s.setting_set("theme", r#""dark""#).unwrap();
        s.setting_set("theme", r#""light""#).unwrap();
        assert_eq!(
            s.setting_get("theme").unwrap().as_deref(),
            Some(r#""light""#)
        );
        s.meta_set("vault", "x").unwrap();
        assert_eq!(s.meta_get("vault").unwrap().as_deref(), Some("x"));
        s.meta_delete("vault").unwrap();
        assert_eq!(s.meta_get("vault").unwrap(), None);
    }

    #[test]
    fn everything_survives_a_reopen_and_legacy_records_migrate() {
        let dir = std::env::temp_dir().join(format!("promptly-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("deep").join("promptly.db");
        {
            // A milestone 1 database.
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "CREATE TABLE records (col TEXT, id TEXT, json TEXT, updated_at TEXT, PRIMARY KEY (col, id));
                 INSERT INTO records VALUES ('hosts', 'h1', '{\"id\":\"h1\",\"label\":\"old\"}', '');",
            )
            .unwrap();
        }
        let device;
        {
            let s = Store::open(&path).unwrap();
            device = s.device_id().clone();
            assert_eq!(s.list(Collection::Hosts).unwrap().len(), 1, "migrated");
            s.put(
                Collection::Snippets,
                "x",
                r#"{"id":"x","label":"ls","command":"ls"}"#,
            )
            .unwrap();
            assert_eq!(s.clock_counter(), 2);
        }
        let again = Store::open(&path).unwrap();
        assert_eq!(again.device_id(), &device, "the device id is kept");
        assert_eq!(again.clock_counter(), 2);
        assert_eq!(again.list(Collection::Snippets).unwrap().len(), 1);
        assert_eq!(
            again.list(Collection::Hosts).unwrap()[0].json,
            r#"{"id":"h1","label":"old"}"#
        );
        assert_eq!(again.pending_count().unwrap(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn two_stores_sync_through_a_vault() {
        let backend = MemoryBackend::default();
        let a = Store::open_in_memory().unwrap();
        let b = Store::open_in_memory().unwrap();
        a.put(
            Collection::Hosts,
            "h",
            r#"{"id":"h","label":"web","port":22}"#,
        )
        .unwrap();

        let (va, _code) = Vault::create(
            &backend,
            a.device_id().clone(),
            "pw",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        assert_eq!(a.push(&va).unwrap(), Some(1));
        assert_eq!(a.push(&va).unwrap(), None, "nothing left");
        assert!(a.compact(&va, true).unwrap());

        let vb = Vault::open(&backend, b.device_id().clone(), "pw").unwrap();
        let report = b.pull(&vb).unwrap();
        assert_eq!(report.files_applied, 1);
        assert_eq!(
            b.list(Collection::Hosts).unwrap()[0].json,
            r#"{"id":"h","label":"web","port":22}"#
        );
        assert!(b.sync_state().unwrap().markers.contains_key(a.device_id()));

        b.put(
            Collection::Hosts,
            "h",
            r#"{"id":"h","label":"web","port":2222}"#,
        )
        .unwrap();
        b.push(&vb).unwrap();
        a.put(
            Collection::Hosts,
            "h",
            r#"{"id":"h","label":"web-1","port":22}"#,
        )
        .unwrap();
        a.push(&va).unwrap();
        a.pull(&va).unwrap();
        b.pull(&vb).unwrap();
        let want = r#"{"id":"h","label":"web-1","port":2222}"#;
        assert_eq!(a.list(Collection::Hosts).unwrap()[0].json, want);
        assert_eq!(b.list(Collection::Hosts).unwrap()[0].json, want);
        assert!(b.clock_counter() >= a.clock_counter() - 1);
    }
}
