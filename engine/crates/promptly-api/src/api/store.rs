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

pub(crate) fn secrets() -> Arc<dyn SecretStore> {
    let mut guard = SECRETS.lock().unwrap();
    if let Some(s) = guard.as_ref() {
        return s.clone();
    }
    let s = Arc::new(FileSecretStore::new(data_dir().join("secrets")));
    *guard = Some(s.clone());
    s
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
