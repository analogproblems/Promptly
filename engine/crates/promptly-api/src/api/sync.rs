//! Sync for the app: set a vault up, keep it in step, show what is going on.
//!
//! Setting up takes a moment (the passphrase is stretched with Argon2id),
//! so those calls are asynchronous; the rest answer at once.

use flutter_rust_bridge::frb;
use promptly_vault::{KdfParams, RecoveryCode, Vault};

use crate::frb_generated::StreamSink;
use crate::sync_engine::{self, VaultConfig};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum SyncBackendKind {
    LocalFolder,
    Sftp,
}

pub struct SyncDevice {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub enrolled_at: String,
    pub last_seen_at: Option<String>,
    pub is_this_device: bool,
}

pub struct SyncStatus {
    pub configured: bool,
    pub kind: Option<SyncBackendKind>,
    /// The folder path, or the host for SFTP.
    pub location: Option<String>,
    pub vault_id: Option<String>,
    pub device_id: String,
    pub device_name: String,
    pub syncing: bool,
    pub last_sync_at: Option<String>,
    pub last_error: Option<String>,
    pub warnings: Vec<String>,
    pub pending_ops: u32,
    pub devices: Vec<SyncDevice>,
    pub vault_bytes: u32,
    pub recovery_hint: Option<String>,
    /// Grows whenever other devices' changes land; reload lists when it moves.
    pub changes: u32,
}

pub struct SyncSetupResult {
    pub vault_id: String,
    /// Shown once; never stored by Promptly.
    pub recovery_code: String,
}

#[frb(sync)]
pub fn sync_status() -> Result<SyncStatus, String> {
    sync_engine::status()
}

/// Status after every sync run and every change to the setup.
pub fn sync_events(sink: StreamSink<SyncStatus>) -> anyhow::Result<()> {
    sync_engine::set_sink(sink);
    sync_engine::emit();
    Ok(())
}

/// Whether a folder already holds a vault, so setup can offer to join it.
#[frb(sync)]
pub fn sync_folder_has_vault(path: String) -> bool {
    Vault::read_manifest(&promptly_vault::LocalFolder::new(&path)).is_ok()
}

/// A default name for this device, from the machine's hostname.
#[frb(sync)]
pub fn sync_default_device_name() -> String {
    let host = std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .or_else(|| std::env::var("COMPUTERNAME").ok())
        .unwrap_or_default();
    let os = match std::env::consts::OS {
        "linux" => "Linux",
        "windows" => "Windows",
        "macos" => "Mac",
        "android" => "Android",
        "ios" => "iPhone",
        other => other,
    };
    if host.is_empty() {
        format!("{os} device")
    } else {
        format!("{host} ({os})")
    }
}

fn kdf() -> KdfParams {
    if std::env::var_os("PROMPTLY_FAST_KDF").is_some() {
        KdfParams::fast_for_tests()
    } else {
        KdfParams::default()
    }
}

/// Create a new vault in an empty folder and enrol this device.
pub fn sync_create_local_folder(
    path: String,
    passphrase: String,
    device_name: String,
) -> Result<SyncSetupResult, String> {
    if passphrase.chars().count() < 8 {
        return Err("Use a passphrase of at least eight characters.".into());
    }
    let store = crate::api::store::store()?;
    let backend = promptly_vault::LocalFolder::new(&path);
    let (vault, recovery) = Vault::create(&backend, store.device_id().clone(), &passphrase, kdf())
        .map_err(|e| e.to_string())?;
    let config = VaultConfig {
        kind: "local_folder".into(),
        path,
        vault_id: vault.vault_id().to_string(),
        device_name,
        recovery_hint: Some(recovery.hint()),
        host_id: None,
    };
    sync_engine::finish_setup(config, vault.dek(), &vault, true)?;
    Ok(SyncSetupResult {
        vault_id: vault.vault_id().to_string(),
        recovery_code: recovery.as_str().to_string(),
    })
}

/// Join a vault that already exists in a folder, with its passphrase or
/// its recovery code (either one, whichever is given).
pub fn sync_join_local_folder(
    path: String,
    passphrase: Option<String>,
    recovery_code: Option<String>,
    device_name: String,
) -> Result<(), String> {
    let store = crate::api::store::store()?;
    let backend = promptly_vault::LocalFolder::new(&path);
    let device = store.device_id().clone();
    let manifest = Vault::read_manifest(&backend).map_err(|e| e.to_string())?;
    let vault = match (passphrase, recovery_code) {
        (Some(p), _) => Vault::open(&backend, device, &p).map_err(|e| e.to_string())?,
        (None, Some(code)) => {
            let code = RecoveryCode::parse(&code).ok_or(
                "That is not a recovery code: expect eight groups of four letters and digits.",
            )?;
            Vault::open_with_recovery(&backend, device, &code).map_err(|e| e.to_string())?
        }
        (None, None) => return Err("A passphrase or a recovery code is needed.".into()),
    };
    let config = VaultConfig {
        kind: "local_folder".into(),
        path,
        vault_id: vault.vault_id().to_string(),
        device_name,
        recovery_hint: manifest.recovery_hint().map(str::to_string),
        host_id: None,
    };
    sync_engine::finish_setup(config, vault.dek(), &vault, true)
}

/// Whether a folder on a saved host already holds a vault. Connects, so
/// this takes a moment and can fail like any connection.
pub fn sync_sftp_folder_has_vault(host_id: String, remote_dir: String) -> Result<bool, String> {
    let backend = sync_engine::connect_sftp(&host_id, &remote_dir)?;
    Ok(Vault::read_manifest(&*backend).is_ok())
}

