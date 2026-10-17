//! Sync for the app: set a vault up, keep it in step, show what is going on.
//!
//! Setting up takes a moment (the passphrase is stretched with Argon2id),
//! so those calls are asynchronous; the rest answer at once.

use flutter_rust_bridge::frb;
use promptly_vault::{KdfParams, Vault};

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

/// Something about the vault itself that another try will not fix: the
/// person has to do something, and the sync screen says what.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncAttention {
    /// The vault was last changed by a newer Promptly: update this one.
    UpdateNeeded,
    /// The passphrase was changed on another device: type the new one.
    PassphraseChanged,
    /// The vault folder, or its settings file, is gone: set it up again
    /// here from this device's copy, or disconnect.
    VaultMissing,
    /// The folder now holds another vault: join it, or disconnect.
    DifferentVault,
    /// Another device removed this one, so nothing it writes counts:
    /// disconnect, and join again to sync here once more.
    Removed,
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
    /// Set alongside `last_error` when the person has to act.
    pub attention: Option<SyncAttention>,
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

/// How easy a new passphrase would be to guess, for the meter under the
/// field. Setting a vault up refuses one that is not `allowed`, with the
/// same advice.
pub struct PassphraseCheck {
    /// 0, refused, to 3, strong.
    pub level: u8,
    pub allowed: bool,
    /// What to say about it, in plain words.
    pub advice: String,
}

#[frb(sync)]
pub fn sync_passphrase_check(passphrase: String) -> PassphraseCheck {
    let a = promptly_vault::passphrase::assess(&passphrase);
    PassphraseCheck {
        level: a.strength as u8,
        allowed: a.allowed(),
        advice: a.advice.into(),
    }
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
    match Vault::read_manifest(&promptly_vault::LocalFolder::new(&path)) {
        Ok(_) => true,
        // iCloud has the manifest but has not downloaded it yet: joining
        // waits for it, where creating would fail.
        Err(promptly_vault::SyncError::Backend(promptly_vault::BackendError::NotDownloaded(_))) => {
            true
        }
        Err(_) => false,
    }
}

