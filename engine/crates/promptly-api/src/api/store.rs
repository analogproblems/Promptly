//! The local record store and secret store, for the app.
//!
//! Records travel as JSON strings in the vault's own format, so nothing is
//! translated on the way to sync or export. Each put is checked against the
//! engine's data model for the collections that have one, so a record the
//! app writes is always one the engine (and the vault) can read. Every
//! change wakes the sync loop.

use std::sync::{Arc, Mutex};

use flutter_rust_bridge::frb;
use promptly_store::{col_parse, Collection, FileSecretStore, SecretStore, Store};
use promptly_vault::model::{Group, Host, Identity, Snippet};
use promptly_vault::Dek;

use crate::api::engine::data_dir;
use crate::sync_engine;

static STORE: Mutex<Option<Arc<Store>>> = Mutex::new(None);
static SECRETS: Mutex<Option<Arc<FileSecretStore>>> = Mutex::new(None);

pub(crate) fn store() -> Result<Arc<Store>, String> {
    let mut guard = STORE.lock().unwrap();
    if let Some(s) = guard.as_ref() {
        return Ok(s.clone());
    }
    let path = data_dir().join("promptly.db");
    let s = Arc::new(
        Store::open(&path)
            .map_err(|e| format!("could not open the local store at {}: {e}", path.display()))?,
    );
    *guard = Some(s.clone());
    Ok(s)
}

static DEVICE_KEY: Mutex<Option<DeviceKey>> = Mutex::new(None);

enum DeviceKey {
    Key(Dek),
    Unavailable,
}

/// Hand the engine the device key from the platform's secure storage, so
/// saved secrets are encrypted on disk. Call once at startup, before
/// anything reads a secret; without it they are stored as plain files.
#[frb(sync)]
pub fn set_device_key(key: Vec<u8>) -> Result<(), String> {
    let key = Dek::from_slice(&key).ok_or("the device key must be 32 bytes")?;
    set_key(DeviceKey::Key(key))
}

/// Tell the engine the platform's secure storage exists but would not give
/// up the device key (denied, locked or damaged). Saved secrets are then
/// neither read nor written until the app restarts with the key.
#[frb(sync)]
pub fn set_device_key_unavailable() -> Result<(), String> {
    set_key(DeviceKey::Unavailable)
}

fn set_key(key: DeviceKey) -> Result<(), String> {
    if SECRETS.lock().unwrap().is_some() {
        return Err("the secret store is already open".into());
    }
    *DEVICE_KEY.lock().unwrap() = Some(key);
    Ok(())
}

/// How saved passwords, keys and the vault key are kept on this device.
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
        Some(DeviceKey::Unavailable) => FileSecretStore::locked(dir),
        None => FileSecretStore::new(dir),
    });
    *guard = Some(s.clone());
    s
}

pub(crate) fn secrets() -> Arc<dyn SecretStore> {
    secret_store()
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

#[frb(sync)]
pub fn setting_set(key: String, json: String) -> Result<(), String> {
    serde_json::from_str::<serde_json::Value>(&json).map_err(|e| format!("not valid JSON: {e}"))?;
    store()?.setting_set(&key, &json).map_err(|e| e.to_string())
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
