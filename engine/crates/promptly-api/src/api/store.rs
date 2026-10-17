//! The local record store and secret store, for the app.
//!
//! Records travel as JSON strings in the vault's own format, so nothing is
//! translated on the way to sync or export. Each put is checked against the
//! engine's data model for the collections that have one, so a record the
//! app writes is always one the engine (and the vault) can read. Every
//! change wakes the sync loop.

use std::sync::{Arc, Mutex};

use flutter_rust_bridge::frb;
use promptly_ssh::FileKnownHosts;
use promptly_store::{col_parse, Collection, DbKey, FileSecretStore, SecretStore, Store};
use promptly_vault::model::{Group, Host, Identity, Snippet};
use promptly_vault::Dek;

use crate::api::engine::data_dir;
use crate::sync_engine;

static STORE: Mutex<Option<Arc<Store>>> = Mutex::new(None);
static SECRETS: Mutex<Option<Arc<FileSecretStore>>> = Mutex::new(None);

/// The local database, opened on first use with a key derived from the
/// device key. It will not open until the app has said what became of that
/// key, so it is never opened unencrypted by mistake.
pub(crate) fn store() -> Result<Arc<Store>, String> {
    let mut guard = STORE.lock().unwrap();
    if let Some(s) = guard.as_ref() {
        return Ok(s.clone());
    }
    let s = match &*DEVICE_KEY.lock().unwrap() {
        None => return Err("the local store was used before startup finished".into()),
        Some(device_key) => Arc::new(open_store(device_key, &data_dir().join("promptly.db"))?),
    };
    *guard = Some(s.clone());
    Ok(s)
}

/// Plain on disk only when the system has no secure storage at all. When
/// the storage refused the key, the file is not touched: the app works from
/// an empty store kept in memory, so nothing is written unencrypted.
fn open_store(device_key: &DeviceKey, path: &std::path::Path) -> Result<Store, String> {
    let opened = match device_key {
        DeviceKey::Key(key) => Store::open(path, Some(&DbKey::derive(key))),
        DeviceKey::NoStorage => Store::open(path, None),
        DeviceKey::Unavailable => Store::open_in_memory(),
    };
    opened.map_err(|e| format!("could not open the local store at {}: {e}", path.display()))
}

static DEVICE_KEY: Mutex<Option<DeviceKey>> = Mutex::new(None);

enum DeviceKey {
    Key(Dek),
    NoStorage,
    Unavailable,
}

/// Hand the engine the device key from the platform's secure storage, so
/// saved secrets and the local database are encrypted on disk. Call once at
/// startup, before anything else; the database will not open until this,
/// [`set_no_device_key`] or [`set_device_key_unavailable`] has been called.
#[frb(sync)]
pub fn set_device_key(key: Vec<u8>) -> Result<(), String> {
    let key = Dek::from_slice(&key).ok_or("the device key must be 32 bytes")?;
    set_key(DeviceKey::Key(key))
}

/// Tell the engine the system has no secure storage to keep a device key
/// in (a Linux desktop with no keyring). Saved secrets are then plain
/// owner-only files and the local database is not encrypted.
#[frb(sync)]
pub fn set_no_device_key() -> Result<(), String> {
    set_key(DeviceKey::NoStorage)
}

/// Tell the engine the platform's secure storage exists but would not give
/// up the device key (denied, locked or damaged). Saved secrets are then
/// neither read nor written until the app restarts with the key, and the
/// local database is left alone: hosts and settings start empty and are
/// kept in memory only, never written unencrypted.
#[frb(sync)]
pub fn set_device_key_unavailable() -> Result<(), String> {
    set_key(DeviceKey::Unavailable)
}

fn set_key(key: DeviceKey) -> Result<(), String> {
    if SECRETS.lock().unwrap().is_some() {
        return Err("the secret store is already open".into());
    }
    if STORE.lock().unwrap().is_some() {
        return Err("the local store is already open".into());
    }
    *DEVICE_KEY.lock().unwrap() = Some(key);
    Ok(())
}

