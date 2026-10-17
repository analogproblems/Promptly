//! Keeps the local store in step with the vault: configuration, the
//! background loop, secrets, and the status the app shows.
//!
//! Lives outside `api/` so the bridge generator does not see its internals.

use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use promptly_ssh::{
    Algorithm, ConnectError, ConnectParams, Endpoint, FileKnownHosts, HostKeyInfo, HostKeyStatus,
    KnownHosts, PublicKey, QuietPrompter, SftpBackend, SftpError,
};
use promptly_store::{Collection, SecretStore, Store};
use promptly_term::TermSize;
use promptly_vault::backend::LocalFolder;
use promptly_vault::model::{Device, Host, KnownHost};
use promptly_vault::{crypto, Backend, Dek, Vault};
use serde::{Deserialize, Serialize};

use crate::api::sync::{SyncBackendKind, SyncDevice, SyncStatus};
use crate::frb_generated::StreamSink;

pub const META_VAULT: &str = "vault";
pub const META_SECRET_MARKERS: &str = "secret_markers";
pub const META_KNOWN_HOST_MARKER: &str = "known_hosts_applied";
pub const DEK_SECRET_ID: &str = "vault-dek";

/// Settle time after a local change before pushing.
const DEBOUNCE: Duration = Duration::from_secs(2);
/// How often to look for other devices' changes with nothing else going
/// on. A listing is one cheap call per device folder.
const PERIOD: Duration = Duration::from_secs(30);
const MAX_BACKOFF: Duration = Duration::from_secs(3600);

/// The device's known-hosts files, plus a record in the vault for every
/// key trusted here, so trusting a server once trusts it on every device.
pub struct VaultKnownHosts {
    files: FileKnownHosts,
}

impl VaultKnownHosts {
    pub fn new() -> Self {
        Self {
            files: FileKnownHosts::default_paths(&crate::api::engine::data_dir()),
        }
    }
}

impl Default for VaultKnownHosts {
    fn default() -> Self {
        Self::new()
    }
}

impl KnownHosts for VaultKnownHosts {
    fn check(&self, host: &str, port: u16, key: &PublicKey) -> HostKeyStatus {
        self.files.check(host, port, key)
    }

    fn known_algorithms(&self, host: &str, port: u16) -> Vec<Algorithm> {
        self.files.known_algorithms(host, port)
    }

    fn remember(&self, host: &str, port: u16, key: &PublicKey) -> std::io::Result<()> {
        self.files.remember(host, port, key)?;
        if let Ok(store) = store() {
            let info = HostKeyInfo::from_key(host, port, key);
            let record = KnownHost {
                id: promptly_vault::model::new_id(),
                host: host.to_string(),
                port,
                key_type: info.algorithm,
                fingerprint_sha256: info.fingerprint,
                public_key: info.public_key,
                first_seen_at: time::OffsetDateTime::now_utc(),
                first_seen_device: store.device_id().to_string(),
            };
            // One record per (host, port): the key trusted now replaces any
            // trusted before, on every device.
            let mut exists = false;
            for r in store.list(Collection::KnownHosts).unwrap_or_default() {
                let Ok(k) = serde_json::from_str::<KnownHost>(&r.json) else {
                    continue;
                };
                if k.host != record.host || k.port != record.port {
                    continue;
                }
                if k.public_key == record.public_key && !exists {
                    exists = true;
                } else {
                    let _ = store.delete(Collection::KnownHosts, &r.id);
                    notify_change();
                }
            }
            if !exists {
                if let Ok(json) = serde_json::to_string(&record) {
                    let _ = store.put(Collection::KnownHosts, &record.id.to_string(), &json);
                    notify_change();
                }
            }
        }
        Ok(())
    }
}

