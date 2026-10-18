//! The local copy of the vault, in SQLite.
//!
//! The store holds the merged [`State`] (every record with a timestamp per
//! field), this device's [`Clock`], the operations not yet pushed, and the
//! sync markers. Everything is kept in memory and written through, so reads
//! never touch the database. Records go in and out as JSON objects in the
//! vault's own format.
//!
//! With a [`DbKey`] the file is SQLCipher: every page is encrypted, so the
//! file on disk reads as random bytes. Without one it is plain SQLite.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use hkdf::Hkdf;
use promptly_vault::model::{Collection, CREATED_AT, SETTINGS_ID, SYNCED_SETTINGS, UPDATED_AT};
use promptly_vault::policy::removed_devices;
use promptly_vault::state::{Field, Record as VaultRecord};
use promptly_vault::{
    Clock, Dek, DeviceId, Op, PullReport, State, SyncError, SyncState, Timestamp, Vault,
};
use rusqlite::{params, Connection, ErrorCode, OptionalExtension};
use serde_json::{Map, Value};
use sha2::Sha256;
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
    #[error("the database is encrypted and its key is not available")]
    Locked,
    #[error("the database is open in another copy of Promptly; close it and try again")]
    Busy,
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
    /// Held shared while the store is open, so a change to the whole file
    /// (encrypting it, or setting it aside) can tell nobody else uses it.
    _lock: Option<std::fs::File>,
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

/// The key that encrypts the database file. It is derived from a longer-lived
/// key (the device key in the app, the vault key in the CLI) and never is that
/// key itself, which already seals other files.
#[derive(Clone)]
pub struct DbKey([u8; 32]);

impl DbKey {
    pub fn derive(from: &Dek) -> Self {
        let mut key = [0u8; 32];
        Hkdf::<Sha256>::new(None, &from.0)
            .expand(b"promptly-db", &mut key)
            .expect("32 bytes is a valid HKDF length");
        Self(key)
    }

    /// SQLCipher's form for a raw key, so it skips its own passphrase stretching.
    fn literal(&self) -> String {
        let hex: String = self.0.iter().map(|b| format!("{b:02x}")).collect();
        format!("x'{hex}'")
    }
}

impl std::fmt::Debug for DbKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DbKey(…)")
    }
}

/// What the start of a database file says about it.
#[derive(Debug, PartialEq, Eq)]
enum FileKind {
    /// No file yet, or an empty one.
    Missing,
    Plain,
    /// Anything else: an encrypted file starts with random bytes.
    Encrypted,
}

fn file_kind(path: &Path) -> Result<FileKind, StoreError> {
    use std::io::Read;
    let mut head = Vec::with_capacity(16);
    match std::fs::File::open(path) {
        Ok(f) => f
            .take(16)
            .read_to_end(&mut head)
            .map_err(|e| StoreError::Io(path.display().to_string(), e))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(FileKind::Missing),
        Err(e) => return Err(StoreError::Io(path.display().to_string(), e)),
    };
    Ok(if head.is_empty() {
        FileKind::Missing
    } else if head == b"SQLite format 3\0" {
        FileKind::Plain
    } else {
        FileKind::Encrypted
    })
}

/// `path` with `suffix` added to its file name, as SQLite names its
/// `-wal` and `-shm` files.
fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(suffix);
    PathBuf::from(s)
}

/// The lock file beside the database. Every open store holds it shared;
/// rewriting or moving the database needs it alone.
fn open_lock(path: &Path) -> Result<std::fs::File, StoreError> {
    let lock_path = with_suffix(path, ".lock");
    let io = |e| StoreError::Io(lock_path.display().to_string(), e);
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock_path)
        .map_err(io)?;
    file.lock_shared().map_err(io)?;
    Ok(file)
}

/// The database to this store alone, until dropped: refused with
/// [`StoreError::Busy`] while any other store has it open.
struct Alone<'a>(&'a std::fs::File);

impl<'a> Alone<'a> {
    fn take(lock: &'a std::fs::File, path: &Path) -> Result<Self, StoreError> {
        let io = |e| StoreError::Io(path.display().to_string(), e);
        lock.unlock().map_err(io)?;
        match lock.try_lock() {
            Ok(()) => Ok(Self(lock)),
            Err(e) => {
                lock.lock_shared().map_err(io)?;
                Err(match e {
                    std::fs::TryLockError::WouldBlock => StoreError::Busy,
                    std::fs::TryLockError::Error(e) => io(e),
                })
            }
        }
    }
}

impl Drop for Alone<'_> {
    fn drop(&mut self) {
        let _ = self.0.unlock();
        let _ = self.0.lock_shared();
    }
}

/// Open `path`, keyed when there is a key, and read from it once so a wrong
/// key fails here rather than on first use.
fn connect(path: &Path, key: Option<&DbKey>) -> Result<Connection, rusqlite::Error> {
    let conn = Connection::open(path)?;
    if let Some(key) = key {
        conn.pragma_update(None, "key", key.literal())?;
    }
    conn.query_row("SELECT COUNT(*) FROM sqlite_master", [], |_| Ok(()))?;
    Ok(conn)
}