/// How saved passwords, keys and the vault key are kept on this device. The
/// local database follows the same device key: encrypted when there is one,
/// plain when there is not.
pub enum SecretsState {
    /// Encrypted with the device key.
    Encrypted,
    /// Plain owner-only files: the system has no secure storage.
    Plain,
    /// Neither read nor written: the secure storage refused the key.
    Locked,
}

#[frb(sync)]
pub fn secrets_state() -> SecretsState {
    let s = secret_store();
    if s.is_locked() {
        SecretsState::Locked
    } else if s.is_encrypted() {
        SecretsState::Encrypted
    } else {
        SecretsState::Plain
    }
}

fn secret_store() -> Arc<FileSecretStore> {
    let mut guard = SECRETS.lock().unwrap();
    if let Some(s) = guard.as_ref() {
        return s.clone();
    }
    let dir = data_dir().join("secrets");
    let s = Arc::new(match &*DEVICE_KEY.lock().unwrap() {
        Some(DeviceKey::Key(key)) => FileSecretStore::encrypted(dir, key.clone()),
        Some(DeviceKey::NoStorage) => FileSecretStore::new(dir),
        Some(DeviceKey::Unavailable) => FileSecretStore::locked(dir),
        // Too early: locked for now, and not kept, so the key can still come.
        None => return Arc::new(FileSecretStore::locked(dir)),
    });
    *guard = Some(s.clone());
    s
}

pub(crate) fn secrets() -> Arc<dyn SecretStore> {
    secret_store()
}

/// The known-hosts files: the user's own `~/.ssh/known_hosts`, read only,
/// and Promptly's file in the data folder, sealed with the device key like
/// the saved secrets (plain only when the system has no secure storage).
pub(crate) fn known_hosts_files() -> FileKnownHosts {
    // Unit tests never read the real one in the home folder.
    let user = if cfg!(test) {
        Some(data_dir().join("user_known_hosts"))
    } else {
        FileKnownHosts::user_file()
    };
    let files = FileKnownHosts::new(user.into_iter().collect(), data_dir().join("known_hosts"));
    match &*DEVICE_KEY.lock().unwrap() {
        Some(DeviceKey::Key(key)) => files.sealed(key.clone()),
        Some(DeviceKey::NoStorage) => files,
        // Too early, or refused: nothing is read or written in the clear.
        Some(DeviceKey::Unavailable) | None => files.locked(),
    }
}

fn collection(name: &str) -> Result<Collection, String> {
    col_parse(name).ok_or_else(|| format!("unknown collection {name:?}"))
}

/// Reject a record the engine could not read back.
fn validate(col: Collection, id: &str, json: &str) -> Result<(), String> {
    fn check<T: serde::de::DeserializeOwned>(
        json: &str,
        what: &str,
    ) -> Result<serde_json::Value, String> {
        serde_json::from_str::<T>(json).map_err(|e| format!("not a valid {what}: {e}"))?;
        serde_json::from_str(json).map_err(|e| e.to_string())
    }
    let value = match col {
        Collection::Hosts => check::<Host>(json, "host")?,
        Collection::Groups => check::<Group>(json, "group")?,
        Collection::Identities => check::<Identity>(json, "identity")?,
        Collection::Snippets => check::<Snippet>(json, "snippet")?,
        _ => serde_json::from_str(json).map_err(|e| format!("not valid JSON: {e}"))?,
    };
    match value.get("id").and_then(|v| v.as_str()) {
        Some(found) if found == id => Ok(()),
        Some(found) => Err(format!("record id {found:?} does not match {id:?}")),
        None => Err("record has no id".into()),
    }
}

pub struct StoreRecord {
    pub id: String,
    pub json: String,
}

#[frb(sync)]
pub fn records_list(collection_name: String) -> Result<Vec<StoreRecord>, String> {
    let col = collection(&collection_name)?;
    Ok(store()?
        .list(col)
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|r| StoreRecord {
            id: r.id,
            json: r.json,
        })
        .collect())
}

#[frb(sync)]
pub fn record_get(collection_name: String, id: String) -> Result<Option<StoreRecord>, String> {
    let col = collection(&collection_name)?;
    Ok(store()?
        .get(col, &id)
        .map_err(|e| e.to_string())?
        .map(|r| StoreRecord {
            id: r.id,
            json: r.json,
        }))
}

