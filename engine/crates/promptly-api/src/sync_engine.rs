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
use promptly_vault::manifest::ManifestError;
use promptly_vault::model::{Device, Host, KnownHost};
use promptly_vault::policy::{self, Kept, KeptPlan};
use promptly_vault::{
    crypto, Backend, Dek, DeviceId, Manifest, Marker, RecoveryCode, SyncError, Vault,
};
use serde::{Deserialize, Serialize};

use crate::api::sync::{SyncAttention, SyncBackendKind, SyncDevice, SyncStatus};
use crate::frb_generated::StreamSink;

pub const META_VAULT: &str = "vault";
pub const META_SECRET_MARKERS: &str = "secret_markers";
pub const META_KNOWN_HOST_MARKER: &str = "known_hosts_applied";
/// The records kept on this device last time, with their tombstones.
pub const META_KEPT: &str = "kept_on_device";
/// The folder this device writes in the vault, once it is not the store's
/// own id: a device removed from a vault joins it again as a new one.
pub const META_DEVICE: &str = "vault_device";
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
    /// The manifest's [`Manifest::keys_fingerprint`] when this device last
    /// unlocked it; a different one means the passphrase changed elsewhere.
    /// Missing in setups from before this was kept: the first sync fills it.
    ///
    /// [`Manifest::keys_fingerprint`]: promptly_vault::Manifest::keys_fingerprint
    #[serde(default)]
    pub manifest_keys: Option<String>,
    /// A full snapshot is still owed: the key was changed and the snapshot
    /// under the new one could not be written yet.
    #[serde(default)]
    pub snapshot_due: bool,
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
    /// Set when the vault itself needs the person, not just another try.
    attention: Option<SyncAttention>,
    warnings: Vec<String>,
    /// Operations applied from other devices since the app started; the
    /// UI reloads its lists when this moves.
    changes: u32,
}

enum Wake {
    LocalChange,
    Now,
    /// Work out when the next run is due again, without running now (a
    /// sync the person started has just reset the backoff).
    Reschedule,
}

pub struct SyncEngine {
    status: Mutex<Status>,
    sink: Mutex<Option<StreamSink<SyncStatus>>>,
    wake: Mutex<Option<Sender<Wake>>>,
    /// One sync at a time.
    run: Mutex<()>,
    /// Failed runs in a row, for the backoff.
    failures: Mutex<u32>,
}

pub static ENGINE: LazyLock<SyncEngine> = LazyLock::new(|| SyncEngine {
    status: Mutex::new(Status::default()),
    sink: Mutex::new(None),
    wake: Mutex::new(None),
    run: Mutex::new(()),
    failures: Mutex::new(0),
});

/// How long the loop waits before its next run after `failures` failed
/// runs in a row: the usual period when all is well, otherwise ten seconds
/// doubling with each failure, up to an hour.
pub fn retry_delay(failures: u32) -> Duration {
    if failures == 0 {
        return PERIOD;
    }
    let doublings = (failures - 1).min(16);
    Duration::from_secs(10u64 << doublings).min(MAX_BACKOFF)
}

/// What a sync run that failed tells the person: the words, and whether it
/// needs them to do something about the vault.
struct Failure {
    message: String,
    attention: Option<SyncAttention>,
}

impl From<String> for Failure {
    fn from(message: String) -> Self {
        Self {
            message,
            attention: None,
        }
    }
}

/// The manifest check's verdict in plain words, when it needs the person.
fn manifest_failure(e: SyncError) -> Failure {
    let (attention, message) = match e {
        SyncError::NoVault => (
            SyncAttention::VaultMissing,
            "The vault folder is gone, or the settings file in it is. Nothing on this device is lost. Set the vault up again here, or disconnect this device.",
        ),
        SyncError::Manifest(ManifestError::NewerFormat(_)) => (
            SyncAttention::UpdateNeeded,
            "This vault was last changed by a newer version of Promptly. Update Promptly on this device to keep syncing. Everything here keeps working meanwhile.",
        ),
        SyncError::KeysChanged => (
            SyncAttention::PassphraseChanged,
            "The vault's passphrase or key was changed on another device. Type the vault's passphrase to keep syncing.",
        ),
        SyncError::DifferentVault => (
            SyncAttention::DifferentVault,
            "The vault folder now holds a different vault. Type that vault's passphrase to join it, or disconnect this device.",
        ),
        other => return other.to_string().into(),
    };
    Failure {
        message: message.into(),
        attention: Some(attention),
    }
}

/// Another device removed this one: nothing it writes counts any more.
fn removed_failure() -> Failure {
    Failure {
        message: "This device was removed from the vault on another device, so it no longer syncs. Everything on it stays here and keeps working. To sync it again, disconnect it and join the vault again.".into(),
        attention: Some(SyncAttention::Removed),
    }
}

/// The folder this device writes in the vault: the store's own id, unless
/// it was removed once and joined again as a new device.
pub fn vault_device(store: &Store) -> DeviceId {
    store
        .meta_get(META_DEVICE)
        .ok()
        .flatten()
        .and_then(|s| DeviceId::parse(&s))
        .unwrap_or_else(|| store.device_id().clone())
}

/// Whether this device's record says another device removed it.
fn is_removed(store: &Store, device: &DeviceId) -> bool {
    store
        .get(Collection::Devices, &device.as_uuid().to_string())
        .ok()
        .flatten()
        .and_then(|r| serde_json::from_str::<Device>(&r.json).ok())
        .is_some_and(|d| d.is_removed())
}

/// A vault handle writing as a new device, kept from now on, for a device
/// that was removed and is joining again.
fn as_new_device<'a>(store: &Store, vault: &Vault<'a>) -> Result<Vault<'a>, String> {
    let device = DeviceId::generate();
    store
        .meta_set(META_DEVICE, device.as_str())
        .map_err(|e| e.to_string())?;
    Ok(vault.for_device(device))
}

fn saved_kept(store: &Store) -> Result<Kept, String> {
    Ok(store
        .meta_get(META_KEPT)
        .map_err(|e| e.to_string())?
        .map(|s| policy::kept_from_json(&s))
        .unwrap_or_default())
}

fn save_kept(store: &Store, kept: &Kept) -> Result<(), String> {
    store
        .meta_set(META_KEPT, &policy::kept_to_json(kept))
        .map_err(|e| e.to_string())
}

/// What a secret's bytes are: keys announce themselves.
fn secret_kind(value: &[u8]) -> &'static str {
    if value.starts_with(b"-----BEGIN") || value.starts_with(b"PuTTY-User-Key") {
        "private_key"
    } else {
        "password"
    }
}