/// Keys other devices trusted land in this device's known-hosts file.
fn apply_pulled_known_hosts(store: &Store) -> Result<(), String> {
    let applied: std::collections::BTreeSet<String> = store
        .meta_get(META_KNOWN_HOST_MARKER)
        .map_err(|e| e.to_string())?
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    let mut now = applied.clone();
    let files = FileKnownHosts::default_paths(&crate::api::engine::data_dir());
    // Normally one record per host; two devices that trusted different
    // keys at once leave two until one of them trusts again. The newest
    // trust wins, the same on every device.
    let mut newest: std::collections::BTreeMap<(String, u16), (KnownHost, bool)> =
        Default::default();
    for r in store
        .list(Collection::KnownHosts)
        .map_err(|e| e.to_string())?
    {
        let Ok(k) = serde_json::from_str::<KnownHost>(&r.json) else {
            continue;
        };
        let fresh = now.insert(r.id);
        let slot = newest.entry((k.host.clone(), k.port));
        match slot {
            std::collections::btree_map::Entry::Vacant(v) => {
                v.insert((k, fresh));
            }
            std::collections::btree_map::Entry::Occupied(mut o) => {
                let (best, any_fresh) = o.get_mut();
                *any_fresh |= fresh;
                if (k.first_seen_at, k.id) > (best.first_seen_at, best.id) {
                    *best = k;
                }
            }
        }
    }
    for (k, any_fresh) in newest.into_values() {
        if !any_fresh {
            continue;
        }
        if let Ok(key) = PublicKey::from_openssh(&k.public_key) {
            if files.check(&k.host, k.port, &key) != HostKeyStatus::Known {
                let _ = files.remember(&k.host, k.port, &key);
            }
        }
    }
    if now.len() != applied.len() {
        store
            .meta_set(
                META_KNOWN_HOST_MARKER,
                &serde_json::to_string(&now).expect("set serialises"),
            )
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// What is kept in the store's metadata once a vault is set up.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VaultConfig {
    pub kind: String,
    pub path: String,
    pub vault_id: String,
    pub device_name: String,
    #[serde(default)]
    pub recovery_hint: Option<String>,
    /// For SFTP: the saved host the vault lives on.
    #[serde(default)]
    pub host_id: Option<String>,
}

impl VaultConfig {
    pub fn kind(&self) -> SyncBackendKind {
        match self.kind.as_str() {
            "sftp" => SyncBackendKind::Sftp,
            _ => SyncBackendKind::LocalFolder,
        }
    }
}

#[derive(Debug, Clone, Default)]
struct Status {
    syncing: bool,
    last_sync_at: Option<String>,
    last_error: Option<String>,
    warnings: Vec<String>,
    /// Operations applied from other devices since the app started; the
    /// UI reloads its lists when this moves.
    changes: u32,
}

enum Wake {
    LocalChange,
    Now,
}

pub struct SyncEngine {
    status: Mutex<Status>,
    sink: Mutex<Option<StreamSink<SyncStatus>>>,
    wake: Mutex<Option<Sender<Wake>>>,
    /// One sync at a time.
    run: Mutex<()>,
}

pub static ENGINE: LazyLock<SyncEngine> = LazyLock::new(|| SyncEngine {
    status: Mutex::new(Status::default()),
    sink: Mutex::new(None),
    wake: Mutex::new(None),
    run: Mutex::new(()),
});

fn store() -> Result<Arc<Store>, String> {
    crate::api::store::store()
}

fn secrets() -> Arc<dyn SecretStore> {
    crate::api::store::secrets()
}

pub fn config() -> Result<Option<VaultConfig>, String> {
    match store()?.meta_get(META_VAULT).map_err(|e| e.to_string())? {
        Some(json) => serde_json::from_str(&json)
            .map(Some)
            .map_err(|e| format!("the vault configuration is not valid: {e}")),
        None => Ok(None),
    }
}

pub fn dek() -> Result<Dek, String> {
    let bytes = secrets()
        .get(DEK_SECRET_ID)
        .map_err(|e| e.to_string())?
        .ok_or("the vault key is missing from this device; set up sync again")?;
    let raw = B64
        .decode(bytes)
        .map_err(|_| "the vault key on this device is not valid")?;
    Dek::from_slice(&raw).ok_or_else(|| "the vault key on this device is not valid".to_string())
}

/// One SFTP connection is kept between runs and dropped after a failure,
/// so the next run reconnects.
static SFTP_CACHE: Mutex<Option<(String, Arc<SftpBackend>)>> = Mutex::new(None);

pub fn backend_for(config: &VaultConfig) -> Result<Arc<dyn Backend>, String> {
    match config.kind() {
        SyncBackendKind::LocalFolder => Ok(Arc::new(LocalFolder::new(&config.path))),
        SyncBackendKind::Sftp => {
            let host_id = config.host_id.clone().ok_or("the SFTP setup has no host")?;
            Ok(connect_sftp(&host_id, &config.path)?)
        }
    }
}

pub fn forget_sftp() {
    *SFTP_CACHE.lock().unwrap() = None;
}

/// The saved host as connection parameters, using its stored password or
/// key, with its group's defaults and jump hosts resolved as a terminal
/// connection does. Unattended, so anything that would need a prompt is an
/// error that says what to do.
pub fn sftp_params(store: &Store, host_id: &str) -> Result<(ConnectParams, String), String> {
    let (mut request, label) = crate::host_plan::unattended_request(store, &*secrets(), host_id)?;
    let endpoint = Endpoint {
        user: request.user.clone(),
        host: request.host.clone(),
        port: request.port,
    };
    let params = crate::api::ssh::params_for(&mut request, endpoint, TermSize::default(), None);
    Ok((params, label))
}

/// Connect to the saved host over SFTP, reusing a live connection.
pub fn connect_sftp(host_id: &str, remote_dir: &str) -> Result<Arc<SftpBackend>, String> {
    let key = format!("{host_id}\n{remote_dir}");
    if let Some((k, b)) = SFTP_CACHE.lock().unwrap().as_ref() {
        if *k == key {
            return Ok(b.clone());
        }
    }
    let store = store()?;
    let (params, label) = sftp_params(&store, host_id)?;
    let known_hosts = Arc::new(VaultKnownHosts::new());
    let backend = SftpBackend::connect_blocking(
        &params,
        Arc::new(QuietPrompter),
        known_hosts,
        remote_dir,
    )
    .map_err(|e| match e {
        SftpError::Connect(ConnectError::HostKeyRejected { changed: false }) => {
            format!("Connect to {label} in the terminal once first, so its host key is trusted.")
        }
        SftpError::Connect(ConnectError::HostKeyRejected { changed: true }) => format!(
            "{label} showed a different host key from the one trusted before, so sync stopped. This can mean someone is intercepting the connection. Check with whoever runs the server before connecting to it in the terminal."
        ),
        SftpError::Connect(ConnectError::HostKeyRevoked) => format!(
            "{label}'s host key is marked as revoked in a known_hosts file, so sync stopped."
        ),
        SftpError::Connect(ConnectError::Cancelled)
        | SftpError::Connect(ConnectError::AuthFailed { .. }) => format!(
            "The saved login for {label} did not work. Check the password or key on the host."
        ),
        SftpError::Connect(ConnectError::KeyNeedsPassphrase) => format!(
            "The key for {label} needs its passphrase, which sync can't ask for. Pick a key without one for this host."
        ),
        SftpError::Connect(e) => {
            let plain = e.explain();
            format!("{label}: {}. {}", plain.title, plain.hint)
        }
        other => format!("{label}: {other}"),
    })?;
    let backend = Arc::new(backend);
    *SFTP_CACHE.lock().unwrap() = Some((key, backend.clone()));
    Ok(backend)
}

/// A label for where the vault lives, for the status line.
pub fn location_for(config: &VaultConfig) -> String {
    match config.kind() {
        SyncBackendKind::LocalFolder => config.path.clone(),
        SyncBackendKind::Sftp => {
            let label = config
                .host_id
                .as_ref()
                .and_then(|id| store().ok()?.get(Collection::Hosts, id).ok().flatten())
                .and_then(|r| serde_json::from_str::<Host>(&r.json).ok())
                .map(|h| h.label)
                .unwrap_or_else(|| "a server".into());
            format!("{label} · {}", config.path)
        }
    }
}

fn device_record(store: &Store, name: &str) -> Device {
    Device {
        id: store.device_id().as_uuid(),
        name: name.to_string(),
        platform: std::env::consts::OS.to_string(),
        enrolled_at: time::OffsetDateTime::now_utc(),
        last_seen_at: Some(time::OffsetDateTime::now_utc()),
        app_version: env!("CARGO_PKG_VERSION").to_string(),
    }
}

/// Store the configuration and key after a successful create or join, and
/// enrol this device: its record, every local secret, and a first sync.
pub fn finish_setup(
    config: VaultConfig,
    dek: &Dek,
    vault: &Vault,
    first_snapshot: bool,
) -> Result<(), String> {
    let store = store()?;
    secrets()
        .put(DEK_SECRET_ID, B64.encode(dek.0).as_bytes())
        .map_err(|e| format!("could not keep the vault key: {e}"))?;
    store
        .meta_set(
            META_VAULT,
            &serde_json::to_string(&config).expect("config serialises"),
        )
        .map_err(|e| e.to_string())?;
    store.reset_sync_state().map_err(|e| e.to_string())?;
    store
        .meta_delete(META_SECRET_MARKERS)
        .map_err(|e| e.to_string())?;

    let device = device_record(&store, &config.device_name);
    store
        .put(
            Collection::Devices,
            &device.id.to_string(),
            &serde_json::to_string(&device).expect("device serialises"),
        )
        .map_err(|e| e.to_string())?;
    // Every secret this device already has travels in the vault.
    for id in secrets().list().map_err(|e| e.to_string())? {
        if id == DEK_SECRET_ID {
            continue;
        }
        if let Some(value) = secrets().get(&id).map_err(|e| e.to_string())? {
            // The files do not record what they hold; keys announce themselves.
            let kind = if value.starts_with(b"-----BEGIN") || value.starts_with(b"PuTTY-User-Key") {
                "private_key"
            } else {
                "password"
            };
            put_secret_record(&store, dek, &id, kind, &value)?;
        }
    }
    {
        let _guard = ENGINE.run.lock().unwrap();
        let report = store.pull(vault).map_err(|e| e.to_string())?;
        ENGINE.status.lock().unwrap().changes += report.ops_applied as u32;
        apply_pulled_secrets(&store, dek)?;
        apply_pulled_known_hosts(&store)?;
        store.push(vault).map_err(|e| e.to_string())?;
        store
            .compact(vault, first_snapshot)
            .map_err(|e| e.to_string())?;
    }
    {
        let mut st = ENGINE.status.lock().unwrap();
        st.last_sync_at = Some(promptly_vault::ops::now_rfc3339());
        st.last_error = None;
    }
    ensure_loop();
    emit();
    Ok(())
}

/// Encrypt a secret under the vault key and store it as a `secrets` record.
pub fn put_secret_record(
    store: &Store,
    dek: &Dek,
    id: &str,
    kind: &str,
    value: &[u8],
) -> Result<(), String> {
    let aad = format!("secret/{id}");
    let ciphertext = crypto::seal(dek, aad.as_bytes(), value).map_err(|e| e.to_string())?;
    let record = serde_json::json!({
        "id": id,
        "kind": kind,
        "ciphertext": ciphertext,
        "sync": "vault",
    });
    store
        .put(Collection::Secrets, id, &record.to_string())
        .map_err(|e| e.to_string())?;
    if let Some(ts) = store.newest_ts(Collection::Secrets, id) {
        mark_secret(store, id, Some(&ts))?;
    }
    Ok(())
}

fn markers(store: &Store) -> Result<serde_json::Map<String, serde_json::Value>, String> {
    Ok(store
        .meta_get(META_SECRET_MARKERS)
        .map_err(|e| e.to_string())?
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default())
}

fn mark_secret(
    store: &Store,
    id: &str,
    ts: Option<&promptly_vault::Timestamp>,
) -> Result<(), String> {
    let mut m = markers(store)?;
    match ts {
        Some(ts) => {
            m.insert(
                id.to_string(),
                serde_json::to_value(ts).expect("timestamp serialises"),
            );
        }
        None => {
            m.remove(id);
        }
    }
    store
        .meta_set(
            META_SECRET_MARKERS,
            &serde_json::Value::Object(m).to_string(),
        )
        .map_err(|e| e.to_string())
}

/// Bring the secret files in line with the `secrets` records: new or
/// changed ones are decrypted and written, deleted ones removed.
fn apply_pulled_secrets(store: &Store, dek: &Dek) -> Result<(), String> {
    let mut m = markers(store)?;
    let mut changed = false;
    let records = store.with_state(|state| {
        state
            .records()
            .filter(|(c, _, _)| *c == Collection::Secrets)
            .map(|(_, id, r)| {
                (
                    id.to_string(),
                    r.is_visible(),
                    r.visible_fields(),
                    r.newest_ts().cloned(),
                )
            })
            .collect::<Vec<_>>()
    });
    for (id, visible, fields, newest) in records {
        let Some(newest) = newest else { continue };
        let seen = m
            .get(&id)
            .and_then(|v| serde_json::from_value::<promptly_vault::Timestamp>(v.clone()).ok());
        if seen.as_ref() == Some(&newest) {
            continue;
        }
        if visible {
            let Some(ct) = fields
                .get("ciphertext")
                .and_then(|v| serde_json::from_value::<Vec<u8>>(v.clone()).ok())
            else {
                continue;
            };
            let aad = format!("secret/{id}");
            match crypto::open(dek, aad.as_bytes(), &ct) {
                Ok(plain) => {
                    secrets().put(&id, &plain).map_err(|e| e.to_string())?;
                }
                Err(e) => {
                    ENGINE
                        .status
                        .lock()
                        .unwrap()
                        .warnings
                        .push(format!("secret {id}: {e}"));
                    continue;
                }
            }
        } else {
            secrets().delete(&id).map_err(|e| e.to_string())?;
        }
        m.insert(
            id,
            serde_json::to_value(&newest).expect("timestamp serialises"),
        );
        changed = true;
    }
    if changed {
        store
            .meta_set(
                META_SECRET_MARKERS,
                &serde_json::Value::Object(m).to_string(),
            )
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// One full round: pull, secrets, push, compact. Returns the warnings.
pub fn sync_once() -> Result<(), String> {
    let Some(config) = config()? else {
        return Err("sync is not set up".into());
    };
    let _guard = ENGINE.run.lock().unwrap();
    {
        let mut st = ENGINE.status.lock().unwrap();
        st.syncing = true;
        st.warnings.clear();
    }
    emit();
    let result = (|| {
        let store = store()?;
        let dek = dek()?;
        let backend = backend_for(&config)?;
        let vault = Vault::with_dek(
            &*backend,
            store.device_id().clone(),
            config.vault_id.clone(),
            dek.clone(),
        );
        let report = store.pull(&vault).map_err(|e| e.to_string())?;
        apply_pulled_secrets(&store, &dek)?;
        apply_pulled_known_hosts(&store)?;
        store.push(&vault).map_err(|e| e.to_string())?;
        store.compact(&vault, false).map_err(|e| e.to_string())?;
        Ok::<(Vec<String>, usize), String>((report.warnings, report.ops_applied))
    })();
    let mut st = ENGINE.status.lock().unwrap();
    st.syncing = false;
    match &result {
        Ok((warnings, applied)) => {
            st.last_sync_at = Some(promptly_vault::ops::now_rfc3339());
            st.last_error = None;
            st.warnings.extend(warnings.iter().cloned());
            st.changes = st.changes.wrapping_add(*applied as u32);
        }
        Err(e) => {
            st.last_error = Some(e.clone());
            forget_sftp();
        }
    }
    drop(st);
    emit();
    result.map(|_| ())
}

/// Called after any local change to a record or secret.
pub fn notify_change() {
    if let Some(tx) = ENGINE.wake.lock().unwrap().as_ref() {
        let _ = tx.send(Wake::LocalChange);
    }
}

/// Start the background loop if sync is set up and it is not running.
pub fn ensure_loop() {
    let mut wake = ENGINE.wake.lock().unwrap();
    if wake.is_some() {
        return;
    }
    if !matches!(config(), Ok(Some(_))) {
        return;
    }
    let (tx, rx) = mpsc::channel::<Wake>();
    *wake = Some(tx);
    std::thread::Builder::new()
        .name("promptly-sync".into())
        .spawn(move || {
            let mut backoff = Duration::from_secs(10);
            let mut next = Instant::now() + Duration::from_secs(1);
            loop {
                let timeout = next.saturating_duration_since(Instant::now());
                match rx.recv_timeout(timeout) {
                    Ok(Wake::LocalChange) => {
                        // Settle: more changes within the debounce window coalesce.
                        let settle = Instant::now() + DEBOUNCE;
                        while let Ok(_more) =
                            rx.recv_timeout(settle.saturating_duration_since(Instant::now()))
                        {
                            if settle <= Instant::now() {
                                break;
                            }
                        }
                    }
                    Ok(Wake::Now) => {}
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => return,
                }
                if config().ok().flatten().is_none() {
                    // Disconnected: stop until set up again.
                    *ENGINE.wake.lock().unwrap() = None;
                    return;
                }
                match sync_once() {
                    Ok(()) => {
                        backoff = Duration::from_secs(10);
                        next = Instant::now() + PERIOD;
                    }
                    Err(_) => {
                        next = Instant::now() + backoff.min(PERIOD);
                        backoff = (backoff * 2).min(MAX_BACKOFF);
                    }
                }
            }
        })
        .expect("spawn sync thread");
}

/// Forget the vault on this device. Records stay; the key and markers go.
pub fn disconnect() -> Result<(), String> {
    let store = store()?;
    store.meta_delete(META_VAULT).map_err(|e| e.to_string())?;
    store
        .meta_delete(META_SECRET_MARKERS)
        .map_err(|e| e.to_string())?;
    store
        .meta_delete(META_KNOWN_HOST_MARKER)
        .map_err(|e| e.to_string())?;
    store.reset_sync_state().map_err(|e| e.to_string())?;
    secrets().delete(DEK_SECRET_ID).map_err(|e| e.to_string())?;
    forget_sftp();
    // The loop notices the missing config on its next wake.
    if let Some(tx) = ENGINE.wake.lock().unwrap().as_ref() {
        let _ = tx.send(Wake::Now);
    }
    *ENGINE.status.lock().unwrap() = Status::default();
    emit();
    Ok(())
}

pub fn set_sink(sink: StreamSink<SyncStatus>) {
    *ENGINE.sink.lock().unwrap() = Some(sink);
    ensure_loop();
}

pub fn emit() {
    if let Ok(status) = status() {
        if let Some(sink) = ENGINE.sink.lock().unwrap().as_ref() {
            let _ = sink.add(status);
        }
    }
}

pub fn status() -> Result<SyncStatus, String> {
    let store = store()?;
    let config = config()?;
    let st = ENGINE.status.lock().unwrap().clone();
    let this = store.device_id().as_uuid().to_string();
    let mut devices: Vec<SyncDevice> = store
        .list(Collection::Devices)
        .map_err(|e| e.to_string())?
        .into_iter()
        .filter_map(|r| serde_json::from_str::<Device>(&r.json).ok())
        .map(|d| SyncDevice {
            id: d.id.to_string(),
            name: d.name,
            platform: d.platform,
            enrolled_at: d
                .enrolled_at
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap_or_default(),
            last_seen_at: d.last_seen_at.and_then(|t| {
                t.format(&time::format_description::well_known::Rfc3339)
                    .ok()
            }),
            is_this_device: d.id.to_string() == this,
        })
        .collect();
    devices.sort_by(|a, b| {
        b.is_this_device
            .cmp(&a.is_this_device)
            .then(a.name.cmp(&b.name))
    });
    let vault_bytes = match &config {
        // Only a cheap listing: a folder on disk, or an SFTP connection already open.
        Some(c)
            if c.kind() == SyncBackendKind::LocalFolder || SFTP_CACHE.lock().unwrap().is_some() =>
        {
            backend_for(c)
                .ok()
                .and_then(|b| {
                    let v = Vault::with_dek(
                        &*b,
                        store.device_id().clone(),
                        c.vault_id.clone(),
                        Dek([0; 32]),
                    );
                    v.total_bytes().ok()
                })
                .unwrap_or(0)
        }
        _ => 0,
    };
    Ok(SyncStatus {
        configured: config.is_some(),
        kind: config.as_ref().map(|c| c.kind()),
        location: config.as_ref().map(location_for),
        vault_id: config.as_ref().map(|c| c.vault_id.clone()),
        device_id: this,
        device_name: config
            .as_ref()
            .map(|c| c.device_name.clone())
            .unwrap_or_default(),
        syncing: st.syncing,
        last_sync_at: st.last_sync_at,
        last_error: st.last_error,
        warnings: st.warnings,
        pending_ops: store.pending_count().map_err(|e| e.to_string())? as u32,
        devices,
        vault_bytes: vault_bytes.min(u32::MAX as u64) as u32,
        recovery_hint: config.and_then(|c| c.recovery_hint),
        changes: st.changes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_vault_store_passes_on_the_kinds_of_key_it_trusts() {
        let dir = std::env::temp_dir().join(format!("promptly-vkh-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let store = VaultKnownHosts {
            files: FileKnownHosts::new(vec![], dir.join("known_hosts")),
        };
        let generated = promptly_ssh::generate_key(promptly_ssh::KeyKind::EcdsaP256, "").unwrap();
        let key = PublicKey::from_openssh(&generated.public_openssh).unwrap();
        // Through the file, so the test needs no store.
        store.files.remember("example.test", 22, &key).unwrap();
        assert_eq!(
            store.known_algorithms("example.test", 22),
            vec![key.algorithm()],
            "the handshake asks for the trusted ECDSA key first"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