/// Create a new vault in a folder on a saved host, over SFTP, and enrol
/// this device. The host must have a stored password or key and a trusted
/// host key.
pub fn sync_create_sftp(
    host_id: String,
    remote_dir: String,
    passphrase: String,
    device_name: String,
) -> Result<SyncSetupResult, String> {
    if passphrase.chars().count() < 8 {
        return Err("Use a passphrase of at least eight characters.".into());
    }
    let store = crate::api::store::store()?;
    let backend = sync_engine::connect_sftp(&host_id, &remote_dir)?;
    let (vault, recovery) = Vault::create(&*backend, store.device_id().clone(), &passphrase, kdf())
        .map_err(|e| e.to_string())?;
    let config = VaultConfig {
        kind: "sftp".into(),
        path: remote_dir,
        vault_id: vault.vault_id().to_string(),
        device_name,
        recovery_hint: Some(recovery.hint()),
        host_id: Some(host_id),
    };
    sync_engine::finish_setup(config, vault.dek(), &vault, true)?;
    Ok(SyncSetupResult {
        vault_id: vault.vault_id().to_string(),
        recovery_code: recovery.as_str().to_string(),
    })
}

/// Join a vault that already exists on a saved host.
pub fn sync_join_sftp(
    host_id: String,
    remote_dir: String,
    passphrase: Option<String>,
    recovery_code: Option<String>,
    device_name: String,
) -> Result<(), String> {
    let store = crate::api::store::store()?;
    let backend = sync_engine::connect_sftp(&host_id, &remote_dir)?;
    let device = store.device_id().clone();
    let manifest = Vault::read_manifest(&*backend).map_err(|e| e.to_string())?;
    let vault = match (passphrase, recovery_code) {
        (Some(p), _) => Vault::open(&*backend, device, &p).map_err(|e| e.to_string())?,
        (None, Some(code)) => {
            let code = RecoveryCode::parse(&code).ok_or(
                "That is not a recovery code: expect eight groups of four letters and digits.",
            )?;
            Vault::open_with_recovery(&*backend, device, &code).map_err(|e| e.to_string())?
        }
        (None, None) => return Err("A passphrase or a recovery code is needed.".into()),
    };
    let config = VaultConfig {
        kind: "sftp".into(),
        path: remote_dir,
        vault_id: vault.vault_id().to_string(),
        device_name,
        recovery_hint: manifest.recovery_hint().map(str::to_string),
        host_id: Some(host_id),
    };
    sync_engine::finish_setup(config, vault.dek(), &vault, true)
}

/// Pull, push and compact now. Returns the status afterwards.
pub fn sync_now() -> Result<SyncStatus, String> {
    sync_engine::sync_once()?;
    sync_engine::status()
}

/// Forget the vault on this device. Everything stays usable locally.
#[frb(sync)]
pub fn sync_disconnect() -> Result<(), String> {
    sync_engine::disconnect()
}

/// Remove another device: its record goes, a snapshot of ours is written
/// so nothing of its is lost, and its folder is deleted.
pub fn sync_remove_device(device_record_id: String) -> Result<(), String> {
    let store = crate::api::store::store()?;
    let Some(config) = sync_engine::config()? else {
        return Err("sync is not set up".into());
    };
    if device_record_id == store.device_id().as_uuid().to_string() {
        return Err("To remove this device, disconnect it instead.".into());
    }
    store
        .delete(promptly_store::Collection::Devices, &device_record_id)
        .map_err(|e| e.to_string())?;
    sync_engine::sync_once()?;
    let dek = {
        let bytes = crate::api::store::secrets()
            .get(sync_engine::DEK_SECRET_ID)
            .map_err(|e| e.to_string())?
            .ok_or("the vault key is missing")?;
        use base64::Engine;
        let raw = base64::engine::general_purpose::STANDARD
            .decode(bytes)
            .map_err(|e| e.to_string())?;
        promptly_vault::Dek::from_slice(&raw).ok_or("the vault key is not valid")?
    };
    let backend = sync_engine::backend_for(&config)?;
    let vault = Vault::with_dek(
        &*backend,
        store.device_id().clone(),
        config.vault_id.clone(),
        dek,
    );
    store.compact(&vault, true).map_err(|e| e.to_string())?;
    let folder = uuid::Uuid::parse_str(&device_record_id)
        .map(|u| {
            u.as_bytes()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        })
        .ok()
        .and_then(|hex| promptly_vault::DeviceId::parse(&hex));
    if let Some(other) = folder {
        vault
            .delete_device_folder(&other)
            .map_err(|e| e.to_string())?;
    }
    sync_engine::emit();
    Ok(())
}

/// What a QR code for enrolling another device carries, as JSON, or
/// `None` when sync is not set up. Whoever reads it can read the vault.
#[frb(sync)]
pub fn sync_qr_payload() -> Result<Option<String>, String> {
    let Some(config) = sync_engine::config()? else {
        return Ok(None);
    };
    let bytes = crate::api::store::secrets()
        .get(sync_engine::DEK_SECRET_ID)
        .map_err(|e| e.to_string())?
        .ok_or("the vault key is missing")?;
    let dek = String::from_utf8(bytes).map_err(|_| "the vault key is not valid")?;
    Ok(Some(
        serde_json::json!({
            "v": 1,
            "vault_id": config.vault_id,
            "kind": config.kind,
            "path": config.path,
            "dek": dek,
        })
        .to_string(),
    ))
}