/// Work out what stays on this device (see [`policy`]) and give the vault
/// handle that. A record going back into the vault was tombstoned there,
/// so it is written again in full, newer than the tombstone: deleted and
/// put back at once, which changes nothing here.
fn keep_on_device<'a>(
    store: &Store,
    dek: &Dek,
    vault: Vault<'a>,
) -> Result<(Vault<'a>, KeptPlan), String> {
    let previous = saved_kept(store)?;
    let plan = store.with_state(|state| policy::plan_kept(state, &previous));
    // A host or key going back takes the passwords and keys it uses along,
    // even one saved before sync was set up, which has no record yet.
    let mut back = plan.back.clone();
    for (col, id) in &plan.back {
        let used = store.with_state(|state| {
            state
                .record(*col, id)
                .map(|r| policy::secrets_used(*col, &r.visible_fields()))
                .unwrap_or_default()
        });
        for secret in used {
            let key = (Collection::Secrets, secret);
            if !plan.kept.contains_key(&key) && !back.contains(&key) {
                back.push(key);
            }
        }
    }
    for (col, id) in &back {
        match store.get(*col, id).map_err(|e| e.to_string())? {
            // Only one that was kept here last time needs writing again.
            Some(record) if plan.back.contains(&(*col, id.clone())) => {
                store.delete(*col, id).map_err(|e| e.to_string())?;
                store
                    .put(*col, id, &record.json)
                    .map_err(|e| e.to_string())?;
                if *col == Collection::Secrets {
                    mark_secret(store, id, store.newest_ts(*col, id).as_ref())?;
                }
            }
            Some(_) => {}
            // A password kept here from the start has no record yet.
            None if *col == Collection::Secrets => {
                if let Some(value) = secrets().get(id).map_err(|e| e.to_string())? {
                    put_secret_record(store, dek, id, secret_kind(&value), &value)?;
                }
            }
            None => {}
        }
    }
    let vault = vault.with_kept(plan.kept.clone());
    Ok((vault, plan))
}

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

fn save_config(store: &Store, config: &VaultConfig) -> Result<(), String> {
    store
        .meta_set(
            META_VAULT,
            &serde_json::to_string(config).expect("config serialises"),
        )
        .map_err(|e| e.to_string())
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

/// The join code another device can enrol with (VAULT.md section 11): the
/// vault, where it is here, its data key (`dek`, base64 as kept on this
/// device) and the manifest's keys when this device last looked, as JSON.
/// The QR code shows the same text.
pub fn join_code(config: &VaultConfig, dek: &str) -> String {
    serde_json::json!({
        "v": 1,
        "vault_id": config.vault_id,
        "kind": config.kind,
        "path": config.path,
        "dek": dek,
        "keys": config.manifest_keys,
    })
    .to_string()
}

/// Open the vault in `backend`, whose manifest is `manifest`, to join it:
/// with the passphrase, the recovery code or a join code, whichever is
/// given (the first, if several).
pub fn open_to_join<'a>(
    backend: &'a dyn Backend,
    device: DeviceId,
    manifest: &Manifest,
    passphrase: Option<String>,
    recovery_code: Option<String>,
    join: Option<String>,
) -> Result<Vault<'a>, String> {
    if let Some(p) = passphrase {
        return Vault::open(backend, device, &p).map_err(|e| e.to_string());
    }
    if let Some(code) = recovery_code {
        let code = RecoveryCode::parse(&code).ok_or(
            "That is not a recovery code: expect eight groups of four letters and digits.",
        )?;
        return Vault::open_with_recovery(backend, device, &code).map_err(|e| e.to_string());
    }
    let Some(join) = join else {
        return Err("A passphrase, a recovery code or a join code is needed.".into());
    };
    const NOT_A_CODE: &str = "That is not a join code. On a device already in the vault, open Settings, Sync, Add another device, Show code, and copy the code as text.";
    let code: serde_json::Value = serde_json::from_str(join.trim()).map_err(|_| NOT_A_CODE)?;
    let field = |name: &str| code.get(name).and_then(serde_json::Value::as_str);
    let (Some(vault_id), Some(dek)) = (field("vault_id"), field("dek")) else {
        return Err(NOT_A_CODE.into());
    };
    let dek = B64
        .decode(dek)
        .ok()
        .and_then(|raw| Dek::from_slice(&raw))
        .ok_or(NOT_A_CODE)?;
    if vault_id != manifest.vault_id {
        return Err("That join code is for a different vault from the one in this folder.".into());
    }
    // A code from before a passphrase change or a new key: the key in it
    // may not open anything written since.
    if field("keys").is_some_and(|k| k != manifest.keys_fingerprint()) {
        return Err("That join code is out of date: the vault's passphrase or key has changed since it was shown. Show a new code on the other device.".into());
    }
    Ok(Vault::with_dek(
        backend,
        device,
        manifest.vault_id.clone(),
        dek,
    ))
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
            "The key for {label} needs its passphrase, which sync can't ask for. Connect to {label} in the terminal once, with Remember passphrase on."
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