/// The fingerprint of the keys in a vault just made, so the next sync can
/// tell a passphrase change elsewhere from none.
fn keys_of(backend: &dyn promptly_vault::Backend) -> Option<String> {
    Vault::read_manifest(backend)
        .ok()
        .map(|m| m.keys_fingerprint())
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
    // Development builds only: a release app always stretches properly,
    // whatever its environment says.
    if cfg!(debug_assertions) && std::env::var_os("PROMPTLY_FAST_KDF").is_some() {
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
    promptly_vault::passphrase::check(&passphrase)?;
    let store = crate::api::store::store()?;
    let backend = promptly_vault::LocalFolder::new(&path);
    let (vault, recovery) = Vault::create(
        &backend,
        sync_engine::vault_device(&store),
        &passphrase,
        kdf(),
    )
    .map_err(|e| e.to_string())?;
    let manifest_keys = keys_of(&backend);
    let config = VaultConfig {
        kind: "local_folder".into(),
        path,
        vault_id: vault.vault_id().to_string(),
        device_name,
        recovery_hint: Some(recovery.hint()),
        host_id: None,
        manifest_keys,
        snapshot_due: false,
    };
    sync_engine::finish_setup(config, vault.dek(), &vault, true, false)?;
    Ok(SyncSetupResult {
        vault_id: vault.vault_id().to_string(),
        recovery_code: recovery.as_str().to_string(),
    })
}

/// Join a vault that already exists in a folder, with its passphrase, its
/// recovery code, or a join code shown on a device already in it (the
/// text of the QR code). Whichever one is given; the first, if several.
pub fn sync_join_local_folder(
    path: String,
    passphrase: Option<String>,
    recovery_code: Option<String>,
    join_code: Option<String>,
    device_name: String,
) -> Result<(), String> {
    let store = crate::api::store::store()?;
    let backend = promptly_vault::LocalFolder::new(&path);
    let device = sync_engine::vault_device(&store);
    let manifest = Vault::read_manifest(&backend).map_err(|e| e.to_string())?;
    let vault = sync_engine::open_to_join(
        &backend,
        device,
        &manifest,
        passphrase,
        recovery_code,
        join_code,
    )?;
    let manifest_keys = Some(manifest.keys_fingerprint());
    let config = VaultConfig {
        kind: "local_folder".into(),
        path,
        vault_id: vault.vault_id().to_string(),
        device_name,
        recovery_hint: manifest.recovery_hint().map(str::to_string),
        host_id: None,
        manifest_keys,
        snapshot_due: false,
    };
    sync_engine::finish_setup(config, vault.dek(), &vault, true, false)
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
    promptly_vault::passphrase::check(&passphrase)?;
    let store = crate::api::store::store()?;
    let backend = sync_engine::connect_sftp(&host_id, &remote_dir)?;
    let (vault, recovery) = Vault::create(
        &*backend,
        sync_engine::vault_device(&store),
        &passphrase,
        kdf(),
    )
    .map_err(|e| e.to_string())?;
    let manifest_keys = keys_of(&*backend);
    let config = VaultConfig {
        kind: "sftp".into(),
        path: remote_dir,
        vault_id: vault.vault_id().to_string(),
        device_name,
        recovery_hint: Some(recovery.hint()),
        host_id: Some(host_id),
        manifest_keys,
        snapshot_due: false,
    };
    sync_engine::finish_setup(config, vault.dek(), &vault, true, false)?;
    Ok(SyncSetupResult {
        vault_id: vault.vault_id().to_string(),
        recovery_code: recovery.as_str().to_string(),
    })
}

/// Join a vault that already exists on a saved host, as
/// [`sync_join_local_folder`] does.
pub fn sync_join_sftp(
    host_id: String,
    remote_dir: String,
    passphrase: Option<String>,
    recovery_code: Option<String>,
    join_code: Option<String>,
    device_name: String,
) -> Result<(), String> {
    let store = crate::api::store::store()?;
    let backend = sync_engine::connect_sftp(&host_id, &remote_dir)?;
    let device = sync_engine::vault_device(&store);
    let manifest = Vault::read_manifest(&*backend).map_err(|e| e.to_string())?;
    let vault = sync_engine::open_to_join(
        &*backend,
        device,
        &manifest,
        passphrase,
        recovery_code,
        join_code,
    )?;
    let manifest_keys = Some(manifest.keys_fingerprint());
    let config = VaultConfig {
        kind: "sftp".into(),
        path: remote_dir,
        vault_id: vault.vault_id().to_string(),
        device_name,
        recovery_hint: manifest.recovery_hint().map(str::to_string),
        host_id: Some(host_id),
        manifest_keys,
        snapshot_due: false,
    };
    sync_engine::finish_setup(config, vault.dek(), &vault, true, false)
}

/// Pull, push and compact now, as the person asked (the Sync now button,
/// pull to refresh): a failure before this no longer delays the next try.
/// Returns the status afterwards.
pub fn sync_now() -> Result<SyncStatus, String> {
    sync_engine::sync_now()?;
    sync_engine::status()
}

/// Sync soon in the background, as when the app comes to the front. Does
/// nothing when sync is not set up.
#[frb(sync)]
pub fn sync_wake() {
    sync_engine::sync_soon();
}

/// Unlock the vault again after its passphrase was changed on another
/// device, or join the vault that is in its folder now, with the
/// passphrase or the recovery code (either one, whichever is given).
pub fn sync_unlock(
    passphrase: Option<String>,
    recovery_code: Option<String>,
) -> Result<(), String> {
    sync_engine::unlock_again(passphrase, recovery_code)
}

/// Set the vault up again in its place after its folder was deleted, from
/// everything on this device, keeping the same vault so the other devices
/// carry on once they have the new passphrase. Returns the new recovery
/// code, shown once; the old one stops working.
pub fn sync_recreate_vault(passphrase: String) -> Result<SyncSetupResult, String> {
    promptly_vault::passphrase::check(&passphrase)?;
    let code = sync_engine::recreate(&passphrase, kdf())?;
    Ok(SyncSetupResult {
        // Not a reason to lose the code, which the vault already needs.
        vault_id: sync_engine::config()
            .ok()
            .flatten()
            .map(|c| c.vault_id)
            .unwrap_or_default(),
        recovery_code: code,
    })
}

/// Forget the vault on this device. Everything stays usable locally.
#[frb(sync)]
pub fn sync_disconnect() -> Result<(), String> {
    sync_engine::disconnect()
}

/// Remove another device. It is marked removed, so every device ignores
/// what it writes from now on and it stops syncing once it finds out; its
/// folder in the vault is tidied away later. It keeps the copy of the
/// vault it has: re-key the vault too if it was lost or stolen.
pub fn sync_remove_device(device_record_id: String) -> Result<(), String> {
    sync_engine::remove_device(&device_record_id)
}

/// Re-key the vault: a new key, locked with `passphrase` and a new
/// recovery code (returned, shown once; the old code stops working).
/// Removed devices, and anyone else with only the old key, can read
/// nothing written from now on. The other devices ask for the passphrase
/// once.
pub fn sync_rotate_key(passphrase: String) -> Result<SyncSetupResult, String> {
    promptly_vault::passphrase::check(&passphrase)?;
    let code = sync_engine::rotate_key(&passphrase, kdf())?;
    Ok(SyncSetupResult {
        // Not a reason to lose the code, which the vault already needs.
        vault_id: sync_engine::config()
            .ok()
            .flatten()
            .map(|c| c.vault_id)
            .unwrap_or_default(),
        recovery_code: code,
    })
}

/// What a QR code for enrolling another device carries, as JSON, or
/// `None` when sync is not set up. The same text, pasted on the other
/// device, is its join code. Whoever reads it can read the vault.
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
    sync_engine::join_code(&config, &dek).map(Some)
}