/// Insert or replace. The JSON must be a valid record of the collection
/// with a matching `id`. Only the fields that changed are recorded.
#[frb(sync)]
pub fn record_put(collection_name: String, id: String, json: String) -> Result<(), String> {
    let col = collection(&collection_name)?;
    validate(col, &id, &json)?;
    let changed = store()?.put(col, &id, &json).map_err(|e| e.to_string())?;
    if changed {
        sync_engine::notify_change();
    }
    Ok(())
}

#[frb(sync)]
pub fn record_delete(collection_name: String, id: String) -> Result<bool, String> {
    let col = collection(&collection_name)?;
    let gone = store()?.delete(col, &id).map_err(|e| e.to_string())?;
    if gone {
        sync_engine::notify_change();
    }
    Ok(gone)
}

#[frb(sync)]
pub fn setting_get(key: String) -> Result<Option<String>, String> {
    store()?.setting_get(&key).map_err(|e| e.to_string())
}

/// Save an app setting. The ones that make sense on every device (the
/// look, the terminal's behaviour) travel in the vault; the rest stay here.
#[frb(sync)]
pub fn setting_set(key: String, json: String) -> Result<(), String> {
    serde_json::from_str::<serde_json::Value>(&json).map_err(|e| format!("not valid JSON: {e}"))?;
    let changed = store()?
        .setting_set(&key, &json)
        .map_err(|e| e.to_string())?;
    if changed {
        sync_engine::notify_change();
    }
    Ok(())
}

/// Store a secret (a password, a private key) under an id the app chooses.
/// `kind` is `password`, `private_key` or `key_passphrase`. With a vault set
/// up, the secret also travels to the other devices, encrypted.
#[frb(sync)]
pub fn secret_put(id: String, kind: String, value: String) -> Result<(), String> {
    secrets()
        .put(&id, value.as_bytes())
        .map_err(|e| e.to_string())?;
    if sync_engine::config()?.is_some() {
        let dek = sync_engine::dek()?;
        let store = store()?;
        sync_engine::put_secret_record(&store, &dek, &id, &kind, value.as_bytes())?;
        sync_engine::notify_change();
    }
    Ok(())
}

#[frb(sync)]
pub fn secret_get(id: String) -> Result<Option<String>, String> {
    match secrets().get(&id).map_err(|e| e.to_string())? {
        Some(bytes) => Ok(Some(
            String::from_utf8(bytes).map_err(|_| "secret is not text".to_string())?,
        )),
        None => Ok(None),
    }
}

#[frb(sync)]
pub fn secret_delete(id: String) -> Result<(), String> {
    secrets().delete(&id).map_err(|e| e.to_string())?;
    if sync_engine::config()?.is_some() {
        let store = store()?;
        if store
            .delete(Collection::Secrets, &id)
            .map_err(|e| e.to_string())?
        {
            sync_engine::notify_change();
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST: &str = r#"{"hostname":"10.0.0.1","id":"h","label":"web"}"#;

    #[test]
    fn a_refused_key_writes_nothing_to_disk() {
        let dir = std::env::temp_dir().join(format!("promptly-api-refused-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // No database yet: none is made, and what is saved stays in memory.
        let path = dir.join("promptly.db");
        let s = open_store(&DeviceKey::Unavailable, &path).unwrap();
        s.put(Collection::Hosts, "h", HOST).unwrap();
        drop(s);
        assert!(!path.exists());

        // A plain one from before is neither read nor added to.
        let plain = dir.join("plain.db");
        drop(open_store(&DeviceKey::NoStorage, &plain).unwrap());
        let before = std::fs::read(&plain).unwrap();
        let s = open_store(&DeviceKey::Unavailable, &plain).unwrap();
        assert!(s.list(Collection::Hosts).unwrap().is_empty());
        s.put(Collection::Hosts, "h", HOST).unwrap();
        drop(s);
        assert_eq!(std::fs::read(&plain).unwrap(), before);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