fn put_device_record(store: &Store, device: &DeviceId, name: &str) -> Result<(), String> {
    let record = Device {
        id: device.as_uuid(),
        name: name.to_string(),
        platform: std::env::consts::OS.to_string(),
        enrolled_at: time::OffsetDateTime::now_utc(),
        last_seen_at: Some(time::OffsetDateTime::now_utc()),
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        removed_at: None,
        removed_after: None,
    };
    store
        .put(
            Collection::Devices,
            &record.id.to_string(),
            &serde_json::to_string(&record).expect("device serialises"),
        )
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Store the configuration and key after a successful create or join, and
/// enrol this device: its record, every local secret that may travel, and
/// a first sync. `keep_markers` is for the same vault under a new key:
/// everything read before stays read.
pub fn finish_setup(
    config: VaultConfig,
    dek: &Dek,
    vault: &Vault,
    first_snapshot: bool,
    keep_markers: bool,
) -> Result<(), String> {
    let store = store()?;
    secrets()
        .put(DEK_SECRET_ID, B64.encode(dek.0).as_bytes())
        .map_err(|e| format!("could not keep the vault key: {e}"))?;
    save_config(&store, &config)?;
    if !keep_markers {
        store.reset_sync_state().map_err(|e| e.to_string())?;
    }
    for key in [META_SECRET_MARKERS, META_KEPT] {
        store.meta_delete(key).map_err(|e| e.to_string())?;
    }
    // Removed from this vault before: join as a new device, since nothing
    // written in the old one's name counts any more.
    let mut vault = vault.clone();
    if is_removed(&store, vault.device()) {
        vault = as_new_device(&store, &vault)?;
    }
    put_device_record(&store, vault.device(), &config.device_name)?;
    // Every secret this device already has travels in the vault, except
    // those of hosts and keys kept on this device.
    let kept = store.with_state(policy::kept_on_device);
    for id in secrets().list().map_err(|e| e.to_string())? {
        if id == DEK_SECRET_ID || kept.contains(&(Collection::Secrets, id.clone())) {
            continue;
        }
        if let Some(value) = secrets().get(&id).map_err(|e| e.to_string())? {
            put_secret_record(&store, dek, &id, secret_kind(&value), &value)?;
        }
    }
    {
        let _guard = ENGINE.run.lock().unwrap();
        let (mut vault, plan) = keep_on_device(&store, dek, vault)?;
        let report = store.pull(&vault).map_err(|e| e.to_string())?;
        ENGINE.status.lock().unwrap().changes += report.ops_applied as u32;
        // The vault knew of the removal when this device did not.
        if is_removed(&store, vault.device()) {
            vault = as_new_device(&store, &vault)?;
            put_device_record(&store, vault.device(), &config.device_name)?;
        }
        apply_pulled_secrets(&store, dek)?;
        apply_pulled_known_hosts(&store)?;
        store.push(&vault).map_err(|e| e.to_string())?;
        store
            .compact(&vault, first_snapshot || plan.newly_kept)
            .map_err(|e| e.to_string())?;
        save_kept(&store, &plan.kept)?;
    }
    {
        let mut st = ENGINE.status.lock().unwrap();
        st.last_sync_at = Some(promptly_vault::ops::now_rfc3339());
        st.last_error = None;
        st.attention = None;
    }
    *ENGINE.failures.lock().unwrap() = 0;
    ensure_loop();
    emit();
    Ok(())
}

/// Encrypt a secret under the vault key and store it as a `secrets` record.
/// Whether it travels follows the host or key that uses it (see
/// [`policy`]); a record marked local only itself stays so.
pub fn put_secret_record(
    store: &Store,
    dek: &Dek,
    id: &str,
    kind: &str,
    value: &[u8],
) -> Result<(), String> {
    let aad = format!("secret/{id}");
    let ciphertext = crypto::seal(dek, aad.as_bytes(), value).map_err(|e| e.to_string())?;
    let sync = store
        .get(Collection::Secrets, id)
        .map_err(|e| e.to_string())?
        .and_then(|r| serde_json::from_str::<serde_json::Value>(&r.json).ok())
        .and_then(|v| v.get("sync")?.as_str().map(str::to_string))
        .unwrap_or_else(|| "vault".into());
    let record = serde_json::json!({
        "id": id,
        "kind": kind,
        "ciphertext": ciphertext,
        "sync": sync,
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
    let _guard = ENGINE.run.lock().unwrap();
    // Read after the lock: a key change that held it may have just saved a new one.
    let Some(config) = config()? else {
        return Err("sync is not set up".into());
    };
    {
        let mut st = ENGINE.status.lock().unwrap();
        st.syncing = true;
        st.warnings.clear();
    }
    emit();
    let result = (|| {
        let store = store()?;
        let device = vault_device(&store);
        // Removed on another device: this one's writes no longer count, so
        // it does not go near the vault at all.
        if is_removed(&store, &device) {
            return Err(removed_failure());
        }
        let dek = dek()?;
        let backend = backend_for(&config)?;
        let vault = Vault::with_dek(&*backend, device, config.vault_id.clone(), dek.clone());
        // The manifest first, every time: writing into a folder whose vault
        // is gone, newer, or locked differently now would only do harm.
        let keys = vault
            .check_manifest(config.manifest_keys.as_deref())
            .map_err(manifest_failure)?;
        let mut config = config.clone();
        if config.manifest_keys.is_none() {
            config.manifest_keys = Some(keys);
            save_config(&store, &config)?;
        }
        let (vault, plan) = keep_on_device(&store, &dek, vault)?;
        let report = store.pull(&vault).map_err(|e| e.to_string())?;
        if is_removed(&store, vault.device()) {
            return Err(removed_failure());
        }
        apply_pulled_secrets(&store, &dek)?;
        apply_pulled_known_hosts(&store)?;
        // A key change that stopped part way: lock again whatever secrets
        // are still under the old key, from this device's copies.
        if config.snapshot_due {
            reseal_secrets(&store, None, &dek)?;
        }
        store.push(&vault).map_err(|e| e.to_string())?;
        // A snapshot now when records just left the vault (it carries their
        // tombstones) or one is owed after a key change.
        let force = plan.newly_kept || config.snapshot_due;
        store.compact(&vault, force).map_err(|e| e.to_string())?;
        save_kept(&store, &plan.kept)?;
        if config.snapshot_due {
            config.snapshot_due = false;
            save_config(&store, &config)?;
        }
        Ok::<(Vec<String>, usize), Failure>((report.warnings, report.ops_applied))
    })();
    let mut st = ENGINE.status.lock().unwrap();
    st.syncing = false;
    match &result {
        Ok((warnings, applied)) => {
            st.last_sync_at = Some(promptly_vault::ops::now_rfc3339());
            st.last_error = None;
            st.attention = None;
            st.warnings.extend(warnings.iter().cloned());
            st.changes = st.changes.wrapping_add(*applied as u32);
            *ENGINE.failures.lock().unwrap() = 0;
        }
        Err(e) => {
            st.last_error = Some(e.message.clone());
            st.attention = e.attention;
            let mut failures = ENGINE.failures.lock().unwrap();
            *failures = failures.saturating_add(1);
            forget_sftp();
        }
    }
    drop(st);
    emit();
    result.map(|_| ()).map_err(|e| e.message)
}

/// A sync the person asked for: it starts the backoff over, whatever
/// happened before, and the loop takes its timing from the result.
pub fn sync_now() -> Result<(), String> {
    *ENGINE.failures.lock().unwrap() = 0;
    let result = sync_once();
    wake(Wake::Reschedule);
    result
}

/// Ask the loop for a run soon, as when the app comes to the front.
pub fn sync_soon() {
    wake(Wake::Now);
}

fn wake(w: Wake) {
    if let Some(tx) = ENGINE.wake.lock().unwrap().as_ref() {
        let _ = tx.send(w);
    }
}

/// The vault this device is set up for, opened with the key it holds.
fn current_vault<'a>(
    store: &Store,
    config: &VaultConfig,
    backend: &'a dyn Backend,
) -> Result<Vault<'a>, String> {
    Ok(Vault::with_dek(
        backend,
        vault_device(store),
        config.vault_id.clone(),
        dek()?,
    ))
}

/// After the passphrase or key changed elsewhere, or the folder took a
/// different vault: unlock what is there now with its passphrase or
/// recovery code. Same vault and key: this device carries on where it was,
/// and writes a full snapshot in case its folder was lost along the way.
/// Same vault, new key: everything is encrypted again with the new key and
/// a snapshot under it replaces this device's old files; what was read
/// before stays read. Otherwise this is joining afresh, as setup would.
pub fn unlock_again(
    passphrase: Option<String>,
    recovery_code: Option<String>,
) -> Result<(), String> {
    let Some(mut config) = config()? else {
        return Err("sync is not set up".into());
    };
    let store = store()?;
    let backend = backend_for(&config)?;
    let device = vault_device(&store);
    let manifest = Vault::read_manifest(&*backend).map_err(|e| e.to_string())?;
    let vault = match (passphrase, recovery_code) {
        (Some(p), _) => Vault::open(&*backend, device, &p).map_err(|e| e.to_string())?,
        (None, Some(code)) => {
            let code = promptly_vault::RecoveryCode::parse(&code).ok_or(
                "That is not a recovery code: expect eight groups of four letters and digits.",
            )?;
            Vault::open_with_recovery(&*backend, device, &code).map_err(|e| e.to_string())?
        }
        (None, None) => return Err("A passphrase or a recovery code is needed.".into()),
    };
    config.manifest_keys = Some(manifest.keys_fingerprint());
    config.recovery_hint = manifest.recovery_hint().map(str::to_string);
    let same_vault = vault.vault_id() == config.vault_id;
    if !same_vault || dek().ok().as_ref() != Some(vault.dek()) {
        config.vault_id = vault.vault_id().to_string();
        return finish_setup(config, vault.dek(), &vault, true, same_vault);
    }
    save_config(&store, &config)?;
    {
        let _guard = ENGINE.run.lock().unwrap();
        let dek = vault.dek().clone();
        let (vault, plan) = keep_on_device(&store, &dek, vault)?;
        // A key change here that stopped after keeping the new key: lock
        // the secrets again before the snapshot.
        if config.snapshot_due {
            reseal_secrets(&store, None, &dek)?;
        }
        store.push(&vault).map_err(|e| e.to_string())?;
        store.compact(&vault, true).map_err(|e| e.to_string())?;
        save_kept(&store, &plan.kept)?;
    }
    sync_now()
}

/// The vault folder, or its manifest, is gone: write a new manifest for the
/// same vault from the key this device holds, under `passphrase`, and a
/// full snapshot beside it, so every device can carry on. Returns the new
/// recovery code; the old one no longer opens the vault.
pub fn recreate(passphrase: &str, params: promptly_vault::KdfParams) -> Result<String, String> {
    let Some(mut config) = config()? else {
        return Err("sync is not set up".into());
    };
    let store = store()?;
    let backend = backend_for(&config)?;
    let vault = current_vault(&store, &config, &*backend)?;
    let (manifest, code) = {
        let _guard = ENGINE.run.lock().unwrap();
        // What stays on this device is settled before the manifest is
        // written, so nothing after that can stop the code being returned.
        let (vault, plan) = keep_on_device(&store, &dek()?, vault)?;
        let (manifest, code) =
            vault
                .recreate_manifest(passphrase, params)
                .map_err(|e| match e {
                    SyncError::VaultExists => {
                        "The vault is back in its folder. Sync again instead.".to_string()
                    }
                    other => other.to_string(),
                })?;
        // The new manifest is written, so from here on the code must reach
        // the person: what follows is best effort. The snapshot that brings
        // the records back stays owed until it is written, so a failure
        // here is retried, and reported, by the next sync.
        let pushed = store.push(&vault).is_ok();
        let _ = store.compact(&vault, true);
        if pushed {
            let _ = save_kept(&store, &plan.kept);
        }
        (manifest, code)
    };
    config.manifest_keys = Some(manifest.keys_fingerprint());
    config.recovery_hint = Some(code.hint());
    let _ = save_config(&store, &config);
    let _ = sync_now();
    Ok(code.as_str().to_string())
}

/// Encrypt every saved secret again under `new`, from the record (opened
/// with `old`, when there is one) or, failing that, from the copy on this
/// device. Records `new` opens already are left as they are, so this can
/// run again after stopping part way.
fn reseal_secrets(store: &Store, old: Option<&Dek>, new: &Dek) -> Result<(), String> {
    for r in store.list(Collection::Secrets).map_err(|e| e.to_string())? {
        let fields: serde_json::Value = serde_json::from_str(&r.json).map_err(|e| e.to_string())?;
        let kind = fields
            .get("kind")
            .and_then(|k| k.as_str())
            .unwrap_or("password")
            .to_string();
        let aad = format!("secret/{}", r.id);
        let ct = fields
            .get("ciphertext")
            .and_then(|v| serde_json::from_value::<Vec<u8>>(v.clone()).ok());
        let opens = |dek: &Dek| {
            ct.as_ref()
                .and_then(|ct| crypto::open(dek, aad.as_bytes(), ct).ok())
        };
        if opens(new).is_some() {
            continue;
        }
        let value = match old.and_then(opens) {
            Some(v) => Some(v),
            None => secrets().get(&r.id).map_err(|e| e.to_string())?,
        };
        match value {
            Some(v) => put_secret_record(store, new, &r.id, &kind, &v)?,
            None => ENGINE.status.lock().unwrap().warnings.push(format!(
                "secret {}: could not be read to lock it again",
                r.id
            )),
        }
    }
    Ok(())
}

/// Give the vault a new key (VAULT.md section 11), wrapped under
/// `passphrase` and a new recovery code, which is returned to show once.
/// Everything is synced first, the secrets are encrypted again, and a full
/// snapshot under the new key replaces this device's files. A device that
/// holds only the old key, a removed one included, reads nothing written
/// from now on. The other devices ask for the passphrase once.
const SAME_PASSPHRASE: &str = "Choose a passphrase the vault does not have now: whoever knows the current one could open the new key with it.";

pub fn rotate_key(passphrase: &str, params: promptly_vault::KdfParams) -> Result<String, String> {
    // Everything every device wrote, so the new snapshot leaves nothing out.
    sync_once()?;
    let Some(mut config) = config()? else {
        return Err("sync is not set up".into());
    };
    let store = store()?;
    let backend = backend_for(&config)?;
    // The passphrase it has now would hand the new key to whoever knows it.
    let current = Vault::read_manifest(&*backend).map_err(|e| e.to_string())?;
    if current.unlock(passphrase).is_ok() {
        return Err(SAME_PASSPHRASE.into());
    }
    let guard = ENGINE.run.lock().unwrap();
    let old_dek = dek()?;
    let (old, plan) = keep_on_device(&store, &old_dek, current_vault(&store, &config, &*backend)?)?;
    let known = config
        .manifest_keys
        .clone()
        .ok_or("Sync once before changing the key.")?;
    // Saved before the vault changes, so a run that stops at any point
    // after leaves the next sync, or unlock, to lock the secrets again and
    // write the snapshot. Should the key not change after all, it costs
    // only a snapshot.
    config.snapshot_due = true;
    save_config(&store, &config)?;
    let (vault, manifest, code) = old
        .rotate(&known, passphrase, params)
        .map_err(|e| match e {
            SyncError::KeysChanged => "The vault's passphrase or key was changed on another device just now. Sync, then try again.".to_string(),
            other => other.to_string(),
        })?;
    // The vault is locked with the new key from here on, so the new code
    // must reach the person whatever follows. Until the snapshot under the
    // new key is out, the next sync finishes what is left: the secrets
    // locked again from this device's copies, then the snapshot.
    let mut trouble = None;
    let mut note = |e: String| {
        trouble.get_or_insert(e);
    };
    if let Err(e) = secrets().put(DEK_SECRET_ID, B64.encode(vault.dek().0).as_bytes()) {
        // Nothing more under the old key: the next sync finds the key
        // changed and asks for the passphrase, which locks everything again.
        note(format!("The vault has a new key, but this device could not keep it ({e}). Type the passphrase on the Sync screen to unlock it again."));
    } else {
        config.manifest_keys = Some(manifest.keys_fingerprint());
        config.recovery_hint = Some(code.hint());
        if let Err(e) = save_config(&store, &config) {
            note(e);
        }
        let written = reseal_secrets(&store, Some(&old_dek), vault.dek()).and_then(|_| {
            store
                .push(&vault)
                .and_then(|_| store.compact(&vault, true))
                .map_err(|e| e.to_string())
        });
        match written {
            Ok(_) => {
                config.snapshot_due = false;
                if let Err(e) =
                    save_config(&store, &config).and_then(|_| save_kept(&store, &plan.kept))
                {
                    note(e);
                }
            }
            Err(e) => note(e),
        }
    }
    {
        let mut st = ENGINE.status.lock().unwrap();
        if trouble.is_none() {
            st.last_sync_at = Some(promptly_vault::ops::now_rfc3339());
            st.attention = None;
        }
        st.last_error = trouble;
    }
    drop(guard);
    emit();
    Ok(code.as_str().to_string())
}

/// Remove another device (VAULT.md section 11): its record is marked
/// removed, with the last of its files this device has read. Every device
/// then ignores whatever it writes after that, and it stops syncing once
/// it finds out. Its folder is tidied away by a later snapshot that holds
/// everything it had. It keeps the copy it has; [`rotate_key`] stops it
/// reading anything new.
pub fn remove_device(record_id: &str) -> Result<(), String> {
    let store = store()?;
    if config()?.is_none() {
        return Err("sync is not set up".into());
    }
    if record_id == vault_device(&store).as_uuid().to_string() {
        return Err("To remove this device, disconnect it instead.".into());
    }
    let folder = uuid::Uuid::parse_str(record_id)
        .map(|u| DeviceId::from_uuid(&u))
        .map_err(|_| "That is not one of the vault's devices.".to_string())?;
    // Everything it has written so far first: that much still counts.
    sync_once()?;
    let record = store
        .get(Collection::Devices, record_id)
        .map_err(|e| e.to_string())?
        .ok_or("That device is no longer in the vault.")?;
    let mut device: Device = serde_json::from_str(&record.json).map_err(|e| e.to_string())?;
    let after = store
        .sync_state()
        .map_err(|e| e.to_string())?
        .markers
        .get(&folder)
        .map_or(0, Marker::highest);
    device.removed_at = Some(time::OffsetDateTime::now_utc());
    device.removed_after = Some(after);
    store
        .put(
            Collection::Devices,
            record_id,
            &serde_json::to_string(&device).expect("device serialises"),
        )
        .map_err(|e| e.to_string())?;
    // Out at once, so the others stop listening to it soon. If it cannot
    // go yet, the status says so and it goes with the next sync.
    let _ = sync_once();
    Ok(())
}

/// Called after any local change to a record or secret.
pub fn notify_change() {
    wake(Wake::LocalChange);
}

/// Start the background loop if sync is set up and it is not running.
pub fn ensure_loop() {
    // Tests drive every run themselves.
    if cfg!(test) {
        return;
    }
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
                    Ok(Wake::Reschedule) => {
                        next = Instant::now() + retry_delay(*ENGINE.failures.lock().unwrap());
                        continue;
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => return,
                }
                if config().ok().flatten().is_none() {
                    // Disconnected: stop until set up again.
                    *ENGINE.wake.lock().unwrap() = None;
                    return;
                }
                // Success or failure, the count of failures in a row decides.
                let _ = sync_once();
                next = Instant::now() + retry_delay(*ENGINE.failures.lock().unwrap());
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
    store.meta_delete(META_KEPT).map_err(|e| e.to_string())?;
    store.reset_sync_state().map_err(|e| e.to_string())?;
    secrets().delete(DEK_SECRET_ID).map_err(|e| e.to_string())?;
    forget_sftp();
    // The loop notices the missing config on its next wake.
    wake(Wake::Now);
    *ENGINE.status.lock().unwrap() = Status::default();
    *ENGINE.failures.lock().unwrap() = 0;
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
    let this = vault_device(&store).as_uuid().to_string();
    let mut devices: Vec<SyncDevice> = store
        .list(Collection::Devices)
        .map_err(|e| e.to_string())?
        .into_iter()
        .filter_map(|r| serde_json::from_str::<Device>(&r.json).ok())
        .filter(|d| !d.is_removed())
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
                        vault_device(&store),
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
        attention: st.attention,
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
    use crate::api::sync::{
        sync_create_local_folder, sync_join_local_folder, sync_recreate_vault, sync_unlock,
        SyncAttention,
    };
    use promptly_vault::{
        Clock, DeviceId, KdfParams, Manifest, Marker, RecoveryCode, State, SyncState,
    };
    use serde_json::json;

    #[test]
    fn retries_back_off_from_ten_seconds_to_an_hour() {
        assert_eq!(retry_delay(0), PERIOD);
        assert_eq!(retry_delay(1), Duration::from_secs(10));
        assert_eq!(retry_delay(2), Duration::from_secs(20));
        assert_eq!(retry_delay(6), Duration::from_secs(320));
        assert_eq!(retry_delay(9), Duration::from_secs(2560));
        assert_eq!(retry_delay(10), MAX_BACKOFF);
        assert_eq!(retry_delay(u32::MAX), MAX_BACKOFF);
    }

    #[test]
    fn a_join_code_opens_its_own_vault_and_nothing_else() {
        let root = std::env::temp_dir().join(format!("promptly-join-{}", uuid::Uuid::new_v4()));
        let (here, there) = (root.join("here"), root.join("there"));
        std::fs::create_dir_all(&here).unwrap();
        std::fs::create_dir_all(&there).unwrap();
        let backend = LocalFolder::new(&here);
        let (vault, _) = Vault::create(
            &backend,
            DeviceId::generate(),
            "a long passphrase",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        let manifest = Vault::read_manifest(&backend).unwrap();
        let config = VaultConfig {
            kind: "local_folder".into(),
            path: here.to_string_lossy().into_owned(),
            vault_id: vault.vault_id().to_string(),
            device_name: "laptop".into(),
            recovery_hint: None,
            host_id: None,
            manifest_keys: Some(manifest.keys_fingerprint()),
            snapshot_due: false,
        };
        let code = join_code(&config, &B64.encode(vault.dek().0));
        let join = |code: &str, manifest: &Manifest| {
            open_to_join(
                &backend,
                DeviceId::generate(),
                manifest,
                None,
                None,
                Some(code.to_string()),
            )
        };

        let joined = join(&code, &manifest).unwrap();
        assert_eq!(joined.vault_id(), vault.vault_id());
        assert_eq!(joined.dek().0, vault.dek().0);
        // Pasted with stray spaces and a newline, it still reads.
        assert!(join(&format!("  {code}\n"), &manifest).is_ok());

        assert!(join("hello", &manifest)
            .err()
            .unwrap()
            .contains("not a join code"));
        let other_backend = LocalFolder::new(&there);
        Vault::create(
            &other_backend,
            DeviceId::generate(),
            "another passphrase",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        let other = Vault::read_manifest(&other_backend).unwrap();
        assert!(join(&code, &other)
            .err()
            .unwrap()
            .contains("different vault"));

        // After a passphrase change the code is out of date.
        let mut changed = manifest.clone();
        changed.change_passphrase(vault.dek(), "a newer passphrase");
        assert!(join(&code, &changed).err().unwrap().contains("out of date"));

        // Nothing given at all.
        assert!(open_to_join(&backend, DeviceId::generate(), &manifest, None, None, None).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_server_vault_uses_the_passphrase_saved_with_a_locked_key() {
        // No secure storage in tests: secrets are plain files.
        let _ = crate::api::store::set_no_device_key();
        let store = Store::open_in_memory().unwrap();
        let plain = promptly_ssh::generate_key(promptly_ssh::KeyKind::Ed25519, "")
            .unwrap()
            .private_openssh;
        let locked = promptly_ssh::export_key(&plain, None, Some("open sesame")).unwrap();
        let (key_id, secret_id, pass_id, host_id) = (
            uuid::Uuid::new_v4(),
            uuid::Uuid::new_v4(),
            uuid::Uuid::new_v4(),
            uuid::Uuid::new_v4(),
        );
        secrets()
            .put(&secret_id.to_string(), locked.as_bytes())
            .unwrap();
        let identity = |passphrase: Option<uuid::Uuid>| {
            json!({
                "id": key_id, "label": "laptop", "key_type": "ed25519",
                "public_key": "ssh-ed25519 AAAA", "private_key_secret_id": secret_id,
                "passphrase_secret_id": passphrase,
            })
            .to_string()
        };
        store
            .put(Collection::Identities, &key_id.to_string(), &identity(None))
            .unwrap();
        let host = json!({
            "id": host_id, "label": "nas", "hostname": "nas.local", "username": "ops",
            "auth": {"kind": "identity", "identity_id": key_id},
        });
        store
            .put(Collection::Hosts, &host_id.to_string(), &host.to_string())
            .unwrap();

        // Without its passphrase the key cannot be used unattended.
        let err = sftp_params(&store, &host_id.to_string()).unwrap_err();
        assert!(err.contains("passphrase that is not saved"), "{err}");

        secrets().put(&pass_id.to_string(), b"open sesame").unwrap();
        store
            .put(
                Collection::Identities,
                &key_id.to_string(),
                &identity(Some(pass_id)),
            )
            .unwrap();
        let (params, label) = sftp_params(&store, &host_id.to_string()).unwrap();
        assert_eq!(label, "nas");
        match &params.auth {
            promptly_ssh::AuthMethod::Key {
                private_key,
                passphrase,
            } => {
                assert_eq!(*private_key, locked);
                assert_eq!(passphrase.as_deref(), Some("open sesame"));
            }
            other => panic!("expected a key login, got {other:?}"),
        }
        for id in [secret_id, pass_id] {
            secrets().delete(&id.to_string()).unwrap();
        }
    }

    /// The one test here that uses the app's store, which lives for the
    /// whole process (in a folder of the tests' own): it walks through
    /// every problem in turn.
    #[test]
    fn every_sync_checks_the_manifest_and_each_problem_has_a_way_out() {
        // No secure storage in tests: the database opens without a key.
        let _ = crate::api::store::set_no_device_key();
        let root = std::env::temp_dir().join(format!("promptly-api-sync-{}", uuid::Uuid::new_v4()));
        std::env::set_var("PROMPTLY_FAST_KDF", "1");
        let folder = root.join("vault");
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.to_string_lossy().into_owned();
        let setup =
            sync_create_local_folder(path.clone(), "first passphrase".into(), "Test box".into())
                .unwrap();
        let store = store().unwrap();
        let attention = || status().unwrap().attention;
        let failures = || *ENGINE.failures.lock().unwrap();
        let snippet = |id: &str| {
            let json = format!(r#"{{"id":"{id}","label":"{id}","command":"ls"}}"#);
            store.put(Collection::Snippets, id, &json).unwrap();
        };
        sync_once().unwrap();
        assert_eq!(attention(), None);
        assert!(config().unwrap().unwrap().manifest_keys.is_some());
        let backend = LocalFolder::new(&folder);
        let write_manifest = |json: &str| std::fs::write(folder.join("vault.json"), json).unwrap();

        // Another device changes the passphrase: nothing is written until
        // this one has the new passphrase.
        let mut manifest: Manifest = Vault::read_manifest(&backend).unwrap();
        manifest.change_passphrase(&dek().unwrap(), "second passphrase");
        write_manifest(&manifest.to_json());
        snippet("s1");
        assert!(sync_once().is_err());
        assert_eq!(attention(), Some(SyncAttention::PassphraseChanged));
        assert!(store.pending_count().unwrap() > 0, "held back");
        assert!(sync_once().is_err());
        assert_eq!(failures(), 2, "each failed run counts towards the backoff");
        let wrong = sync_unlock(Some("first passphrase".into()), None).unwrap_err();
        assert!(wrong.contains("wrong"), "{wrong}");
        sync_unlock(Some("second passphrase".into()), None).unwrap();
        assert_eq!(attention(), None);
        assert_eq!(store.pending_count().unwrap(), 0);
        assert_eq!(failures(), 0);
        assert_eq!(config().unwrap().unwrap().vault_id, setup.vault_id);

        // A newer Promptly changed the format.
        write_manifest(
            &manifest
                .to_json()
                .replace(r#""format": 1"#, r#""format": 2"#),
        );
        assert!(sync_once().is_err());
        assert_eq!(attention(), Some(SyncAttention::UpdateNeeded));
        write_manifest(&manifest.to_json());
        sync_now().unwrap();
        assert_eq!(attention(), None);

        // The whole vault folder is deleted. It is not quietly made again
        // without its settings file; setting it up again keeps everything.
        std::fs::remove_dir_all(&folder).unwrap();
        snippet("s2");
        assert!(sync_once().is_err());
        assert_eq!(attention(), Some(SyncAttention::VaultMissing));
        assert!(!folder.exists());
        assert!(sync_recreate_vault("short".into()).is_err());
        let again = sync_recreate_vault("third passphrase".into()).unwrap();
        assert_eq!(again.vault_id, setup.vault_id, "the same vault");
        assert_eq!(attention(), None);
        // What a brand new device reading the vault with `vault` gets.
        let listed = |vault: &Vault, col: Collection| {
            let (mut sync, mut state) = (SyncState::default(), State::new());
            let mut clock = Clock::new(DeviceId::generate());
            vault.pull(&mut sync, &mut state, &mut clock).unwrap();
            state
                .list(col)
                .into_iter()
                .map(|(id, _)| id)
                .collect::<Vec<_>>()
        };
        let fresh = |vault: &Vault| listed(vault, Collection::Snippets);
        let code = RecoveryCode::parse(&again.recovery_code).unwrap();
        let joiner = Vault::open_with_recovery(&backend, DeviceId::generate(), &code).unwrap();
        assert_eq!(fresh(&joiner), ["s1", "s2"], "a new device gets everything");
        let old = RecoveryCode::parse(&setup.recovery_code).unwrap();
        assert!(Vault::open_with_recovery(&backend, DeviceId::generate(), &old).is_err());

        // Someone makes a different vault in its place.
        std::fs::remove_dir_all(&folder).unwrap();
        Vault::create(
            &backend,
            DeviceId::generate(),
            "other passphrase",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        assert!(sync_once().is_err());
        assert_eq!(attention(), Some(SyncAttention::DifferentVault));
        sync_unlock(Some("other passphrase".into()), None).unwrap();
        assert_eq!(attention(), None);
        assert_ne!(config().unwrap().unwrap().vault_id, setup.vault_id);
        let other = Vault::open(&backend, DeviceId::generate(), "other passphrase").unwrap();
        assert_eq!(fresh(&other), ["s1", "s2"], "this device's records went in");

        // A host kept on this device never reaches the vault. Switched to
        // this device only, it leaves the vault but stays here; switched
        // back, it is there again in full.
        let host = |id: &str, sync: &str| {
            let json = json!({"id": id, "label": id, "hostname": "h", "sync": sync});
            store.put(Collection::Hosts, id, &json.to_string()).unwrap();
        };
        host("h1", "vault");
        host("h2", "local_only");
        sync_once().unwrap();
        assert_eq!(listed(&other, Collection::Hosts), ["h1"]);
        host("h1", "local_only");
        sync_once().unwrap();
        assert!(listed(&other, Collection::Hosts).is_empty());
        assert!(store.get(Collection::Hosts, "h1").unwrap().is_some());
        host("h1", "vault");
        sync_once().unwrap();
        assert_eq!(listed(&other, Collection::Hosts), ["h1"]);

        // A password saved here before sync was set up has no record of
        // its own; when its host goes into the vault, it goes too.
        let secret_in = |vault: &Vault, id: &str| -> Option<Vec<u8>> {
            let (mut sync, mut state) = (SyncState::default(), State::new());
            let mut clock = Clock::new(DeviceId::generate());
            vault.pull(&mut sync, &mut state, &mut clock).unwrap();
            let (_, fields) = state
                .list(Collection::Secrets)
                .into_iter()
                .find(|(i, _)| i == id)?;
            let ct: Vec<u8> = serde_json::from_value(fields.get("ciphertext")?.clone()).ok()?;
            crypto::open(vault.dek(), format!("secret/{id}").as_bytes(), &ct).ok()
        };
        let pw = "0192f3a0-0000-7000-8000-0000000000a1";
        secrets().put(pw, b"hunter2").unwrap();
        let with_password = |sync: &str| {
            let json = json!({"id": "h3", "label": "h3", "hostname": "h", "sync": sync,
                "auth": {"kind": "password", "password_secret_id": pw}});
            store
                .put(Collection::Hosts, "h3", &json.to_string())
                .unwrap();
        };
        with_password("local_only");
        sync_once().unwrap();
        assert_eq!(secret_in(&other, pw), None);
        with_password("vault");
        sync_once().unwrap();
        assert_eq!(listed(&other, Collection::Hosts), ["h1", "h3"]);
        assert_eq!(secret_in(&other, pw).as_deref(), Some(&b"hunter2"[..]));

        // Another device, a phone, joins; then this one removes it. What
        // it wrote before counts, nothing after does.
        let vault_id = config().unwrap().unwrap().vault_id;
        let other_device = |name: &str| {
            let s = Store::open(&root.join(format!("{name}.db")), None).unwrap();
            let id = s.device_id().as_uuid().to_string();
            let record = json!({"id": id, "name": name, "platform": "ios",
                "enrolled_at": "2026-01-01T00:00:00Z"});
            s.put(Collection::Devices, &id, &record.to_string())
                .unwrap();
            s
        };
        let phone = other_device("phone");
        let phone_vault = Vault::with_dek(
            &backend,
            phone.device_id().clone(),
            vault_id.clone(),
            dek().unwrap(),
        );
        let phone_id = phone.device_id().as_uuid().to_string();
        let put_snippet = |s: &Store, id: &str| {
            let json = json!({"id": id, "label": id, "command": "ls"});
            s.put(Collection::Snippets, id, &json.to_string()).unwrap();
        };
        put_snippet(&phone, "p1");
        phone.push(&phone_vault).unwrap();
        sync_once().unwrap();
        let listed_devices = || {
            status()
                .unwrap()
                .devices
                .into_iter()
                .map(|d| d.id)
                .collect::<Vec<_>>()
        };
        assert!(listed_devices().contains(&phone_id));
        let me = vault_device(&store);
        assert!(remove_device(&me.as_uuid().to_string()).is_err());
        remove_device(&phone_id).unwrap();
        assert!(!listed_devices().contains(&phone_id));
        phone.pull(&phone_vault).unwrap();
        put_snippet(&phone, "p2");
        phone.push(&phone_vault).unwrap();
        sync_once().unwrap();
        assert!(store.get(Collection::Snippets, "p1").unwrap().is_some());
        assert!(store.get(Collection::Snippets, "p2").unwrap().is_none());

        // A laptop removes this device. It stops syncing and says why;
        // everything stays here, and joining again makes it a new device.
        let laptop = other_device("laptop");
        let laptop_vault = Vault::with_dek(
            &backend,
            laptop.device_id().clone(),
            vault_id.clone(),
            dek().unwrap(),
        );
        laptop.pull(&laptop_vault).unwrap();
        let my_id = me.as_uuid().to_string();
        let mut record: serde_json::Value = serde_json::from_str(
            &laptop
                .get(Collection::Devices, &my_id)
                .unwrap()
                .unwrap()
                .json,
        )
        .unwrap();
        record["removed_at"] = json!("2026-02-01T00:00:00Z");
        record["removed_after"] = json!(laptop
            .sync_state()
            .unwrap()
            .markers
            .get(&me)
            .map_or(0, Marker::highest));
        laptop
            .put(Collection::Devices, &my_id, &record.to_string())
            .unwrap();
        laptop.push(&laptop_vault).unwrap();
        snippet("s3");
        assert!(sync_once().is_err());
        assert_eq!(attention(), Some(SyncAttention::Removed));
        assert!(sync_once().is_err(), "it stays stopped");
        assert!(store.get(Collection::Snippets, "s3").unwrap().is_some());
        disconnect().unwrap();
        sync_join_local_folder(
            path.clone(),
            Some("other passphrase".into()),
            None,
            None,
            "Test box".into(),
        )
        .unwrap();
        assert_ne!(vault_device(&store), me);
        assert_eq!(attention(), None);
        assert_eq!(fresh(&other), ["p1", "s1", "s2", "s3"]);

        // This device gives the vault a new key: the old key and
        // passphrase open nothing new; the new ones open everything.
        let old_keys = config().unwrap().unwrap().manifest_keys.unwrap();
        assert_eq!(
            rotate_key("other passphrase", KdfParams::fast_for_tests()).unwrap_err(),
            SAME_PASSPHRASE
        );
        let code = rotate_key("fourth passphrase", KdfParams::fast_for_tests()).unwrap();
        assert_eq!(attention(), None);
        assert!(Vault::open(&backend, DeviceId::generate(), "other passphrase").is_err());
        assert!(matches!(
            phone_vault.check_manifest(Some(&old_keys)),
            Err(SyncError::KeysChanged)
        ));
        let rotated = Vault::open(&backend, DeviceId::generate(), "fourth passphrase").unwrap();
        assert_ne!(rotated.dek(), other.dek());
        assert_eq!(fresh(&rotated), ["p1", "s1", "s2", "s3"]);
        let by_code = Vault::open_with_recovery(
            &backend,
            DeviceId::generate(),
            &RecoveryCode::parse(&code).unwrap(),
        )
        .unwrap();
        assert_eq!(by_code.dek(), rotated.dek());
        let mine = |dir: &DeviceId| backend.list(&format!("devices/{dir}")).unwrap();
        let only_snapshots = |dir: &DeviceId| mine(dir).iter().all(|e| e.name.ends_with(".snap"));
        assert!(only_snapshots(&vault_device(&store)));
        assert_eq!(secret_in(&rotated, pw).as_deref(), Some(&b"hunter2"[..]));

        // A key change that stopped before every secret was locked again:
        // the next sync finishes it, then writes the snapshot it owes.
        let stale =
            crypto::seal(other.dek(), format!("secret/{pw}").as_bytes(), b"hunter2").unwrap();
        let record = json!({"id": pw, "kind": "password", "ciphertext": stale, "sync": "vault"});
        store
            .put(Collection::Secrets, pw, &record.to_string())
            .unwrap();
        let mut owed = config().unwrap().unwrap();
        owed.snapshot_due = true;
        save_config(&store, &owed).unwrap();
        sync_once().unwrap();
        assert_eq!(secret_in(&rotated, pw).as_deref(), Some(&b"hunter2"[..]));
        assert!(!config().unwrap().unwrap().snapshot_due);

        // Then the laptop gives it another: this device asks for the
        // passphrase, and with it carries on under the newest key.
        let laptop_vault =
            Vault::open(&backend, laptop.device_id().clone(), "fourth passphrase").unwrap();
        laptop.pull(&laptop_vault).unwrap();
        let known = laptop_vault.check_manifest(None).unwrap();
        let (laptop_vault, _, _) = laptop_vault
            .rotate(&known, "fifth passphrase", KdfParams::fast_for_tests())
            .unwrap();
        laptop.compact(&laptop_vault, true).unwrap();
        snippet("s4");
        assert!(sync_once().is_err());
        assert_eq!(attention(), Some(SyncAttention::PassphraseChanged));
        sync_unlock(Some("fifth passphrase".into()), None).unwrap();
        assert_eq!(attention(), None);
        assert_eq!(&dek().unwrap(), laptop_vault.dek());
        assert!(only_snapshots(&vault_device(&store)));
        assert_eq!(fresh(&laptop_vault), ["p1", "s1", "s2", "s3", "s4"]);

        // A key change here that stopped after keeping the new key, before
        // its settings were saved: unlocking with the new passphrase locks
        // the secrets again and writes the snapshot.
        let before = config().unwrap().unwrap();
        let mut owed = before.clone();
        owed.snapshot_due = true;
        save_config(&store, &owed).unwrap();
        let current = Vault::with_dek(
            &backend,
            vault_device(&store),
            before.vault_id.clone(),
            dek().unwrap(),
        );
        let (newer, _, _) = current
            .rotate(
                before.manifest_keys.as_deref().unwrap(),
                "sixth passphrase",
                KdfParams::fast_for_tests(),
            )
            .unwrap();
        secrets()
            .put(DEK_SECRET_ID, B64.encode(newer.dek().0).as_bytes())
            .unwrap();
        assert!(sync_once().is_err());
        assert_eq!(attention(), Some(SyncAttention::PassphraseChanged));
        sync_unlock(Some("sixth passphrase".into()), None).unwrap();
        assert_eq!(attention(), None);
        let reader = Vault::open(&backend, DeviceId::generate(), "sixth passphrase").unwrap();
        assert_eq!(secret_in(&reader, pw).as_deref(), Some(&b"hunter2"[..]));
        assert!(!config().unwrap().unwrap().snapshot_due);

        let _ = std::fs::remove_dir_all(&root);
    }

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