/// Rewrite a plain database encrypted, replacing it in one rename, so a
/// crash leaves either the plain file or the encrypted one.
///
/// Every SQLite connection to a file in WAL mode, whether a store, an older
/// Promptly or any other program, holds a lock on it for as long as it is
/// open, so leaving WAL mode works only for the last one. On the way out
/// SQLite folds the log into the file and removes it itself. The file is
/// then held alone until it is replaced. While anyone else has it open,
/// this is refused with [`StoreError::Busy`] and the file left as it is.
fn encrypt_in_place(path: &Path, key: &DbKey) -> Result<(), StoreError> {
    let tmp = with_suffix(path, &format!(".encrypting-{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let result = export_encrypted(path, &tmp, key);
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

fn export_encrypted(path: &Path, tmp: &Path, key: &DbKey) -> Result<(), StoreError> {
    let busy = |e: rusqlite::Error| match e.sqlite_error_code() {
        Some(ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked) => StoreError::Busy,
        _ => e.into(),
    };
    let conn = connect(path, None)?;
    let mode: String = conn
        .query_row("PRAGMA journal_mode = DELETE", [], |r| r.get(0))
        .map_err(busy)?;
    if !mode.eq_ignore_ascii_case("delete") {
        return Err(StoreError::Busy);
    }
    conn.execute_batch("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE; COMMIT;")
        .map_err(busy)?;
    conn.execute(
        "ATTACH DATABASE ?1 AS encrypted KEY ?2",
        params![tmp.to_string_lossy(), key.literal()],
    )?;
    conn.query_row("SELECT sqlcipher_export('encrypted')", [], |_| Ok(()))?;
    conn.execute("DETACH DATABASE encrypted", [])?;
    let replace =
        || std::fs::rename(tmp, path).map_err(|e| StoreError::Io(path.display().to_string(), e));
    // Replaced while still held. Windows cannot replace an open file, so
    // there it is closed first; a program that opened it since makes the
    // rename fail, and the plain file stays.
    if cfg!(windows) {
        drop(conn);
        replace()
    } else {
        replace()
    }
}

/// Keep a database no key here can read under a name nothing has, with its
/// log, and clear its place so a new one can start. Only while the
/// database is [`Alone`].
fn set_aside(path: &Path) -> Result<(), StoreError> {
    set_aside_with(path, |p| std::fs::remove_file(p))
}

/// Each file is first linked (or copied) to its kept name, and only then
/// are the originals removed, the log before the database. A failure or a
/// crash part way leaves a complete kept set, the originals, or both,
/// never a database apart from its log; and an error means no new database
/// starts.
fn set_aside_with(
    path: &Path,
    remove: impl Fn(&Path) -> std::io::Result<()>,
) -> Result<(), StoreError> {
    let stamp = OffsetDateTime::now_utc().unix_timestamp();
    let free = |aside: &Path| {
        ["", "-wal", "-shm"]
            .iter()
            .all(|s| !with_suffix(aside, s).exists())
    };
    let aside = (1..)
        .map(|n| match n {
            1 => with_suffix(path, &format!(".unreadable-{stamp}")),
            n => with_suffix(path, &format!(".unreadable-{stamp}-{n}")),
        })
        .find(|a| free(a))
        .expect("some name is free");
    let io = |p: &Path, e| StoreError::Io(p.display().to_string(), e);
    let files: Vec<(PathBuf, PathBuf)> = ["", "-wal", "-shm"]
        .iter()
        .map(|s| (with_suffix(path, s), with_suffix(&aside, s)))
        .filter(|(from, _)| from.exists())
        .collect();
    for (from, to) in &files {
        keep_copy(from, to).map_err(|e| io(from, e))?;
    }
    for (from, _) in files.iter().rev() {
        remove(from).map_err(|e| io(from, e))?;
    }
    Ok(())
}

/// `to` as a second name for `from`, or a copy where links are not
/// possible. Never replaces anything at `to`.
fn keep_copy(from: &Path, to: &Path) -> std::io::Result<()> {
    if std::fs::hard_link(from, to).is_ok() {
        return Ok(());
    }
    let mut src = std::fs::File::open(from)?;
    let mut dst = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(to)?;
    std::io::copy(&mut src, &mut dst)?;
    dst.sync_all()
}

impl Store {
    /// Open or create the database at `path`, encrypted with `key` if given.
    ///
    /// With a key, a plain file (written before the key existed) is
    /// encrypted first, and a file the key cannot read (sealed with a key
    /// that has since been replaced, so nothing can read it) is kept as
    /// `<name>.unreadable-<time>` and a new database started. Without a
    /// key, an encrypted file is refused with [`StoreError::Locked`] and
    /// left as it is, for when the key is back. Encrypting or setting aside
    /// waits for no one: while another store, or any other program, has
    /// the file open it is refused with [`StoreError::Busy`] and the file
    /// left as it is.
    pub fn open(path: &Path, key: Option<&DbKey>) -> Result<Self, StoreError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| StoreError::Io(parent.display().to_string(), e))?;
        }
        let lock = open_lock(path)?;
        let unreadable =
            |e: &rusqlite::Error| e.sqlite_error_code() == Some(ErrorCode::NotADatabase);
        let kind = file_kind(path)?;
        let conn = match (key, kind) {
            (None, FileKind::Encrypted) => return Err(StoreError::Locked),
            (None, _) => connect(path, None)?,
            (Some(key), FileKind::Plain) => {
                let _alone = Alone::take(&lock, path)?;
                // Another store may have encrypted it while this one waited.
                if file_kind(path)? == FileKind::Plain {
                    encrypt_in_place(path, key)?;
                }
                connect(path, Some(key))?
            }
            (Some(key), _) => match connect(path, Some(key)) {
                Err(e) if unreadable(&e) => {
                    let _alone = Alone::take(&lock, path)?;
                    match connect(path, Some(key)) {
                        Err(e) if unreadable(&e) => {
                            set_aside(path)?;
                            connect(path, Some(key))?
                        }
                        other => other?,
                    }
                }
                other => other?,
            },
        };
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")?;
        Self::init(conn, Some(lock))
    }

    pub fn open_in_memory() -> Result<Self, StoreError> {
        Self::init(Connection::open_in_memory()?, None)
    }

    fn init(conn: Connection, lock: Option<std::fs::File>) -> Result<Self, StoreError> {
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
            _lock: lock,
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
    ///
    /// A change is stamped with [`UPDATED_AT`], and a record that is new (or
    /// back after a deletion) with [`CREATED_AT`] as well, unless it brings
    /// its own, as a record from an export does. What `json` says about
    /// either is otherwise ignored: the store keeps them.
    pub fn put(&self, col: Collection, id: &str, json: &str) -> Result<bool, StoreError> {
        let value: Value = serde_json::from_str(json)
            .map_err(|e| StoreError::InvalidRecord(format!("not valid JSON: {e}")))?;
        let Value::Object(mut fields) = value else {
            return Err(StoreError::InvalidRecord(
                "a record must be a JSON object".into(),
            ));
        };
        let mut inner = self.inner.lock().unwrap();
        let exists = inner.state.get(col, id).is_some();
        fields.remove(UPDATED_AT);
        if exists {
            fields.remove(CREATED_AT);
        }
        let ts = inner.clock.tick();
        let Some(mut op) = inner.state.put_diff(col, id, &fields, ts, now()) else {
            return Ok(false);
        };
        if let Op::Put {
            at,
            fields: changed,
            ..
        } = &mut op
        {
            changed.insert(UPDATED_AT.into(), Value::String(at.clone()));
            if !exists {
                changed
                    .entry(CREATED_AT.to_string())
                    .or_insert_with(|| Value::String(at.clone()));
            }
        }
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

    // ---- Settings and metadata -------------------------------------------

    /// An app setting as JSON. Those in [`SYNCED_SETTINGS`] are fields of
    /// the vault's `settings` record; the rest live only on this device.
    pub fn setting_get(&self, key: &str) -> Result<Option<String>, StoreError> {
        let inner = self.inner.lock().unwrap();
        if SYNCED_SETTINGS.contains(&key) {
            return Ok(inner
                .state
                .get(Collection::Settings, SETTINGS_ID)
                .and_then(|fields| fields.get(key).map(Value::to_string)));
        }
        let mut stmt = inner
            .conn
            .prepare_cached("SELECT json FROM settings WHERE key = ?1")?;
        Ok(stmt.query_row(params![key], |r| r.get(0)).optional()?)
    }

    /// Save an app setting. Returns whether the vault has something new to
    /// sync: a synced setting that changed.
    pub fn setting_set(&self, key: &str, json: &str) -> Result<bool, StoreError> {
        if SYNCED_SETTINGS.contains(&key) {
            let value: Value = serde_json::from_str(json)
                .map_err(|e| StoreError::InvalidRecord(format!("not valid JSON: {e}")))?;
            let record = serde_json::json!({ "id": SETTINGS_ID, key: value });
            return self.put(Collection::Settings, SETTINGS_ID, &record.to_string());
        }
        let inner = self.inner.lock().unwrap();
        inner.conn.execute(
            "INSERT INTO settings (key, json, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at",
            params![key, json, now()],
        )?;
        Ok(false)
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
        sync_state(&inner.conn)
    }

    /// Whether the database at `path` opens with `key` as it is, so that
    /// [`Store::open`] sets nothing aside: true with no file yet, or a
    /// plain one, which the key encrypts.
    pub fn key_fits(path: &Path, key: &DbKey) -> Result<bool, StoreError> {
        Ok(match file_kind(path)? {
            FileKind::Missing | FileKind::Plain => true,
            FileKind::Encrypted => match connect(path, Some(key)) {
                Ok(_) => true,
                Err(e) if e.sqlite_error_code() == Some(ErrorCode::NotADatabase) => false,
                Err(e) => return Err(e.into()),
            },
        })
    }

    /// Encrypt the database under `key` from now on, for when the key it
    /// is derived from changes. Only for a store opened with a key.
    pub fn rekey(&self, key: &DbKey) -> Result<(), StoreError> {
        let inner = self.inner.lock().unwrap();
        inner.conn.pragma_update(None, "rekey", key.literal())?;
        Ok(())
    }

    /// Forget the sync markers, for when the vault is disconnected. The
    /// records and the clock stay.
    pub fn reset_sync_state(&self) -> Result<(), StoreError> {
        self.meta_delete("sync_state")
    }

    /// Apply everything new from other devices; persists what changed.
    ///
    /// Sync calls run on their own thread while the app reads and saves on
    /// its UI thread, so the store is locked only to take the markers and
    /// to apply what came back, never while files are listed and read.
    pub fn pull(&self, vault: &Vault) -> Result<PullReport, StoreError> {
        let (mut sync, removed) = {
            let inner = self.inner.lock().unwrap();
            (sync_state(&inner.conn)?, removed_devices(&inner.state))
        };
        let fetched = vault.fetch(&sync, &removed)?;
        let mut inner = self.inner.lock().unwrap();
        let Inner { state, clock, .. } = &mut *inner;
        let report = vault.apply_fetched(fetched, &mut sync, state, clock);
        Self::persist_all(&mut inner, &sync)?;
        Ok(report)
    }

    /// Write pending operations as the next segment. Returns its number,
    /// or `None` when there was nothing to push. The upload runs unlocked,
    /// as [`Store::pull`]'s reads do; operations saved meanwhile stay
    /// pending for the next push.
    pub fn push(&self, vault: &Vault) -> Result<Option<u64>, StoreError> {
        let (ops, max_n, mut sync) = {
            let inner = self.inner.lock().unwrap();
            let (ops, max_n) = Self::pending(&inner.conn)?;
            (ops, max_n, sync_state(&inner.conn)?)
        };
        if ops.is_empty() {
            return Ok(None);
        }
        let seq = vault.push(&mut sync, &ops)?;
        let mut inner = self.inner.lock().unwrap();
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

    /// Write a snapshot now (`force`), or only once one is owed or this
    /// device's folder has grown past the limits. It is written from a
    /// copy of the records, so the store stays unlocked while it uploads.
    pub fn compact(&self, vault: &Vault, force: bool) -> Result<bool, StoreError> {
        let (mut sync, state, clock) = {
            let inner = self.inner.lock().unwrap();
            let mut sync = sync_state(&inner.conn)?;
            if force && !sync.snapshot_due {
                // Owed until it is written, so a failure now is made up later.
                sync.snapshot_due = true;
                meta_set(
                    &inner.conn,
                    "sync_state",
                    &serde_json::to_string(&sync).expect("sync state serialises"),
                )?;
            }
            (sync, inner.state.clone(), inner.clock.clone())
        };
        let did = vault.maybe_compact(&mut sync, &state, &clock)?;
        if did {
            let inner = self.inner.lock().unwrap();
            meta_set(
                &inner.conn,
                "sync_state",
                &serde_json::to_string(&sync).expect("sync state serialises"),
            )?;
        }
        Ok(did)
    }
}

/// The sync markers as saved.
fn sync_state(conn: &Connection) -> Result<SyncState, StoreError> {
    Ok(match meta_get(conn, "sync_state")? {
        Some(s) => serde_json::from_str(&s).map_err(|e| StoreError::Corrupt(e.to_string()))?,
        None => SyncState::default(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use promptly_vault::backend::MemoryBackend;
    use promptly_vault::{Backend, BackendError, KdfParams};

    /// A record as the app wrote it: without the times the store adds.
    fn bare(r: &Record) -> String {
        let mut v: Map<String, Value> = serde_json::from_str(&r.json).unwrap();
        assert!(v.remove(CREATED_AT).is_some(), "{}", r.json);
        assert!(v.remove(UPDATED_AT).is_some(), "{}", r.json);
        serde_json::to_string(&v).unwrap()
    }

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
            Op::Put { fields, .. } => {
                assert_eq!(fields.keys().collect::<Vec<_>>(), ["label", UPDATED_AT])
            }
            _ => panic!(),
        }
        assert!(s.delete(Collection::Hosts, "a").unwrap());
        assert!(!s.delete(Collection::Hosts, "a").unwrap());
        assert_eq!(s.list(Collection::Hosts).unwrap().len(), 1);
        assert!(s.put(Collection::Hosts, "nope", "[1,2]").is_err());
    }

    #[test]
    fn records_carry_when_they_were_made_and_last_changed() {
        let s = Store::open_in_memory().unwrap();
        let stamps = |s: &Store| {
            let r: Value =
                serde_json::from_str(&s.get(Collection::Hosts, "h").unwrap().unwrap().json)
                    .unwrap();
            (
                r[CREATED_AT].as_str().unwrap().to_string(),
                r[UPDATED_AT].as_str().unwrap().to_string(),
            )
        };
        s.put(Collection::Hosts, "h", r#"{"id":"h","label":"web"}"#)
            .unwrap();
        let (created, updated) = stamps(&s);
        assert_eq!(created, updated);
        assert!(
            OffsetDateTime::parse(&created, &Rfc3339).is_ok(),
            "{created}"
        );

        // Nothing changed: nothing is stamped, whatever the times sent say.
        let stale = r#"{"id":"h","label":"web","created_at":"2001-01-01T00:00:00Z","updated_at":"2001-01-01T00:00:00Z"}"#;
        assert!(!s.put(Collection::Hosts, "h", stale).unwrap());
        assert_eq!(stamps(&s), (created.clone(), updated.clone()));

        // A change moves the update time and keeps the creation time.
        std::thread::sleep(std::time::Duration::from_millis(20));
        assert!(s
            .put(
                Collection::Hosts,
                "h",
                r#"{"id":"h","label":"web-1","created_at":"2001-01-01T00:00:00Z"}"#
            )
            .unwrap());
        let (created2, updated2) = stamps(&s);
        assert_eq!(created2, created);
        let at = |s: &str| OffsetDateTime::parse(s, &Rfc3339).unwrap();
        assert!(at(&updated2) > at(&updated), "{updated2} after {updated}");

        // A new record from an export keeps the time it was made.
        s.put(
            Collection::Snippets,
            "x",
            r#"{"id":"x","label":"ls","command":"ls","created_at":"2001-01-01T00:00:00Z"}"#,
        )
        .unwrap();
        let x: Value =
            serde_json::from_str(&s.get(Collection::Snippets, "x").unwrap().unwrap().json).unwrap();
        assert_eq!(x[CREATED_AT], "2001-01-01T00:00:00Z");
        assert_ne!(x[UPDATED_AT], "2001-01-01T00:00:00Z");
    }

    #[test]
    fn the_times_travel_and_merge_like_any_field() {
        let backend = MemoryBackend::default();
        let a = Store::open_in_memory().unwrap();
        let b = Store::open_in_memory().unwrap();
        let (va, _code) = Vault::create(
            &backend,
            a.device_id().clone(),
            "pw",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        let vb = Vault::open(&backend, b.device_id().clone(), "pw").unwrap();
        a.put(Collection::Hosts, "h", r#"{"id":"h","label":"web"}"#)
            .unwrap();
        a.push(&va).unwrap();
        b.pull(&vb).unwrap();
        let get = |s: &Store| -> Value {
            serde_json::from_str(&s.get(Collection::Hosts, "h").unwrap().unwrap().json).unwrap()
        };
        let made = get(&a)[CREATED_AT].clone();
        assert_eq!(get(&b)[CREATED_AT], made);

        // Edited on the second device, then snapshotted and read afresh.
        std::thread::sleep(std::time::Duration::from_millis(20));
        b.put(Collection::Hosts, "h", r#"{"id":"h","label":"web-1"}"#)
            .unwrap();
        b.push(&vb).unwrap();
        b.compact(&vb, true).unwrap();
        a.pull(&va).unwrap();
        assert_eq!(get(&a), get(&b));
        assert_eq!(get(&a)[CREATED_AT], made);
        assert_ne!(get(&a)[UPDATED_AT], made);
        let c = Store::open_in_memory().unwrap();
        c.pull(&Vault::open(&backend, c.device_id().clone(), "pw").unwrap())
            .unwrap();
        assert_eq!(get(&c), get(&b));
    }

    #[test]
    fn synced_settings_go_in_the_settings_record_and_the_rest_stay_here() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.setting_get("theme_mode").unwrap(), None);
        assert!(s.setting_set("theme_mode", r#""dark""#).unwrap());
        assert!(
            !s.setting_set("theme_mode", r#""dark""#).unwrap(),
            "no change"
        );
        assert!(s.setting_set("terminal_scrollback", "50000").unwrap());
        assert_eq!(
            s.setting_get("theme_mode").unwrap().as_deref(),
            Some(r#""dark""#)
        );
        assert_eq!(
            s.setting_get("terminal_scrollback").unwrap().as_deref(),
            Some("50000")
        );
        let record: Value = serde_json::from_str(
            &s.get(Collection::Settings, SETTINGS_ID)
                .unwrap()
                .unwrap()
                .json,
        )
        .unwrap();
        assert_eq!(record["id"], SETTINGS_ID);
        assert_eq!(record["theme_mode"], "dark");
        assert_eq!(record["terminal_scrollback"], 50000);
        assert_eq!(
            s.pending_count().unwrap(),
            2,
            "each change goes to the vault"
        );

        // This device's own choices never become operations.
        assert!(!s.setting_set("terminal_font_size", "18").unwrap());
        assert!(!s.setting_set("keyboard_bar_keys", r#"["esc"]"#).unwrap());
        assert_eq!(s.pending_count().unwrap(), 2);
        assert_eq!(
            s.setting_get("terminal_font_size").unwrap().as_deref(),
            Some("18")
        );
        assert!(s.setting_set("theme_mode", "not json").is_err());
    }

    #[test]
    fn a_setting_changed_on_one_device_shows_on_the_other() {
        let backend = MemoryBackend::default();
        let a = Store::open_in_memory().unwrap();
        let b = Store::open_in_memory().unwrap();
        let (va, _code) = Vault::create(
            &backend,
            a.device_id().clone(),
            "pw",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        let vb = Vault::open(&backend, b.device_id().clone(), "pw").unwrap();
        a.setting_set("terminal_bell", r#""vibrate""#).unwrap();
        a.setting_set("terminal_font_size", "20").unwrap();
        a.push(&va).unwrap();
        b.setting_set("paste_warning", "false").unwrap();
        b.push(&vb).unwrap();
        a.pull(&va).unwrap();
        b.pull(&vb).unwrap();
        for s in [&a, &b] {
            assert_eq!(
                s.setting_get("terminal_bell").unwrap().as_deref(),
                Some(r#""vibrate""#)
            );
            assert_eq!(
                s.setting_get("paste_warning").unwrap().as_deref(),
                Some("false"),
                "settings changed on each side both survive"
            );
        }
        assert_eq!(b.setting_get("terminal_font_size").unwrap(), None);
    }

    #[test]
    fn settings_and_meta_round_trip() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.setting_get("theme").unwrap(), None);
        assert!(!s.setting_set("theme", r#""dark""#).unwrap());
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
            let s = Store::open(&path, None).unwrap();
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
        let again = Store::open(&path, None).unwrap();
        assert_eq!(again.device_id(), &device, "the device id is kept");
        assert_eq!(again.clock_counter(), 2);
        assert_eq!(again.list(Collection::Snippets).unwrap().len(), 1);
        assert_eq!(
            bare(&again.list(Collection::Hosts).unwrap()[0]),
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
            bare(&b.list(Collection::Hosts).unwrap()[0]),
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
        assert_eq!(bare(&a.list(Collection::Hosts).unwrap()[0]), want);
        assert_eq!(bare(&b.list(Collection::Hosts).unwrap()[0]), want);
        assert!(b.clock_counter() >= a.clock_counter() - 1);
    }

    #[test]
    fn a_host_deleted_on_one_device_and_used_on_another_stays_deleted() {
        let backend = MemoryBackend::default();
        let a = Store::open_in_memory().unwrap();
        let b = Store::open_in_memory().unwrap();
        let host = r#"{"id":"h","label":"web","hostname":"web.example"}"#;
        a.put(Collection::Hosts, "h", host).unwrap();
        let (va, _code) = Vault::create(
            &backend,
            a.device_id().clone(),
            "pw",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        a.push(&va).unwrap();
        let vb = Vault::open(&backend, b.device_id().clone(), "pw").unwrap();
        b.pull(&vb).unwrap();

        // A deletes it. B, before hearing of that, connects to it, which
        // saves the whole host with one field changed.
        a.delete(Collection::Hosts, "h").unwrap();
        a.push(&va).unwrap();
        b.put(
            Collection::Hosts,
            "h",
            r#"{"id":"h","label":"web","hostname":"web.example","last_connected_at":"2026-10-18T00:00:00Z"}"#,
        )
        .unwrap();
        b.push(&vb).unwrap();
        a.pull(&va).unwrap();
        b.pull(&vb).unwrap();
        // Neither shows a host made of that one field: it stays deleted.
        assert!(a.list(Collection::Hosts).unwrap().is_empty());
        assert!(b.list(Collection::Hosts).unwrap().is_empty());
        assert!(a.get(Collection::Hosts, "h").unwrap().is_none());

        // Saved again in full, it comes back whole everywhere.
        b.put(Collection::Hosts, "h", host).unwrap();
        b.push(&vb).unwrap();
        a.pull(&va).unwrap();
        for s in [&a, &b] {
            let back = s.list(Collection::Hosts).unwrap();
            assert_eq!(back.len(), 1);
            let v: Value = serde_json::from_str(&back[0].json).unwrap();
            assert_eq!(v["id"], "h");
            assert_eq!(v["hostname"], "web.example");
        }
    }

    /// Refuses to write snapshots while `fail` is set, as a full disk or
    /// a dropped connection would.
    #[derive(Default)]
    struct NoSnapshots {
        inner: MemoryBackend,
        fail: std::sync::atomic::AtomicBool,
    }

    impl Backend for NoSnapshots {
        fn list(&self, dir: &str) -> Result<Vec<promptly_vault::Entry>, BackendError> {
            self.inner.list(dir)
        }
        fn get(&self, path: &str) -> Result<Vec<u8>, BackendError> {
            self.inner.get(path)
        }
        fn put_new(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError> {
            if path.ends_with(".snap") && self.fail.load(std::sync::atomic::Ordering::SeqCst) {
                return Err(BackendError::Io(
                    path.into(),
                    std::io::Error::other("no room"),
                ));
            }
            self.inner.put_new(path, bytes)
        }
        fn delete(&self, path: &str) -> Result<(), BackendError> {
            self.inner.delete(path)
        }
    }

    /// Counts the vault calls made while `store` is locked.
    #[derive(Default)]
    struct WhileLocked {
        inner: MemoryBackend,
        store: std::sync::OnceLock<std::sync::Arc<Store>>,
        locked: std::sync::atomic::AtomicUsize,
    }

    impl WhileLocked {
        fn check(&self) {
            if let Some(store) = self.store.get() {
                if store.inner.try_lock().is_err() {
                    self.locked
                        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                }
            }
        }
    }

    impl Backend for WhileLocked {
        fn list(&self, dir: &str) -> Result<Vec<promptly_vault::Entry>, BackendError> {
            self.check();
            self.inner.list(dir)
        }
        fn get(&self, path: &str) -> Result<Vec<u8>, BackendError> {
            self.check();
            self.inner.get(path)
        }
        fn put_new(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError> {
            self.check();
            self.inner.put_new(path, bytes)
        }
        fn delete(&self, path: &str) -> Result<(), BackendError> {
            self.check();
            self.inner.delete(path)
        }
    }

    #[test]
    fn the_store_is_not_locked_while_sync_reads_and_writes_files() {
        let backend = WhileLocked::default();
        let a = Store::open_in_memory().unwrap();
        a.put(Collection::Hosts, "h", HOST).unwrap();
        let (va, _) = Vault::create(
            &backend,
            a.device_id().clone(),
            "pw",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        a.push(&va).unwrap();

        let b = std::sync::Arc::new(Store::open_in_memory().unwrap());
        let vb = Vault::open(&backend, b.device_id().clone(), "pw").unwrap();
        assert!(backend.store.set(b.clone()).is_ok());
        b.put(
            Collection::Snippets,
            "s",
            r#"{"id":"s","label":"ls","command":"ls"}"#,
        )
        .unwrap();
        assert_eq!(b.pull(&vb).unwrap().ops_applied, 1);
        assert!(b.push(&vb).unwrap().is_some());
        assert!(b.compact(&vb, true).unwrap());
        assert_eq!(
            backend.locked.load(std::sync::atomic::Ordering::SeqCst),
            0,
            "the app's reads and saves would wait on the network"
        );
        assert!(b.get(Collection::Hosts, "h").unwrap().is_some());
        assert_eq!(b.pending_count().unwrap(), 0);
    }

    #[test]
    fn a_snapshot_that_failed_is_written_on_a_later_sync() {
        let backend = NoSnapshots::default();
        let a = Store::open_in_memory().unwrap();
        a.put(Collection::Hosts, "h", HOST).unwrap();
        let (va, _) = Vault::create(
            &backend,
            a.device_id().clone(),
            "pw",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        a.push(&va).unwrap();
        // The folder is emptied, as when a vault is set up again: only a
        // snapshot can bring the records back, and the first one fails.
        backend
            .inner
            .delete(&format!("devices/{}/000001.seg", a.device_id()))
            .unwrap();
        backend
            .fail
            .store(true, std::sync::atomic::Ordering::SeqCst);
        assert!(a.compact(&va, true).is_err());
        assert!(a.sync_state().unwrap().snapshot_due);

        // A later ordinary sync, with nothing to push, writes it.
        backend
            .fail
            .store(false, std::sync::atomic::Ordering::SeqCst);
        assert_eq!(a.push(&va).unwrap(), None);
        assert!(a.compact(&va, false).unwrap());
        assert!(!a.sync_state().unwrap().snapshot_due);

        let b = Store::open_in_memory().unwrap();
        let vb = Vault::open(&backend, b.device_id().clone(), "pw").unwrap();
        b.pull(&vb).unwrap();
        assert_eq!(b.list(Collection::Hosts).unwrap().len(), 1);
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("promptly-store-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    const HOST: &str = r#"{"hostname":"10.0.0.1","id":"h","label":"web"}"#;

    fn head(path: &Path) -> Vec<u8> {
        std::fs::read(path).unwrap()[..16].to_vec()
    }

    #[test]
    fn a_keyed_database_is_unreadable_without_its_key() {
        let dir = temp_dir("keyed");
        let path = dir.join("promptly.db");
        let key = DbKey::derive(&Dek::generate());
        let device;
        {
            let s = Store::open(&path, Some(&key)).unwrap();
            device = s.device_id().clone();
            s.put(Collection::Hosts, "h", HOST).unwrap();
        }
        assert_ne!(head(&path), b"SQLite format 3\0");
        let bytes = std::fs::read(&path).unwrap();
        assert!(!bytes.windows(8).any(|w| w == b"10.0.0.1"), "no plain text");

        let again = Store::open(&path, Some(&key)).unwrap();
        assert_eq!(again.device_id(), &device);
        assert_eq!(bare(&again.list(Collection::Hosts).unwrap()[0]), HOST);
        drop(again);

        // Plain SQLite cannot read it, and the store will not open it unkeyed.
        let plain = Connection::open(&path).unwrap();
        assert!(plain
            .query_row("SELECT COUNT(*) FROM sqlite_master", [], |_| Ok(()))
            .is_err());
        drop(plain);
        assert!(matches!(Store::open(&path, None), Err(StoreError::Locked)));
        assert!(connect(&path, Some(&DbKey::derive(&Dek::generate()))).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_rekeyed_database_opens_with_the_new_key_only() {
        let dir = temp_dir("rekey");
        let path = dir.join("promptly.db");
        let (old, new) = (
            DbKey::derive(&Dek::generate()),
            DbKey::derive(&Dek::generate()),
        );
        let device;
        {
            let s = Store::open(&path, Some(&old)).unwrap();
            device = s.device_id().clone();
            s.put(Collection::Hosts, "h", HOST).unwrap();
            s.rekey(&new).unwrap();
            s.put(Collection::Hosts, "h2", HOST).unwrap();
        }
        assert!(!Store::key_fits(&path, &old).unwrap());
        assert!(Store::key_fits(&path, &new).unwrap());
        let again = Store::open(&path, Some(&new)).unwrap();
        assert_eq!(again.device_id(), &device, "the same database");
        assert_eq!(again.list(Collection::Hosts).unwrap().len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_wrong_key_sets_the_file_aside_and_starts_again() {
        let dir = temp_dir("wrong-key");
        let path = dir.join("promptly.db");
        Store::open(&path, Some(&DbKey::derive(&Dek::generate())))
            .unwrap()
            .put(Collection::Hosts, "h", HOST)
            .unwrap();
        let s = Store::open(&path, Some(&DbKey::derive(&Dek::generate()))).unwrap();
        assert!(s.list(Collection::Hosts).unwrap().is_empty());
        let aside: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with("promptly.db.unreadable-") && !n.contains("-wal"))
            .collect();
        assert_eq!(aside.len(), 1, "the old file is kept: {aside:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn without_a_key_the_database_is_plain_and_a_key_later_encrypts_it() {
        let dir = temp_dir("plain");
        let path = dir.join("promptly.db");
        Store::open(&path, None)
            .unwrap()
            .put(Collection::Hosts, "h", HOST)
            .unwrap();
        assert_eq!(head(&path), b"SQLite format 3\0");
        assert_eq!(
            bare(
                &Store::open(&path, None)
                    .unwrap()
                    .list(Collection::Hosts)
                    .unwrap()[0]
            ),
            HOST
        );

        // The keyring arrives: the same data, now encrypted.
        let key = DbKey::derive(&Dek::generate());
        let s = Store::open(&path, Some(&key)).unwrap();
        assert_eq!(bare(&s.list(Collection::Hosts).unwrap()[0]), HOST);
        drop(s);
        assert_ne!(head(&path), b"SQLite format 3\0");
        assert!(no_leftovers(&path));
        let s = Store::open(&path, Some(&key)).unwrap();
        assert_eq!(bare(&s.list(Collection::Hosts).unwrap()[0]), HOST);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Nothing half-made is left beside the database.
    fn no_leftovers(path: &Path) -> bool {
        let dir = path.parent().unwrap();
        !std::fs::read_dir(dir).unwrap().any(|e| {
            e.unwrap()
                .file_name()
                .to_string_lossy()
                .contains(".encrypting")
        })
    }

    #[test]
    fn a_plain_database_any_program_has_open_is_left_as_it_is() {
        let dir = temp_dir("busy-raw");
        let path = dir.join("promptly.db");
        Store::open(&path, None)
            .unwrap()
            .put(Collection::Hosts, "h", HOST)
            .unwrap();
        // An older Promptly, or any SQLite program: no lock file of ours.
        let other = Connection::open(&path).unwrap();
        other
            .query_row("SELECT COUNT(*) FROM vault_records", [], |_| Ok(()))
            .unwrap();
        let key = DbKey::derive(&Dek::generate());
        assert!(matches!(
            Store::open(&path, Some(&key)),
            Err(StoreError::Busy)
        ));
        assert_eq!(head(&path), b"SQLite format 3\0", "untouched");
        assert!(no_leftovers(&path));

        // It goes on writing, into its log, and nothing it wrote is lost.
        other
            .execute(
                "INSERT INTO meta (key, value) VALUES ('written', 'after')",
                [],
            )
            .unwrap();
        assert!(with_suffix(&path, "-wal").exists());
        drop(other);
        let s = Store::open(&path, Some(&key)).unwrap();
        assert_eq!(bare(&s.list(Collection::Hosts).unwrap()[0]), HOST);
        drop(s);
        assert_ne!(head(&path), b"SQLite format 3\0");
        let written: String = connect(&path, Some(&key))
            .unwrap()
            .query_row("SELECT value FROM meta WHERE key = 'written'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(written, "after");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_failed_set_aside_never_parts_a_database_from_its_log() {
        // A database whose newest record is only in its log.
        let made = temp_dir("aside-made");
        let old_key = DbKey::derive(&Dek::generate());
        let live = made.join("promptly.db");
        let conn = connect(&live, Some(&old_key)).unwrap();
        conn.execute_batch(
            "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;
             CREATE TABLE t (x); INSERT INTO t VALUES ('in the log');",
        )
        .unwrap();
        let dir = temp_dir("aside-fail");
        let path = dir.join("promptly.db");
        for s in ["", "-wal"] {
            std::fs::copy(with_suffix(&live, s), with_suffix(&path, s)).unwrap();
        }
        drop(conn);
        let _ = std::fs::remove_dir_all(&made);
        let only_main = dir.join("only-main.db");
        std::fs::copy(&path, &only_main).unwrap();
        assert!(
            connect(&only_main, Some(&old_key))
                .and_then(|c| c.query_row("SELECT x FROM t", [], |_| Ok(())))
                .is_err(),
            "without its log the record is not there"
        );
        std::fs::remove_file(&only_main).unwrap();

        // Removing the database itself fails after its log is gone.
        let err = set_aside_with(&path, |p| {
            if p == path {
                Err(std::io::Error::other("injected"))
            } else {
                std::fs::remove_file(p)
            }
        });
        assert!(err.is_err());
        // Opening again sets the rest aside and starts afresh.
        let s = Store::open(&path, Some(&DbKey::derive(&Dek::generate()))).unwrap();
        assert!(s.list(Collection::Hosts).unwrap().is_empty());

        // Some kept set still has the record that was only in the log.
        let found = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| {
                let n = p.file_name().unwrap().to_string_lossy();
                n.starts_with("promptly.db.unreadable-")
                    && !n.contains("-wal")
                    && !n.contains("-shm")
            })
            .filter(|p| {
                connect(p, Some(&old_key))
                    .and_then(|c| c.query_row("SELECT x FROM t", [], |r| r.get::<_, String>(0)))
                    .is_ok_and(|x| x == "in the log")
            })
            .count();
        assert!(found >= 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_database_another_store_has_open_is_left_plain_until_it_closes() {
        let dir = temp_dir("busy");
        let path = dir.join("promptly.db");
        let other = Store::open(&path, None).unwrap();
        other.put(Collection::Hosts, "h", HOST).unwrap();
        let key = DbKey::derive(&Dek::generate());
        assert!(matches!(
            Store::open(&path, Some(&key)),
            Err(StoreError::Busy)
        ));
        assert_eq!(head(&path), b"SQLite format 3\0", "untouched");
        assert!(no_leftovers(&path));

        // The other store carries on, and what it writes is kept.
        let later = r#"{"hostname":"10.0.0.2","id":"g","label":"db"}"#;
        other.put(Collection::Hosts, "g", later).unwrap();
        drop(other);
        let s = Store::open(&path, Some(&key)).unwrap();
        let hosts: Vec<_> = s
            .list(Collection::Hosts)
            .unwrap()
            .iter()
            .map(bare)
            .collect();
        assert_eq!(hosts.len(), 2, "{hosts:?}");
        assert!(hosts.contains(&HOST.to_string()) && hosts.contains(&later.to_string()));
        drop(s);
        assert_ne!(head(&path), b"SQLite format 3\0");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn two_stores_encrypting_at_once_lose_nothing() {
        let dir = temp_dir("race");
        let path = dir.join("promptly.db");
        Store::open(&path, None)
            .unwrap()
            .put(Collection::Hosts, "h", HOST)
            .unwrap();
        let key = DbKey::derive(&Dek::generate());
        let start = std::sync::Barrier::new(2);
        std::thread::scope(|scope| {
            let open = || {
                start.wait();
                match Store::open(&path, Some(&key)) {
                    Ok(s) => assert_eq!(bare(&s.list(Collection::Hosts).unwrap()[0]), HOST),
                    Err(StoreError::Busy) => {}
                    Err(e) => panic!("{e}"),
                }
            };
            let a = scope.spawn(open);
            let b = scope.spawn(open);
            a.join().unwrap();
            b.join().unwrap();
        });
        assert!(no_leftovers(&path));
        let s = Store::open(&path, Some(&key)).unwrap();
        assert_eq!(bare(&s.list(Collection::Hosts).unwrap()[0]), HOST);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn files_set_aside_in_the_same_second_are_all_kept() {
        let dir = temp_dir("aside-twice");
        let path = dir.join("promptly.db");
        let keys: Vec<_> = (0..3).map(|_| DbKey::derive(&Dek::generate())).collect();
        for (i, key) in keys.iter().enumerate() {
            let s = Store::open(&path, Some(key)).unwrap();
            assert!(s.list(Collection::Hosts).unwrap().is_empty());
            s.put(Collection::Hosts, &format!("h{i}"), HOST).unwrap();
        }
        let mut aside: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| {
                let n = p.file_name().unwrap().to_string_lossy();
                n.starts_with("promptly.db.unreadable-")
                    && !n.ends_with("-wal")
                    && !n.ends_with("-shm")
                    && !n.ends_with(".lock")
            })
            .collect();
        aside.sort();
        assert_eq!(aside.len(), 2, "{aside:?}");
        // Each still opens with the key it was written under.
        for key in &keys[..2] {
            let kept = aside
                .iter()
                .filter(|p| {
                    connect(p, Some(key)).is_ok_and(|c| {
                        c.query_row("SELECT COUNT(*) FROM vault_records", [], |r| {
                            r.get::<_, i64>(0)
                        })
                        .is_ok_and(|n| n == 1)
                    })
                })
                .count();
            assert_eq!(kept, 1);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_database_key_is_not_the_key_it_comes_from() {
        let dek = Dek::generate();
        let a = DbKey::derive(&dek);
        assert_eq!(a.0, DbKey::derive(&dek).0);
        assert_ne!(a.0, dek.0);
        assert_ne!(a.0, DbKey::derive(&Dek::generate()).0);
    }
}
