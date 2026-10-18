//! What each subcommand does, as functions the tests can call.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use promptly_ssh::{
    AuthMethod, ConnectError, ConnectParams, Endpoint, FileKnownHosts, QuietPrompter, SftpBackend,
    SftpError, TermSize,
};
use promptly_store::{col_name, col_parse, Collection, DbKey, Store};
use promptly_vault::model::{Collection as Col, Host};
use promptly_vault::policy::{self, Kept};
use promptly_vault::{
    crypto, Backend, Dek, DeviceId, KdfParams, LocalFolder, Manifest, Marker, RecoveryCode, Vault,
};
use serde_json::{json, Map, Value};

/// How the vault is unlocked: a passphrase or a recovery code, from flags,
/// the environment, or a prompt.
pub trait Credentials {
    fn passphrase(&self) -> Option<&str>;
    /// Unlock with a recovery code: [`Self::recovery_code`] when given,
    /// otherwise asked for.
    fn wants_recovery_code(&self) -> bool {
        self.recovery_code().is_some()
    }
    fn recovery_code(&self) -> Option<&str>;
}

/// Where the vault is, and how to log in to the server it may be on.
pub trait Place {
    /// A folder, or `sftp://user@host[:port]/path` for a vault on a server.
    fn location(&self) -> &str;
    /// A private key to log in to the server with, instead of the SSH agent.
    fn identity(&self) -> Option<&Path> {
        None
    }
}

/// Where a vault lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Location {
    Folder(PathBuf),
    /// On a server, over SFTP. The path is in the login's home folder
    /// unless it starts with `/`.
    Sftp {
        endpoint: Endpoint,
        path: String,
    },
}

impl Location {
    /// A folder, or `sftp://user@host[:port]/path`. A second slash after
    /// the host makes the path absolute: `sftp://me@nas//srv/vault`.
    pub fn parse(text: &str) -> Result<Self> {
        let Some(rest) = text.strip_prefix("sftp://") else {
            return Ok(Self::Folder(PathBuf::from(text)));
        };
        let (login, path) = rest.split_once('/').unwrap_or((rest, ""));
        let endpoint = Endpoint::parse(login).map_err(|e| {
            anyhow!("{text} is not a server vault: {e}, like sftp://me@nas/promptly-vault")
        })?;
        anyhow::ensure!(
            !path.trim_matches('/').is_empty(),
            "{text} names no folder on the server, like sftp://me@nas/promptly-vault"
        );
        Ok(Self::Sftp {
            endpoint,
            path: path.to_string(),
        })
    }
}

/// Open the vault's storage: the folder, or an SFTP connection to the
/// server with the same code the app syncs through. The server's host key
/// must already be in `~/.ssh/known_hosts`, as nobody is there to ask.
pub fn open(place: &impl Place) -> Result<Box<dyn Backend>> {
    match Location::parse(place.location())? {
        Location::Folder(path) => Ok(Box::new(LocalFolder::new(path))),
        Location::Sftp { endpoint, path } => {
            Ok(Box::new(connect_sftp(&endpoint, &path, place.identity())?))
        }
    }
}

/// Log in with the key given, else a password from PROMPTLY_SSH_PASSWORD,
/// else whatever the SSH agent holds. A key with a passphrase takes it from
/// PROMPTLY_KEY_PASSPHRASE, or asks for it on a terminal.
fn connect_sftp(endpoint: &Endpoint, path: &str, identity: Option<&Path>) -> Result<SftpBackend> {
    let private_key = identity
        .map(|p| {
            std::fs::read_to_string(p)
                .map(zeroize::Zeroizing::new)
                .with_context(|| format!("could not read the key {}", p.display()))
        })
        .transpose()?;
    let auth = |passphrase: Option<String>| match &private_key {
        Some(key) => AuthMethod::Key {
            private_key: key.to_string(),
            passphrase,
        },
        None => match std::env::var("PROMPTLY_SSH_PASSWORD") {
            Ok(password) => AuthMethod::Password {
                password: Some(password),
            },
            Err(_) => AuthMethod::Agent,
        },
    };
    let known_hosts = Arc::new(FileKnownHosts::new(
        FileKnownHosts::user_file().into_iter().collect(),
        data_dir()?.join("known_hosts"),
    ));
    let connect = |passphrase: Option<String>| {
        let params = ConnectParams::new(endpoint.clone(), auth(passphrase), TermSize::default());
        SftpBackend::connect_blocking(&params, Arc::new(QuietPrompter), known_hosts.clone(), path)
    };
    let result = match connect(std::env::var("PROMPTLY_KEY_PASSPHRASE").ok()) {
        Err(SftpError::Connect(ConnectError::KeyNeedsPassphrase)) if can_ask() => {
            let typed =
                zeroize::Zeroizing::new(rpassword::prompt_password("Passphrase for the key: ")?);
            connect(Some(typed.to_string()))
        }
        other => other,
    };
    let host = &endpoint.host;
    result.map_err(|e| match e {
        SftpError::Connect(ConnectError::HostKeyRejected { changed: false }) => anyhow!(
            "{host} is not in ~/.ssh/known_hosts yet. Connect to it once with ssh to check and trust its host key, then try again."
        ),
        SftpError::Connect(ConnectError::HostKeyRejected { changed: true }) => anyhow!(
            "{host} showed a different host key from the one in ~/.ssh/known_hosts. This can mean someone is intercepting the connection: check with whoever runs the server."
        ),
        SftpError::Connect(ConnectError::HostKeyRevoked) => {
            anyhow!("{host}'s host key is marked as revoked in ~/.ssh/known_hosts.")
        }
        SftpError::Connect(ConnectError::KeyNeedsPassphrase) => anyhow!(
            "the key needs its passphrase: set PROMPTLY_KEY_PASSPHRASE, or run this on a terminal to be asked"
        ),
        SftpError::Connect(ConnectError::AuthFailed { .. } | ConnectError::Cancelled) => anyhow!(
            "{host} did not accept the login. Give a key it accepts with --identity, add one to your SSH agent, or set PROMPTLY_SSH_PASSWORD."
        ),
        SftpError::Connect(e) => {
            let plain = e.explain();
            anyhow!("{host}: {}. {}", plain.title, plain.hint)
        }
        other => anyhow!("{host}: {other}"),
    })
}

/// The data key plus where it came from.
pub struct Unlocked {
    pub dek: Dek,
    pub manifest: Manifest,
}

/// Unlock the vault in `backend`. Returns `None` only when nothing was
/// given and no terminal is available to ask on.
pub fn unlock(args: &impl Credentials, backend: &dyn Backend) -> Result<Option<Unlocked>> {
    let manifest = Vault::read_manifest(backend).map_err(|e| anyhow!("{e}"))?;
    let dek = if args.wants_recovery_code() {
        let typed;
        let code = match args.recovery_code() {
            Some(c) => c,
            None if can_ask() => {
                typed = zeroize::Zeroizing::new(rpassword::prompt_password("Recovery code: ")?);
                typed.as_str()
            }
            None => return Ok(None),
        };
        let code =
            RecoveryCode::parse(code).ok_or_else(|| anyhow!("that is not a recovery code"))?;
        manifest.unlock_with_recovery(&code)?
    } else if let Some(p) = args.passphrase() {
        manifest.unlock(p)?
    } else if can_ask() {
        let p = zeroize::Zeroizing::new(rpassword::prompt_password("Vault passphrase: ")?);
        manifest.unlock(&p)?
    } else {
        return Ok(None);
    };
    Ok(Some(Unlocked { dek, manifest }))
}

/// Where this tool keeps its own files. Never a folder relative to where
/// it runs, or each folder would make it a new device.
fn data_dir() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("PROMPTLY_CLI_DATA_DIR") {
        return Ok(PathBuf::from(dir));
    }
    let base = if cfg!(windows) {
        std::env::var_os("APPDATA").map(PathBuf::from).or_else(|| {
            std::env::var_os("USERPROFILE")
                .map(|h| PathBuf::from(h).join("AppData").join("Roaming"))
        })
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local").join("share"))
            })
    };
    base.map(|d| d.join("promptly-cli")).ok_or_else(|| {
        anyhow!("no home folder to keep this tool's files in: set PROMPTLY_CLI_DATA_DIR")
    })
}

/// Whether a passphrase can be asked for. The prompt reads the terminal
/// itself, not standard input, so `promptly import VAULT - < hosts.json`
/// can still ask.
fn can_ask() -> bool {
    let tty = if cfg!(windows) { "CONIN$" } else { "/dev/tty" };
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(tty)
        .is_ok()
}

/// Where this tool keeps its own device state for one vault: the store,
/// and copies of the vault settings its key came from (the current one and
/// the one before).
struct DataPaths {
    db: PathBuf,
    manifest: PathBuf,
    previous: PathBuf,
}

fn data_paths(vault_id: &str) -> Result<DataPaths> {
    let base = data_dir()?;
    Ok(DataPaths {
        db: base.join(format!("{vault_id}.db")),
        manifest: base.join(format!("{vault_id}.manifest.json")),
        previous: base.join(format!("{vault_id}.manifest.previous.json")),
    })
}

/// Keep `manifest` as the settings this tool's key comes from, and the
/// one it replaces as the one before, so a store left under either key
/// can still be opened.
fn save_manifest(paths: &DataPaths, manifest: &Manifest) -> Result<()> {
    let json = manifest.to_json();
    let current = std::fs::read_to_string(&paths.manifest).ok();
    if current.as_deref() == Some(json.as_str()) {
        return Ok(());
    }
    if let Some(dir) = paths.manifest.parent() {
        std::fs::create_dir_all(dir)?;
    }
    if current.is_some() {
        std::fs::rename(&paths.manifest, &paths.previous)?;
    }
    let tmp = paths.manifest.with_extension("json.new");
    std::fs::write(&tmp, &json)?;
    std::fs::rename(&tmp, &paths.manifest)?;
    Ok(())
}

/// This tool's own device state: one store per vault, encrypted with a key
/// derived from the vault key, so it opens only for someone who could
/// unlock the vault anyway. When the key was changed on another device,
/// the passphrase from before brings it over (see [`bring_over`]): nothing
/// is set aside or started again.
fn cli_store(unlocked: &Unlocked) -> Result<Store> {
    let paths = data_paths(&unlocked.manifest.vault_id)?;
    let key = DbKey::derive(&unlocked.dek);
    if !Store::key_fits(&paths.db, &key)? {
        bring_over(&paths, &key)?;
    }
    let store = Store::open(&paths.db, Some(&key))?;
    finish_reseal(&store, &unlocked.dek)?;
    save_manifest(&paths, &unlocked.manifest)?;
    Ok(store)
}

/// The store is locked with a key the vault no longer has: find it among
/// the settings saved beside it with the passphrase from before, open the
/// store with it, lock it with `key`, and lock its secrets again under the
/// new vault key. Stops with a way out rather than lose anything.
fn bring_over(paths: &DataPaths, key: &DbKey) -> Result<()> {
    let start_afresh = format!(
        "To start afresh instead, delete {}: everything but what this tool kept on this device only comes back from the vault.",
        paths.db.display()
    );
    let saved: Vec<Manifest> = [&paths.manifest, &paths.previous]
        .into_iter()
        .filter_map(|p| Manifest::from_json(&std::fs::read(p).ok()?).ok())
        .collect();
    anyhow::ensure!(
        !saved.is_empty(),
        "this tool's records are locked with a key the vault no longer has. {start_afresh}"
    );
    let passphrase = previous_passphrase().ok_or_else(|| {
        anyhow!(
            "the vault's key was changed on another device. To bring this tool's records over, give the passphrase it last used in PROMPTLY_PREVIOUS_PASSPHRASE, or run it in a terminal to be asked. {start_afresh}"
        )
    })?;
    let mut opened = false;
    for manifest in saved {
        let Ok(old) = manifest.unlock(&passphrase) else {
            continue;
        };
        opened = true;
        let old_key = DbKey::derive(&old);
        if !Store::key_fits(&paths.db, &old_key)? {
            continue;
        }
        // The old key goes in first, so a run that stops after the store
        // is locked with the new key still locks its secrets again.
        let store = Store::open(&paths.db, Some(&old_key))?;
        add_reseal_from(&store, &old)?;
        store.meta_set(META_SNAPSHOT_DUE, "true")?;
        store.rekey(key)?;
        return Ok(());
    }
    anyhow::bail!(if opened {
        format!("this tool's records are locked with a key from before that passphrase: give the one before it. {start_afresh}")
    } else {
        "that is not the passphrase this tool last used".to_string()
    })
}

fn previous_passphrase() -> Option<zeroize::Zeroizing<String>> {
    if let Ok(p) = std::env::var("PROMPTLY_PREVIOUS_PASSPHRASE") {
        return Some(zeroize::Zeroizing::new(p));
    }
    if can_ask() {
        return rpassword::prompt_password("Vault passphrase from before the key change: ")
            .ok()
            .map(zeroize::Zeroizing::new);
    }
    None
}

/// The records kept on this tool's device last time (see
/// [`promptly_vault::policy`]), under the same key the app uses.
const META_KEPT: &str = "kept_on_device";
/// Set while a snapshot under a new key is still to be written.
const META_SNAPSHOT_DUE: &str = "snapshot_due";
/// The data keys from before a key change, kept while secrets sealed
/// under them are still to be locked again under the new one.
const META_RESEAL_FROM: &str = "reseal_from";

fn reseal_from(store: &Store) -> Result<Vec<Dek>> {
    Ok(store
        .meta_get(META_RESEAL_FROM)?
        .and_then(|json| serde_json::from_str::<Vec<[u8; 32]>>(&json).ok())
        .unwrap_or_default()
        .into_iter()
        .map(Dek)
        .collect())
}

fn add_reseal_from(store: &Store, old: &Dek) -> Result<()> {
    let mut keys: Vec<[u8; 32]> = reseal_from(store)?.into_iter().map(|k| k.0).collect();
    if !keys.contains(&old.0) {
        keys.push(old.0);
    }
    store.meta_set(META_RESEAL_FROM, &json!(keys).to_string())?;
    Ok(())
}

/// Lock again under `new` whatever secrets a key change left under an old
/// key, then forget the old keys.
fn finish_reseal(store: &Store, new: &Dek) -> Result<()> {
    let olds = reseal_from(store)?;
    if !olds.is_empty() {
        reseal(store, &olds, new)?;
        store.meta_delete(META_RESEAL_FROM)?;
    }
    Ok(())
}

fn open_vault<'a>(backend: &'a dyn Backend, store: &Store, unlocked: &Unlocked) -> Vault<'a> {
    let kept = store
        .meta_get(META_KEPT)
        .ok()
        .flatten()
        .map(|s| policy::kept_from_json(&s))
        .unwrap_or_default();
    Vault::with_dek(
        backend,
        store.device_id().clone(),
        unlocked.manifest.vault_id.clone(),
        unlocked.dek.clone(),
    )
    .with_kept(kept)
}

/// Stop here if another device removed this tool from the vault: nothing
/// it wrote would count.
fn ensure_not_removed(store: &Store) -> Result<()> {
    let removed =
        store.with_state(|state| policy::removed_devices(state).contains_key(store.device_id()));
    anyhow::ensure!(
        !removed,
        "this tool was removed from the vault on another device, so it no longer syncs. \
         To sync it again, delete its copy in the PROMPTLY_CLI_DATA_DIR folder \
         (~/.local/share/promptly-cli, or %APPDATA%\\promptly-cli on Windows) and it joins as a new device."
    );
    Ok(())
}

/// Write what changed here: the records kept on this device stay out (and
/// one going back into the vault is written again in full, newer than its
/// tombstone), then a snapshot when one is due or the folder has grown.
fn push_all<'a>(store: &Store, vault: Vault<'a>) -> Result<(Vault<'a>, Option<u64>)> {
    ensure_not_removed(store)?;
    finish_reseal(store, vault.dek())?;
    let previous: Kept = vault.kept().clone();
    let plan = store.with_state(|state| policy::plan_kept(state, &previous));
    for (col, id) in &plan.back {
        if let Some(record) = store.get(*col, id)? {
            store.delete(*col, id)?;
            store.put(*col, id, &record.json)?;
        }
    }
    let vault = vault.with_kept(plan.kept.clone());
    let pushed = store.push(&vault)?;
    let due = plan.newly_kept || store.meta_get(META_SNAPSHOT_DUE)?.is_some();
    store.compact(&vault, due)?;
    store.meta_set(META_KEPT, &policy::kept_to_json(&plan.kept))?;
    store.meta_delete(META_SNAPSHOT_DUE)?;
    Ok((vault, pushed))
}

/// Pull everything into this tool's store and return it with the vault.
fn fresh<'a>(backend: &'a dyn Backend, unlocked: &Unlocked) -> Result<(Store, Vault<'a>)> {
    let store = cli_store(unlocked)?;
    let vault = open_vault(backend, &store, unlocked);
    let report = store.pull(&vault)?;
    for w in report.warnings {
        eprintln!("warning: {w}");
    }
    Ok((store, vault))
}

pub fn inspect(backend: &dyn Backend, unlocked: Option<&Unlocked>) -> Result<String> {
    let manifest = Vault::read_manifest(backend).map_err(|e| anyhow!("{e}"))?;
    let mut out = String::new();
    out.push_str(&format!("vault      {}\n", manifest.vault_id));
    out.push_str(&format!("created    {}\n", manifest.created_at));
    out.push_str(&format!(
        "kdf        {} ({} MiB, {} passes)\n",
        manifest.kdf.alg,
        manifest.kdf.memory_kib / 1024,
        manifest.kdf.iterations
    ));
    out.push_str(&format!(
        "recovery   starts with {}\n",
        manifest.recovery_hint().unwrap_or("?")
    ));
    let devices = backend.list("devices")?;
    out.push_str(&format!("devices    {}\n", devices.len()));
    let mut total = 0u64;
    for d in &devices {
        let files = backend.list(&format!("devices/{}", d.name))?;
        let segs = files.iter().filter(|f| f.name.ends_with(".seg")).count();
        let snaps = files.iter().filter(|f| f.name.ends_with(".snap")).count();
        let bytes: u64 = files.iter().map(|f| f.size).sum();
        total += bytes;
        out.push_str(&format!(
            "  {}  {segs} segment{}, {snaps} snapshot{}, {bytes} bytes\n",
            d.name,
            if segs == 1 { "" } else { "s" },
            if snaps == 1 { "" } else { "s" }
        ));
    }
    out.push_str(&format!("size       {total} bytes\n"));
    if let Some(unlocked) = unlocked {
        let (store, _vault) = fresh(backend, unlocked)?;
        out.push_str(&format!("clock      {}\n", store.clock_counter()));
        for col in [
            Col::Hosts,
            Col::Groups,
            Col::Identities,
            Col::Secrets,
            Col::Snippets,
            Col::KnownHosts,
            Col::Themes,
            Col::Settings,
            Col::Devices,
        ] {
            let n = store.list(col)?.len();
            if n > 0 {
                out.push_str(&format!("  {:<12}{n}\n", col_name(col)));
            }
        }
        let names: Vec<String> = store
            .list(Col::Devices)?
            .into_iter()
            .filter_map(|r| serde_json::from_str::<Value>(&r.json).ok())
            .map(|d| {
                format!(
                    "{} ({})",
                    d["name"].as_str().unwrap_or("?"),
                    d["platform"].as_str().unwrap_or("?")
                )
            })
            .collect();
        if !names.is_empty() {
            out.push_str(&format!("enrolled   {}\n", names.join(", ")));
        }
    }
    Ok(out)
}

fn decrypt_secret(dek: &Dek, id: &str, record: &Value) -> Option<String> {
    let ct: Vec<u8> = serde_json::from_value(record.get("ciphertext")?.clone()).ok()?;
    let plain = crypto::open(dek, format!("secret/{id}").as_bytes(), &ct).ok()?;
    String::from_utf8(plain).ok()
}

pub fn export(backend: &dyn Backend, unlocked: &Unlocked, with_secrets: bool) -> Result<String> {
    let (store, _vault) = fresh(backend, unlocked)?;
    let mut doc = Map::new();
    doc.insert("format".into(), json!(1));
    doc.insert("vault_id".into(), json!(unlocked.manifest.vault_id));
    doc.insert(
        "exported_at".into(),
        json!(promptly_vault::ops::now_rfc3339()),
    );
    for col in [
        Col::Hosts,
        Col::Groups,
        Col::Identities,
        Col::Snippets,
        Col::KnownHosts,
        Col::Themes,
        Col::Settings,
        Col::Devices,
    ] {
        let items: Vec<Value> = store
            .list(col)?
            .into_iter()
            .filter_map(|r| serde_json::from_str(&r.json).ok())
            .collect();
        doc.insert(col_name(col).into(), Value::Array(items));
    }
    if with_secrets {
        let items: Vec<Value> = store
            .list(Col::Secrets)?
            .into_iter()
            .filter_map(|r| {
                let v: Value = serde_json::from_str(&r.json).ok()?;
                let value = decrypt_secret(&unlocked.dek, &r.id, &v)?;
                Some(json!({"id": r.id, "kind": v["kind"], "value": value}))
            })
            .collect();
        doc.insert("secrets".into(), Value::Array(items));
    }
    Ok(serde_json::to_string_pretty(&Value::Object(doc))?)
}

/// Merge records from an export document. Secrets with a `value` are
/// re-encrypted under the vault key.
pub fn import(backend: &dyn Backend, unlocked: &Unlocked, text: &str) -> Result<usize> {
    let doc: Value = serde_json::from_str(text).context("the file is not JSON")?;
    let (store, vault) = fresh(backend, unlocked)?;
    let mut n = 0;
    if let Some(obj) = doc.as_object() {
        for (name, items) in obj {
            let Some(col) = col_parse(name) else { continue };
            let Some(items) = items.as_array() else {
                continue;
            };
            for item in items {
                let Some(id) = item.get("id").and_then(Value::as_str) else {
                    continue;
                };
                let record = if col == Collection::Secrets {
                    match item.get("value").and_then(Value::as_str) {
                        Some(value) => {
                            let ct = crypto::seal(
                                &unlocked.dek,
                                format!("secret/{id}").as_bytes(),
                                value.as_bytes(),
                            )?;
                            json!({"id": id, "kind": item["kind"], "ciphertext": ct, "sync": "vault"})
                        }
                        None => item.clone(),
                    }
                } else {
                    item.clone()
                };
                if store.put(col, id, &record.to_string())? {
                    n += 1;
                }
            }
        }
    }
    push_all(&store, vault)?;
    Ok(n)
}

pub fn sync(backend: &dyn Backend, unlocked: &Unlocked) -> Result<String> {
    let store = cli_store(unlocked)?;
    let vault = open_vault(backend, &store, unlocked);
    let report = store.pull(&vault)?;
    let (_vault, pushed) = push_all(&store, vault)?;
    let mut s = format!(
        "pulled {} file{} ({} changes) from {} device{}",
        report.files_applied,
        if report.files_applied == 1 { "" } else { "s" },
        report.ops_applied,
        report.devices_seen.len(),
        if report.devices_seen.len() == 1 {
            ""
        } else {
            "s"
        }
    );
    if let Some(seq) = pushed {
        s.push_str(&format!(", pushed segment {seq}"));
    }
    for w in &report.warnings {
        s.push_str(&format!("\nwarning: {w}"));
    }
    Ok(s)
}

/// An OpenSSH `config` for every host in the vault.
pub fn ssh_config(
    backend: &dyn Backend,
    unlocked: &Unlocked,
    keys_dir: Option<&Path>,
) -> Result<String> {
    let (store, _vault) = fresh(backend, unlocked)?;
    let identities: BTreeMap<String, Value> = store
        .list(Col::Identities)?
        .into_iter()
        .filter_map(|r| {
            serde_json::from_str::<Value>(&r.json)
                .ok()
                .map(|v| (r.id, v))
        })
        .collect();
    let secrets: BTreeMap<String, Value> = store
        .list(Col::Secrets)?
        .into_iter()
        .filter_map(|r| {
            serde_json::from_str::<Value>(&r.json)
                .ok()
                .map(|v| (r.id, v))
        })
        .collect();
    let mut hosts: Vec<Host> = store
        .list(Col::Hosts)?
        .into_iter()
        .filter_map(|r| serde_json::from_str(&r.json).ok())
        .collect();
    hosts.sort_by_key(|h| h.label.to_lowercase());
    // Each host gets its own name, with no characters ssh would read as a
    // pattern, so two hosts both called "web" don't share one entry.
    let mut aliases: BTreeMap<String, String> = BTreeMap::new();
    let mut used = std::collections::BTreeSet::new();
    for h in &hosts {
        let base: String = h
            .label
            .chars()
            .map(|c| {
                if c.is_whitespace() || "*?!,\"#'=".contains(c) {
                    '-'
                } else {
                    c
                }
            })
            .collect();
        let base = if base.is_empty() {
            "host".to_string()
        } else {
            base
        };
        let mut alias = base.clone();
        let mut n = 2;
        while !used.insert(alias.to_lowercase()) {
            alias = format!("{base}-{n}");
            n += 1;
        }
        aliases.insert(h.id.to_string(), alias);
    }

    let mut out =
        String::from("# Generated by promptly from the vault. Edit the vault, not this file.\n");
    // Each key is written once, under a file name no other key has.
    let mut key_files: BTreeMap<String, PathBuf> = BTreeMap::new();
    for h in hosts {
        let alias = &aliases[&h.id.to_string()];
        out.push_str(&format!(
            "\nHost {alias}\n    HostName {}\n",
            config_value(&h.hostname)
        ));
        if let Some(jump) = h
            .jump_host_id
            .as_ref()
            .and_then(|j| aliases.get(&j.to_string()))
        {
            out.push_str(&format!("    ProxyJump {jump}\n"));
        }
        if h.agent_forwarding {
            out.push_str("    ForwardAgent yes\n");
        }
        if h.persistent_session {
            out.push_str("    RequestTTY yes\n    RemoteCommand tmux new-session -A -s promptly\n");
        }
        for f in &h.port_forwards {
            use promptly_vault::model::ForwardKind;
            let bind = if f.bind_host.is_empty() {
                format!("{}", f.bind_port)
            } else {
                format!("{}:{}", bracketed(&f.bind_host), f.bind_port)
            };
            match f.kind {
                ForwardKind::Local => out.push_str(&format!(
                    "    LocalForward {bind} {}:{}\n",
                    bracketed(&f.target_host),
                    f.target_port
                )),
                ForwardKind::Remote => out.push_str(&format!(
                    "    RemoteForward {bind} {}:{}\n",
                    bracketed(&f.target_host),
                    f.target_port
                )),
                ForwardKind::Dynamic => out.push_str(&format!("    DynamicForward {bind}\n")),
            }
        }
        if !h.username.is_empty() {
            out.push_str(&format!("    User {}\n", config_value(&h.username)));
        }
        if h.port != 22 {
            out.push_str(&format!("    Port {}\n", h.port));
        }
        if h.keepalive_seconds > 0 {
            out.push_str(&format!(
                "    ServerAliveInterval {}\n",
                h.keepalive_seconds
            ));
        }
        if let promptly_vault::model::Auth::Identity { identity_id } = &h.auth {
            if let Some(identity) = identities.get(&identity_id.to_string()) {
                let label = identity["label"].as_str().unwrap_or("key");
                let secret_id = identity["private_key_secret_id"].as_str();
                match (keys_dir, secret_id) {
                    (Some(dir), Some(sid)) => {
                        if let Some(value) = secrets
                            .get(sid)
                            .and_then(|s| decrypt_secret(&unlocked.dek, sid, s))
                        {
                            let safe: String = label
                                .chars()
                                .map(|c| {
                                    if c.is_alphanumeric() || c == '-' || c == '_' {
                                        c
                                    } else {
                                        '_'
                                    }
                                })
                                .collect();
                            let path = match key_files.get(&identity_id.to_string()) {
                                Some(path) => path.clone(),
                                None => {
                                    let taken: Vec<&PathBuf> = key_files.values().collect();
                                    let path =
                                        write_key_file(dir, &safe, value.as_bytes(), &taken)?;
                                    key_files.insert(identity_id.to_string(), path.clone());
                                    path
                                }
                            };
                            out.push_str(&format!(
                                "    IdentityFile {}\n",
                                config_value(&path.to_string_lossy())
                            ));
                        }
                    }
                    _ => out.push_str(&format!(
                        "    # key: {label} (pass --keys-dir to write it out)\n"
                    )),
                }
            }
        }
    }
    Ok(out)
}

/// A value as ssh_config reads it back, exactly: in double quotes when it
/// has a space, `#`, either kind of quote or a backslash ssh would take as
/// an escape, with `"` and those backslashes escaped. A stray quote would
/// break every `ssh` command, not just this host's. Line breaks and other
/// control characters can't be written on one line, so they are left out.
fn config_value(value: &str) -> String {
    let chars: Vec<char> = value.chars().filter(|c| !c.is_control()).collect();
    let mut quote = chars.is_empty();
    let mut out = String::new();
    for (i, &c) in chars.iter().enumerate() {
        match c {
            '"' => {
                out.push_str("\\\"");
                quote = true;
            }
            // ssh reads a backslash before these as an escape, and one at
            // the end would escape the closing quote. Any other backslash,
            // as in `C:\Users`, it keeps as it is.
            '\\' if matches!(chars.get(i + 1), None | Some('\\' | '"' | '\'')) => {
                out.push_str("\\\\");
                quote = true;
            }
            c => {
                quote |= c.is_whitespace() || c == '#' || c == '\'';
                out.push(c);
            }
        }
    }
    if quote {
        format!("\"{out}\"")
    } else {
        out
    }
}

/// An IPv6 address in brackets, as forwarding lines need: `[::1]:8080`.
fn bracketed(host: &str) -> String {
    if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.to_string()
    }
}

/// Write a private key into `dir` as `name`, or `name-2` and so on when
/// that is taken: by another key in this run, or by a file already there
/// that holds something else, such as the user's own `~/.ssh/id_ed25519`.
/// A file already holding this key is used as it is. Only a folder made
/// here is made private; one that was there, such as the home folder, is
/// left alone. Returns where the key is.
fn write_key_file(dir: &Path, name: &str, bytes: &[u8], taken: &[&PathBuf]) -> Result<PathBuf> {
    if !dir.exists() {
        std::fs::create_dir_all(dir)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
    }
    let mut n = 1;
    loop {
        let path = match n {
            1 => dir.join(name),
            _ => dir.join(format!("{name}-{n}")),
        };
        n += 1;
        if taken.contains(&&path) {
            continue;
        }
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        match opts.open(&path) {
            Ok(mut file) => {
                use std::io::Write;
                file.write_all(bytes)?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                if std::fs::read(&path).ok().as_deref() != Some(bytes) {
                    continue;
                }
            }
            Err(e) => return Err(e.into()),
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        }
        return Ok(path);
    }
}

pub fn change_passphrase(
    backend: &dyn Backend,
    unlocked: &Unlocked,
    new_passphrase: &str,
) -> Result<()> {
    let mut manifest = unlocked.manifest.clone();
    // Detect a race: the manifest must still be the one we unlocked.
    let current = Vault::read_manifest(backend).map_err(|e| anyhow!("{e}"))?;
    anyhow::ensure!(
        current == manifest,
        "the vault's manifest changed under us; try again"
    );
    manifest.change_passphrase(&unlocked.dek, new_passphrase);
    // Key stretching takes a moment; look again right before writing, so
    // a change made meanwhile on another device is not overwritten.
    let current = Vault::read_manifest(backend).map_err(|e| anyhow!("{e}"))?;
    anyhow::ensure!(
        current == unlocked.manifest,
        "the vault's manifest changed under us; try again"
    );
    // A folder gets the new manifest beside the old one, renamed over it,
    // so it always holds one whole manifest, old or new, whatever happens.
    // The manifest is no device's file, so any device id will do here.
    Vault::with_dek(
        backend,
        DeviceId::generate(),
        manifest.vault_id.clone(),
        unlocked.dek.clone(),
    )
    .replace_manifest(&unlocked.manifest.keys_fingerprint(), &manifest)
    .map_err(|e| anyhow!("{e}"))
}

/// Give the vault a new data key (VAULT.md section 11), wrapped under
/// `new_passphrase` and a new recovery code, which is returned. Everything
/// is synced first; the secrets are encrypted again and a snapshot under
/// the new key replaces this tool's files. Whoever has only the old key,
/// a removed device included, can read nothing written from now on.
pub fn rotate_dek(
    backend: &dyn Backend,
    unlocked: &Unlocked,
    new_passphrase: &str,
) -> Result<String> {
    check_new_passphrase(unlocked, new_passphrase)?;
    let (store, vault) = fresh(backend, unlocked)?;
    let known = vault
        .check_manifest(Some(&unlocked.manifest.keys_fingerprint()))
        .map_err(|e| anyhow!("{e}"))?;
    let (vault, _) = push_all(&store, vault)?;
    let k = &unlocked.manifest.kdf;
    let params = KdfParams {
        memory_kib: k.memory_kib,
        iterations: k.iterations,
        parallelism: k.parallelism,
    };
    // Kept before the vault changes, so a run that stops at any point after
    // leaves the next one what it needs to finish: the old key to lock the
    // secrets again with, and a snapshot owed. Should the key not change
    // after all, both cost only a snapshot.
    add_reseal_from(&store, &unlocked.dek)?;
    store.meta_set(META_SNAPSHOT_DUE, "true")?;
    let (vault, manifest, code) = vault
        .rotate(&known, new_passphrase, params)
        .map_err(|e| anyhow!("{e}"))?;
    // The vault has the new key from here, so the new code must reach the
    // person whatever follows. What fails is reported, and the next run
    // with the new passphrase finishes it.
    let mut trouble = Vec::new();
    // This tool's own records are locked with a key made from the vault's.
    // The new settings are kept first, with the old ones as the ones
    // before, so whichever key the store is left under, the next run can
    // bring it over (see [`bring_over`]).
    let paths = data_paths(&unlocked.manifest.vault_id)?;
    if let Err(e) = save_manifest(&paths, &manifest) {
        trouble.push(format!(
            "the new vault settings could not be kept beside this tool's records ({e})"
        ));
    }
    if let Err(e) = store.rekey(&DbKey::derive(vault.dek())) {
        trouble.push(format!(
            "this tool's records could not be locked with the new key ({e}); the next run asks for the passphrase from before to do it"
        ));
    }
    let finished = push_all(&store, vault).map(|_| ());
    if let Err(e) = finished {
        trouble.push(format!(
            "the vault has the new key, but writing under it stopped ({e}); the next sync finishes it"
        ));
    }
    for t in trouble {
        eprintln!("warning: {t}");
    }
    Ok(code.as_str().to_string())
}

/// Lock every secret record sealed under one of `olds` again under `new`.
/// Records `new` opens already are left as they are, so this can run again
/// after stopping part way.
fn reseal(store: &Store, olds: &[Dek], new: &Dek) -> Result<()> {
    for r in store.list(Col::Secrets)? {
        let Ok(mut fields) = serde_json::from_str::<Value>(&r.json) else {
            continue;
        };
        let aad = format!("secret/{}", r.id);
        let Some(ct) = fields
            .get("ciphertext")
            .and_then(|v| serde_json::from_value::<Vec<u8>>(v.clone()).ok())
        else {
            continue;
        };
        if crypto::open(new, aad.as_bytes(), &ct).is_ok() {
            continue;
        }
        let Some(plain) = olds
            .iter()
            .find_map(|old| crypto::open(old, aad.as_bytes(), &ct).ok())
        else {
            eprintln!(
                "warning: secret {} could not be read to lock it again",
                r.id
            );
            continue;
        };
        fields["ciphertext"] = json!(crypto::seal(new, aad.as_bytes(), &plain)?);
        store.put(Col::Secrets, &r.id, &fields.to_string())?;
    }
    Ok(())
}

/// A device record's id as a folder name: the same 16 bytes in hex.
fn folder_of(record_id: &str) -> Option<DeviceId> {
    DeviceId::parse(&record_id.replace('-', "").to_ascii_lowercase())
}

/// A folder name as a record id: hex with the dashes of a UUID.
fn record_id_of(device: &DeviceId) -> String {
    let h = device.as_str();
    format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    )
}

/// The vault's devices, one per line, removed ones marked.
pub fn list_devices(backend: &dyn Backend, unlocked: &Unlocked) -> Result<String> {
    let (store, _vault) = fresh(backend, unlocked)?;
    let mut out = String::new();
    let mut seen = Vec::new();
    for r in store.list(Col::Devices)? {
        let Ok(d) = serde_json::from_str::<Value>(&r.json) else {
            continue;
        };
        let date = |key: &str| {
            d[key]
                .as_str()
                .map(|s| s.get(..10).unwrap_or(s).to_string())
        };
        let mut line = format!(
            "{}  {} ({})",
            r.id,
            d["name"].as_str().filter(|n| !n.is_empty()).unwrap_or("?"),
            d["platform"]
                .as_str()
                .filter(|n| !n.is_empty())
                .unwrap_or("?")
        );
        if let Some(at) = date("enrolled_at") {
            line.push_str(&format!(", joined {at}"));
        }
        if let Some(at) = date("last_seen_at") {
            line.push_str(&format!(", last seen {at}"));
        }
        if d.get(policy::REMOVED_AFTER).is_some_and(|v| !v.is_null()) {
            line.push_str(&format!(
                ", removed {}",
                date(policy::REMOVED_AT).unwrap_or_else(|| "?".into())
            ));
        }
        out.push_str(&line);
        out.push('\n');
        seen.extend(folder_of(&r.id));
    }
    // Folders with no record: this tool's own, for one.
    for e in backend.list("devices")? {
        let Some(device) = DeviceId::parse(&e.name) else {
            continue;
        };
        if seen.contains(&device) {
            continue;
        }
        let this = if device == *store.device_id() {
            " (this tool)"
        } else {
            ""
        };
        out.push_str(&format!("{}  no record{this}\n", record_id_of(&device)));
    }
    Ok(out)
}

/// Whether `new_passphrase` may lock a new key: not one the vault has now,
/// since whoever knows that could open the new key with it. Checked before
/// anything changes, as well as by [`rotate_dek`].
pub fn check_new_passphrase(unlocked: &Unlocked, new_passphrase: &str) -> Result<()> {
    anyhow::ensure!(
        unlocked.manifest.unlock(new_passphrase).is_err(),
        "choose a passphrase the vault does not have now: whoever knows the current one could open the new key with it"
    );
    Ok(())
}

/// A device [`remove_device`] was asked to remove.
#[derive(Debug, PartialEq, Eq)]
pub struct Removed {
    pub name: String,
    /// It had been removed before, and nothing changed now.
    pub already: bool,
}

/// Mark a device removed (VAULT.md section 11), found by its id or its
/// name. Every device then ignores what it writes after the last of its
/// files read here, and it stops syncing once it finds out. It keeps the
/// copy it has: rotate the key as well if it was lost. One removed before
/// keeps its cutoff, and any upload an earlier run left unfinished is sent,
/// so a re-run can go on to rotate the key.
pub fn remove_device(backend: &dyn Backend, unlocked: &Unlocked, who: &str) -> Result<Removed> {
    let (store, vault) = fresh(backend, unlocked)?;
    ensure_not_removed(&store)?;
    let records: Vec<(String, Value)> = store
        .list(Col::Devices)?
        .into_iter()
        .filter_map(|r| Some((r.id, serde_json::from_str::<Value>(&r.json).ok()?)))
        .collect();
    let wanted = folder_of(who);
    let matches: Vec<&(String, Value)> = records
        .iter()
        .filter(|(id, d)| {
            (wanted.is_some() && folder_of(id) == wanted)
                || d["name"]
                    .as_str()
                    .is_some_and(|n| n.eq_ignore_ascii_case(who))
        })
        .collect();
    let (device, mut record) = match matches.as_slice() {
        [(id, d)] => (
            folder_of(id).context("that device's id is not valid")?,
            d.clone(),
        ),
        [] => {
            // A folder with no record can be removed by its id too.
            let device = wanted
                .filter(|d| {
                    backend
                        .list("devices")
                        .is_ok_and(|es| es.iter().any(|e| e.name == d.as_str()))
                })
                .ok_or_else(|| anyhow!("no device in the vault is called {who}"))?;
            let record = json!({
                "id": record_id_of(&device),
                "name": "",
                "platform": "",
                "enrolled_at": promptly_vault::ops::now_rfc3339(),
            });
            (device, record)
        }
        _ => anyhow::bail!("more than one device is called {who}: use its id"),
    };
    anyhow::ensure!(
        device != *store.device_id(),
        "that is this tool; to stop it syncing, stop running it"
    );
    let name = record["name"]
        .as_str()
        .filter(|n| !n.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| record_id_of(&device));
    if !record.get(policy::REMOVED_AFTER).is_none_or(Value::is_null) {
        // An earlier run may have marked it here and then failed to
        // upload; send whatever is still waiting, with its first cutoff.
        push_all(&store, vault)?;
        return Ok(Removed {
            name,
            already: true,
        });
    }
    let after = store
        .sync_state()?
        .markers
        .get(&device)
        .map_or(0, Marker::highest);
    record[policy::REMOVED_AT] = json!(promptly_vault::ops::now_rfc3339());
    record[policy::REMOVED_AFTER] = json!(after);
    store.put(Col::Devices, &record_id_of(&device), &record.to_string())?;
    push_all(&store, vault)?;
    Ok(Removed {
        name,
        already: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use promptly_vault::{DeviceId, KdfParams};

    struct Creds<'a> {
        pass: &'a str,
    }
    impl Credentials for Creds<'_> {
        fn passphrase(&self) -> Option<&str> {
            Some(self.pass)
        }
        fn recovery_code(&self) -> Option<&str> {
            None
        }
    }

    /// The CLI keeps its device state here during the tests, never in the
    /// real data folder. Set once: the tests run side by side, each with
    /// its own vault and so its own store file.
    fn use_test_data_dir() {
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| {
            std::env::set_var(
                "PROMPTLY_CLI_DATA_DIR",
                std::env::temp_dir().join(format!("promptly-cli-data-{}", std::process::id())),
            )
        });
    }

    fn device_record(store: &Store, name: &str) {
        let id = record_id_of(store.device_id());
        store
            .put(
                Collection::Devices,
                &id,
                &json!({"id": id, "name": name, "platform": "linux",
                    "enrolled_at": "2026-01-01T00:00:00Z"})
                .to_string(),
            )
            .unwrap();
    }

    /// A vault folder that refuses new files while `fail` is set, as a
    /// dropped connection would.
    struct Flaky {
        inner: LocalFolder,
        fail: std::sync::atomic::AtomicBool,
    }

    impl Backend for Flaky {
        fn list(
            &self,
            dir: &str,
        ) -> Result<Vec<promptly_vault::Entry>, promptly_vault::BackendError> {
            self.inner.list(dir)
        }
        fn get(&self, path: &str) -> Result<Vec<u8>, promptly_vault::BackendError> {
            self.inner.get(path)
        }
        fn put_new(&self, path: &str, bytes: &[u8]) -> Result<(), promptly_vault::BackendError> {
            if self.fail.load(std::sync::atomic::Ordering::SeqCst) {
                return Err(promptly_vault::BackendError::Io(
                    path.into(),
                    std::io::Error::other("connection dropped"),
                ));
            }
            self.inner.put_new(path, bytes)
        }
        fn delete(&self, path: &str) -> Result<(), promptly_vault::BackendError> {
            self.inner.delete(path)
        }
    }

    #[test]
    fn removing_a_device_again_finishes_an_upload_that_failed() {
        let dir = std::env::temp_dir().join(format!("promptly-cli-retry-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let vault_dir = dir.join("vault");
        std::fs::create_dir_all(&vault_dir).unwrap();
        use_test_data_dir();

        let backend = Flaky {
            inner: LocalFolder::new(&vault_dir),
            fail: false.into(),
        };
        let laptop = Store::open(&dir.join("laptop.db"), None).unwrap();
        let (vault, _code) = Vault::create(
            &backend,
            laptop.device_id().clone(),
            "pass",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        device_record(&laptop, "laptop");
        laptop.push(&vault).unwrap();
        let phone = Store::open(&dir.join("phone.db"), None).unwrap();
        let phone_vault = Vault::with_dek(
            &backend,
            phone.device_id().clone(),
            vault.vault_id().to_string(),
            vault.dek().clone(),
        );
        device_record(&phone, "phone");
        phone.push(&phone_vault).unwrap();
        let unlocked = unlock(&Creds { pass: "pass" }, &backend).unwrap().unwrap();
        // The tool's own first upload goes through.
        list_devices(&backend, &unlocked).unwrap();

        // The removal is marked here, then the upload fails.
        backend
            .fail
            .store(true, std::sync::atomic::Ordering::SeqCst);
        assert!(remove_device(&backend, &unlocked, "phone").is_err());
        backend
            .fail
            .store(false, std::sync::atomic::Ordering::SeqCst);

        // Run again: it was removed already here, and now the vault has it.
        assert!(remove_device(&backend, &unlocked, "phone").unwrap().already);
        laptop.pull(&vault).unwrap();
        let host_id = "0192f3a0-0000-7000-8000-000000000009";
        phone
            .put(
                Collection::Hosts,
                host_id,
                &json!({"id": host_id, "label": "sneaky", "hostname": "x"}).to_string(),
            )
            .unwrap();
        phone.push(&phone_vault).unwrap();
        laptop.pull(&vault).unwrap();
        assert!(
            laptop.get(Collection::Hosts, host_id).unwrap().is_none(),
            "the laptop ignores the removed phone"
        );
    }

    #[test]
    fn devices_are_listed_removed_and_the_key_rotated() {
        let dir = std::env::temp_dir().join(format!("promptly-cli-dev-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let vault_dir = dir.join("vault");
        std::fs::create_dir_all(&vault_dir).unwrap();
        use_test_data_dir();

        // Two app devices: a laptop that made the vault, and a phone.
        let backend = LocalFolder::new(&vault_dir);
        let laptop = Store::open(&dir.join("laptop.db"), None).unwrap();
        let (vault, _code) = Vault::create(
            &backend,
            laptop.device_id().clone(),
            "pass",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        device_record(&laptop, "laptop");
        let secret_id = "0192f3a0-0000-7000-8000-000000000002";
        let ct = crypto::seal(
            vault.dek(),
            format!("secret/{secret_id}").as_bytes(),
            b"hunter2",
        )
        .unwrap();
        laptop
            .put(
                Collection::Secrets,
                secret_id,
                &json!({"id": secret_id, "kind": "password", "ciphertext": ct, "sync": "vault"})
                    .to_string(),
            )
            .unwrap();
        laptop.push(&vault).unwrap();
        let phone = Store::open(&dir.join("phone.db"), None).unwrap();
        let phone_vault = Vault::with_dek(
            &backend,
            phone.device_id().clone(),
            vault.vault_id().to_string(),
            vault.dek().clone(),
        );
        device_record(&phone, "phone");
        phone.push(&phone_vault).unwrap();

        let creds = Creds { pass: "pass" };
        let unlocked = unlock(&creds, &backend).unwrap().unwrap();
        let list = list_devices(&backend, &unlocked).unwrap();
        assert!(list.contains("laptop (linux)"), "{list}");
        assert!(list.contains("phone (linux)"), "{list}");

        // Not this tool, nor a name nobody has.
        let me = cli_store(&unlocked).unwrap().device_id().clone();
        assert!(remove_device(&backend, &unlocked, &record_id_of(&me)).is_err());
        assert!(remove_device(&backend, &unlocked, "tablet").is_err());

        // The phone is removed: the laptop stops listening to it.
        assert_eq!(
            remove_device(&backend, &unlocked, "Phone").unwrap(),
            Removed {
                name: "phone".into(),
                already: false
            }
        );
        let list = list_devices(&backend, &unlocked).unwrap();
        assert!(
            list.contains("phone (linux), joined 2026-01-01, removed "),
            "{list}"
        );
        assert!(
            remove_device(&backend, &unlocked, "phone").unwrap().already,
            "a second time changes nothing, so --rekey can go on"
        );
        let host_id = "0192f3a0-0000-7000-8000-000000000007";
        phone
            .put(
                Collection::Hosts,
                host_id,
                &json!({"id": host_id, "label": "sneaky", "hostname": "x"}).to_string(),
            )
            .unwrap();
        phone.push(&phone_vault).unwrap();
        laptop.pull(&vault).unwrap();
        assert!(laptop.get(Collection::Hosts, host_id).unwrap().is_none());

        // A host kept on this tool's device never reaches the vault.
        let local = "0192f3a0-0000-7000-8000-000000000008";
        import(&backend, &unlocked, &json!({
            "hosts": [{"id": local, "label": "here only", "hostname": "h", "sync": "local_only"}]
        }).to_string())
        .unwrap();
        laptop.pull(&vault).unwrap();
        assert!(laptop.get(Collection::Hosts, local).unwrap().is_none());

        // A new key: the old one opens nothing new, the new passphrase and
        // code open the vault, and everything is there under the new key.
        assert!(
            rotate_dek(&backend, &unlocked, "pass").is_err(),
            "not the same passphrase"
        );
        assert!(check_new_passphrase(&unlocked, "pass").is_err());
        assert!(check_new_passphrase(&unlocked, "new pass").is_ok());
        let code = rotate_dek(&backend, &unlocked, "new pass").unwrap();
        let manifest = Vault::read_manifest(&backend).unwrap();
        assert!(manifest.unlock("pass").is_err());
        let new_dek = manifest.unlock("new pass").unwrap();
        assert_ne!(new_dek, unlocked.dek);
        assert_eq!(
            manifest
                .unlock_with_recovery(&RecoveryCode::parse(&code).unwrap())
                .unwrap(),
            new_dek
        );
        assert!(vault
            .check_manifest(Some(&unlocked.manifest.keys_fingerprint()))
            .is_err());
        let fresh_store = Store::open(&dir.join("fresh.db"), None).unwrap();
        let fresh_vault = Vault::with_dek(
            &backend,
            fresh_store.device_id().clone(),
            vault.vault_id().to_string(),
            new_dek.clone(),
        );
        fresh_store.pull(&fresh_vault).unwrap();
        assert_eq!(fresh_store.list(Collection::Devices).unwrap().len(), 2);
        assert!(fresh_store.get(Collection::Hosts, local).unwrap().is_none());
        let secret: Value = serde_json::from_str(
            &fresh_store
                .get(Collection::Secrets, secret_id)
                .unwrap()
                .unwrap()
                .json,
        )
        .unwrap();
        assert_eq!(
            decrypt_secret(&new_dek, secret_id, &secret).as_deref(),
            Some("hunter2")
        );
        // This tool's files under the old key are gone.
        let mine = backend.list(&format!("devices/{me}")).unwrap();
        assert!(mine.iter().all(|e| e.name.ends_with(".snap")), "{mine:?}");

        // Its own records open with the new passphrase: the same device,
        // and the host kept here is still here.
        let creds = Creds { pass: "new pass" };
        let renewed = unlock(&creds, &backend).unwrap().unwrap();
        let again = cli_store(&renewed).unwrap();
        assert_eq!(again.device_id(), &me, "not set aside as unreadable");
        assert!(again.get(Collection::Hosts, local).unwrap().is_some());

        // Stopped part way through locking the secrets again: the next run
        // finishes it from the old key it kept.
        let late = "0192f3a0-0000-7000-8000-000000000009";
        let old_ct = crypto::seal(
            &unlocked.dek,
            format!("secret/{late}").as_bytes(),
            b"swordfish",
        )
        .unwrap();
        again
            .put(
                Collection::Secrets,
                late,
                &json!({"id": late, "kind": "password", "ciphertext": old_ct, "sync": "vault"})
                    .to_string(),
            )
            .unwrap();
        add_reseal_from(&again, &unlocked.dek).unwrap();
        drop(again);
        import(&backend, &renewed, "{}").unwrap();
        fresh_store.pull(&fresh_vault).unwrap();
        let secret: Value = serde_json::from_str(
            &fresh_store
                .get(Collection::Secrets, late)
                .unwrap()
                .unwrap()
                .json,
        )
        .unwrap();
        assert_eq!(
            decrypt_secret(&new_dek, late, &secret).as_deref(),
            Some("swordfish")
        );
        assert!(cli_store(&renewed)
            .unwrap()
            .meta_get(META_RESEAL_FROM)
            .unwrap()
            .is_none());

        // A change made here and not yet written, then a new key made on
        // the laptop: this tool's records are brought over with the
        // passphrase from before, not set aside.
        let pending = cli_store(&renewed).unwrap();
        let snippet = "0192f3a0-0000-7000-8000-00000000000a";
        pending
            .put(
                Collection::Snippets,
                snippet,
                &json!({"id": snippet, "label": "ls", "command": "ls"}).to_string(),
            )
            .unwrap();
        // And a password this tool keeps to itself.
        let mine_only = "0192f3a0-0000-7000-8000-00000000000b";
        let own_secret = |store: &Store, dek: &Dek, value: &[u8], sync: &str| {
            let ct = crypto::seal(dek, format!("secret/{mine_only}").as_bytes(), value).unwrap();
            store
                .put(
                    Collection::Secrets,
                    mine_only,
                    &json!({"id": mine_only, "kind": "password", "ciphertext": ct, "sync": sync})
                        .to_string(),
                )
                .unwrap();
        };
        let read_own = |store: &Store, dek: &Dek| {
            let record: Value = serde_json::from_str(
                &store
                    .get(Collection::Secrets, mine_only)
                    .unwrap()
                    .unwrap()
                    .json,
            )
            .unwrap();
            decrypt_secret(dek, mine_only, &record)
        };
        own_secret(&pending, &renewed.dek, b"kept here", "local_only");
        let waiting = pending.pending_count().unwrap();
        assert!(waiting > 0);
        drop(pending);
        let laptop_vault = Vault::open(&backend, laptop.device_id().clone(), "new pass").unwrap();
        laptop.pull(&laptop_vault).unwrap();
        let known = laptop_vault.check_manifest(None).unwrap();
        laptop_vault
            .rotate(&known, "third pass", KdfParams::fast_for_tests())
            .unwrap();
        let creds = Creds { pass: "third pass" };
        let third = unlock(&creds, &backend).unwrap().unwrap();
        let data_dir = PathBuf::from(std::env::var_os("PROMPTLY_CLI_DATA_DIR").unwrap());
        let set_aside = || {
            std::fs::read_dir(&data_dir)
                .unwrap()
                .filter(|e| {
                    e.as_ref()
                        .unwrap()
                        .file_name()
                        .to_string_lossy()
                        .contains("unreadable")
                })
                .count()
        };
        if !can_ask() {
            let err = cli_store(&third).err().unwrap().to_string();
            assert!(err.contains("PROMPTLY_PREVIOUS_PASSPHRASE"), "{err}");
        }
        std::env::set_var("PROMPTLY_PREVIOUS_PASSPHRASE", "not it");
        let err = cli_store(&third).err().unwrap().to_string();
        assert!(err.contains("not the passphrase"), "{err}");
        assert_eq!(set_aside(), 0, "nothing set aside while asking");
        std::env::set_var("PROMPTLY_PREVIOUS_PASSPHRASE", "new pass");
        let moved = cli_store(&third);
        std::env::remove_var("PROMPTLY_PREVIOUS_PASSPHRASE");
        let moved = moved.unwrap();
        assert_eq!(moved.device_id(), &me);
        assert!(moved.get(Collection::Hosts, local).unwrap().is_some());
        assert!(
            moved.pending_count().unwrap() >= waiting,
            "nothing unwritten lost"
        );
        assert_eq!(set_aside(), 0);
        assert_eq!(
            read_own(&moved, &third.dek).as_deref(),
            Some("kept here"),
            "its secrets are locked again under the new key too"
        );
        drop(moved);
        assert_eq!(cli_store(&third).unwrap().device_id(), &me);

        // A new key made here, then straight away another on the laptop,
        // with no run of this tool between: the passphrase this tool last
        // used still brings everything over.
        rotate_dek(&backend, &third, "fourth pass").unwrap();
        let laptop_vault =
            Vault::open(&backend, laptop.device_id().clone(), "fourth pass").unwrap();
        laptop.pull(&laptop_vault).unwrap();
        let known = laptop_vault.check_manifest(None).unwrap();
        laptop_vault
            .rotate(&known, "fifth pass", KdfParams::fast_for_tests())
            .unwrap();
        let creds = Creds { pass: "fifth pass" };
        let fifth = unlock(&creds, &backend).unwrap().unwrap();
        std::env::set_var("PROMPTLY_PREVIOUS_PASSPHRASE", "fourth pass");
        let moved = cli_store(&fifth);
        std::env::remove_var("PROMPTLY_PREVIOUS_PASSPHRASE");
        let moved = moved.unwrap();
        assert_eq!(moved.device_id(), &me);
        assert_eq!(read_own(&moved, &fifth.dek).as_deref(), Some("kept here"));

        // Shared later, it reaches other devices readable.
        let record = moved.get(Collection::Secrets, mine_only).unwrap().unwrap();
        let mut fields: Value = serde_json::from_str(&record.json).unwrap();
        fields["sync"] = json!("vault");
        moved
            .put(Collection::Secrets, mine_only, &fields.to_string())
            .unwrap();
        drop(moved);
        import(&backend, &fifth, "{}").unwrap();
        let reader = Store::open(&dir.join("reader.db"), None).unwrap();
        let reader_vault = Vault::with_dek(
            &backend,
            reader.device_id().clone(),
            vault.vault_id().to_string(),
            fifth.dek.clone(),
        );
        reader.pull(&reader_vault).unwrap();
        assert_eq!(read_own(&reader, &fifth.dek).as_deref(), Some("kept here"));
        assert_eq!(set_aside(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn export_import_ssh_config_and_passphrase_change() {
        use_test_data_dir();
        let dir = std::env::temp_dir().join(format!("promptly-cli-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let vault_dir = dir.join("vault");
        std::fs::create_dir_all(&vault_dir).unwrap();
        use_test_data_dir();

        // An app device makes the vault and adds a host with a key.
        let backend = LocalFolder::new(&vault_dir);
        let app = Store::open(&dir.join("app.db"), None).unwrap();
        let (vault, _code) = Vault::create(
            &backend,
            app.device_id().clone(),
            "pass",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        let key_id = "0192f3a0-0000-7000-8000-000000000001";
        let secret_id = "0192f3a0-0000-7000-8000-000000000002";
        let host_id = "0192f3a0-0000-7000-8000-000000000003";
        let ct = crypto::seal(
            vault.dek(),
            format!("secret/{secret_id}").as_bytes(),
            b"-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n",
        )
        .unwrap();
        app.put(
            Collection::Secrets,
            secret_id,
            &json!({"id": secret_id, "kind": "private_key", "ciphertext": ct, "sync": "vault"})
                .to_string(),
        )
        .unwrap();
        app.put(Collection::Identities, key_id, &json!({"id": key_id, "label": "laptop", "key_type": "ed25519", "public_key": "ssh-ed25519 AAAA", "private_key_secret_id": secret_id}).to_string()).unwrap();
        app.put(Collection::Hosts, host_id, &json!({"id": host_id, "label": "web 1", "hostname": "10.0.0.11", "port": 2222, "username": "deploy", "auth": {"kind": "identity", "identity_id": key_id}}).to_string()).unwrap();
        // A second key with the same label, used by a second host.
        let key2 = "0192f3a0-0000-7000-8000-000000000004";
        let secret2 = "0192f3a0-0000-7000-8000-000000000005";
        let host2 = "0192f3a0-0000-7000-8000-000000000006";
        let ct2 = crypto::seal(
            vault.dek(),
            format!("secret/{secret2}").as_bytes(),
            b"second key",
        )
        .unwrap();
        app.put(
            Collection::Secrets,
            secret2,
            &json!({"id": secret2, "kind": "private_key", "ciphertext": ct2, "sync": "vault"})
                .to_string(),
        )
        .unwrap();
        app.put(Collection::Identities, key2, &json!({"id": key2, "label": "laptop", "key_type": "ed25519", "public_key": "ssh-ed25519 BBBB", "private_key_secret_id": secret2}).to_string()).unwrap();
        app.put(Collection::Hosts, host2, &json!({"id": host2, "label": "web 2", "hostname": "10.0.0.12", "auth": {"kind": "identity", "identity_id": key2}}).to_string()).unwrap();
        app.push(&vault).unwrap();

        let creds = Creds { pass: "pass" };
        let unlocked = unlock(&creds, &backend).unwrap().unwrap();

        let text = inspect(&backend, Some(&unlocked)).unwrap();
        assert!(text.contains("hosts       2"), "{text}");
        assert!(text.contains("devices    1"), "{text}");

        let exported = export(&backend, &unlocked, true).unwrap();
        let doc: Value = serde_json::from_str(&exported).unwrap();
        assert_eq!(doc["hosts"][0]["label"], "web 1");
        assert!(doc["secrets"][0]["value"]
            .as_str()
            .unwrap()
            .contains("PRIVATE KEY"));
        let without = export(&backend, &unlocked, false).unwrap();
        assert!(!without.contains("PRIVATE KEY"));

        let keys = dir.join("keys");
        let config = ssh_config(&backend, &unlocked, Some(&keys)).unwrap();
        assert!(
            config.contains("Host web-1\n    HostName 10.0.0.11\n    User deploy\n    Port 2222\n"),
            "{config}"
        );
        assert!(config.contains("IdentityFile "), "{config}");
        assert!(std::fs::read(keys.join("laptop"))
            .unwrap()
            .starts_with(b"-----BEGIN"));
        assert_eq!(std::fs::read(keys.join("laptop-2")).unwrap(), b"second key");
        assert_eq!(config.matches("IdentityFile ").count(), 2, "{config}");
        assert_eq!(
            ssh_config(&backend, &unlocked, Some(&keys)).unwrap(),
            config,
            "a second run finds its own files"
        );

        // A folder with a file of the same name in it, such as ~/.ssh with
        // the user's own key: that file is left alone.
        let ssh = dir.join("dot-ssh");
        std::fs::create_dir_all(&ssh).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::fs::write(ssh.join("laptop"), b"my own key").unwrap();
        let config = ssh_config(&backend, &unlocked, Some(&ssh)).unwrap();
        assert_eq!(std::fs::read(ssh.join("laptop")).unwrap(), b"my own key");
        assert!(std::fs::read(ssh.join("laptop-2"))
            .unwrap()
            .starts_with(b"-----BEGIN"));
        assert_eq!(std::fs::read(ssh.join("laptop-3")).unwrap(), b"second key");
        assert!(
            !config.contains(&format!("{}\n", ssh.join("laptop").display())),
            "{config}"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&ssh.join("laptop-2")), 0o600);
            assert_eq!(
                mode(&ssh),
                0o755,
                "a folder that was there is left as it was"
            );
            assert_eq!(mode(&keys), 0o700);
        }

        // Import a new host and a secret in plain text; the app pulls it back.
        let n = import(&backend, &unlocked, &json!({
            "hosts": [{"id": "0192f3a0-0000-7000-8000-000000000009", "label": "nas", "hostname": "nas.local", "auth": {"kind": "agent"}}],
            "secrets": [{"id": "0192f3a0-0000-7000-8000-00000000000a", "kind": "password", "value": "hunter2"}]
        }).to_string()).unwrap();
        assert_eq!(n, 2);
        app.pull(&vault).unwrap();
        assert_eq!(app.list(Collection::Hosts).unwrap().len(), 3);
        let secret: Value = serde_json::from_str(
            &app.get(Collection::Secrets, "0192f3a0-0000-7000-8000-00000000000a")
                .unwrap()
                .unwrap()
                .json,
        )
        .unwrap();
        assert_eq!(
            decrypt_secret(vault.dek(), "0192f3a0-0000-7000-8000-00000000000a", &secret).as_deref(),
            Some("hunter2")
        );

        let report = sync(&backend, &unlocked).unwrap();
        assert!(report.starts_with("pulled"), "{report}");

        change_passphrase(&backend, &unlocked, "new pass").unwrap();
        assert!(unlock(&Creds { pass: "pass" }, &backend).is_err());
        assert!(unlock(&Creds { pass: "new pass" }, &backend)
            .unwrap()
            .is_some());
        // The device id of the CLI is stable across runs.
        let a = cli_store(&unlocked).unwrap().device_id().clone();
        let b = cli_store(&unlocked).unwrap().device_id().clone();
        assert_eq!(a, b);
        let _ = DeviceId::parse(a.as_str()).unwrap();
        // The CLI's copy is encrypted, not plain SQLite.
        let db = std::fs::read(
            PathBuf::from(std::env::var_os("PROMPTLY_CLI_DATA_DIR").unwrap())
                .join(format!("{}.db", unlocked.manifest.vault_id)),
        )
        .unwrap();
        assert!(!db.starts_with(b"SQLite format 3\0"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_vault_is_a_folder_or_a_place_on_a_server() {
        assert_eq!(
            Location::parse("/home/me/vault").unwrap(),
            Location::Folder(PathBuf::from("/home/me/vault"))
        );
        let Location::Sftp { endpoint, path } =
            Location::parse("sftp://me@nas.local:2222/promptly-vault").unwrap()
        else {
            panic!("not a server vault");
        };
        assert_eq!(
            (
                endpoint.user.as_str(),
                endpoint.host.as_str(),
                endpoint.port
            ),
            ("me", "nas.local", 2222)
        );
        assert_eq!(path, "promptly-vault", "in the login's home folder");
        let Location::Sftp { endpoint, path } =
            Location::parse("sftp://me@nas//srv/vault").unwrap()
        else {
            panic!("not a server vault");
        };
        assert_eq!(endpoint.port, 22);
        assert_eq!(path, "/srv/vault", "a second slash makes it absolute");
        for bad in [
            "sftp://nas/vault",
            "sftp://me@nas",
            "sftp://me@nas/",
            "sftp://@nas/v",
        ] {
            assert!(Location::parse(bad).is_err(), "{bad}");
        }
    }

    struct Server(&'static str);
    impl Place for Server {
        fn location(&self) -> &str {
            self.0
        }
    }

    #[test]
    fn a_server_vault_goes_through_the_apps_sftp_connection() {
        use_test_data_dir();
        // Nothing listens on port 1, so the connection fails at once, and
        // says so in plain words naming the server.
        let err = open(&Server("sftp://me@127.0.0.1:1/vault"))
            .err()
            .expect("nothing is listening")
            .to_string();
        assert!(err.starts_with("127.0.0.1: "), "{err}");
        let err = open(&Server("sftp://127.0.0.1/vault")).err().unwrap();
        assert!(err.to_string().contains("user"), "{err}");
    }

    #[test]
    fn ssh_config_writes_lines_ssh_accepts() {
        use_test_data_dir();
        let backend = promptly_vault::backend::MemoryBackend::default();
        let app = Store::open_in_memory().unwrap();
        let (vault, _code) = Vault::create(
            &backend,
            app.device_id().clone(),
            "pass",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        let hosts = [
            json!({"id": "0192f3a0-0000-7000-8000-000000000021", "label": "web", "hostname": "10.0.0.1",
                   "username": "John Smith", "auth": {"kind": "agent"},
                   "port_forwards": [{"kind": "local", "bind_host": "::1", "bind_port": 8080,
                                      "target_host": "fe80::1", "target_port": 80}]}),
            json!({"id": "0192f3a0-0000-7000-8000-000000000022", "label": "Web", "hostname": "10.0.0.2",
                   "auth": {"kind": "agent"}}),
            json!({"id": "0192f3a0-0000-7000-8000-000000000023", "label": "db*", "hostname": "10.0.0.3",
                   "auth": {"kind": "agent"}, "jump_host_id": "0192f3a0-0000-7000-8000-000000000022"}),
        ];
        for h in &hosts {
            app.put(Collection::Hosts, h["id"].as_str().unwrap(), &h.to_string())
                .unwrap();
        }
        app.push(&vault).unwrap();
        let unlocked = unlock(&Creds { pass: "pass" }, &backend).unwrap().unwrap();
        let config = ssh_config(&backend, &unlocked, None).unwrap();
        assert!(config.contains("    User \"John Smith\"\n"), "{config}");
        assert!(
            config.contains("    LocalForward [::1]:8080 [fe80::1]:80\n"),
            "{config}"
        );
        assert!(
            config.contains("\nHost web\n    HostName 10.0.0.1\n"),
            "{config}"
        );
        assert!(
            config.contains("\nHost Web-2\n    HostName 10.0.0.2\n"),
            "{config}"
        );
        assert!(config.contains("\nHost db-\n"), "{config}");
        assert!(config.contains("    ProxyJump Web-2\n"), "{config}");
    }

    #[test]
    fn ssh_reads_back_every_value_as_it_was() {
        let values = [
            "plain",
            "John Smith",
            "O'Brien",
            "/home/jason/O'Brien/keys/key",
            "/keys/a \"q\" b\\",
            r"C:\Users\me\.ssh\key",
            r"\\server\share\key",
            "#1",
        ];
        assert_eq!(config_value("plain"), "plain");
        assert_eq!(config_value("O'Brien"), "\"O'Brien\"");
        assert_eq!(config_value(r"C:\Users\me"), r"C:\Users\me");
        assert_eq!(config_value("a\nb"), "ab");
        // And ssh itself, where it is installed, reads each one back.
        if std::process::Command::new("ssh")
            .arg("-V")
            .output()
            .is_err()
        {
            return;
        }
        let dir = std::env::temp_dir().join(format!("promptly-cli-quote-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for value in values {
            let file = dir.join("config");
            std::fs::write(
                &file,
                format!(
                    "Host t\n    User {}\n    IdentityFile {}\nHost other\n    Port 2222\n",
                    config_value(value),
                    config_value(value)
                ),
            )
            .unwrap();
            let out = std::process::Command::new("ssh")
                .arg("-G")
                .arg("-F")
                .arg(&file)
                .arg("t")
                .output()
                .unwrap();
            let printed = String::from_utf8_lossy(&out.stdout);
            assert!(
                out.status.success(),
                "{value}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            assert!(
                printed.contains(&format!("\nuser {value}\n")),
                "{value}: {printed}"
            );
            assert!(
                printed.contains(&format!("\nidentityfile {value}\n")),
                "{value}: {printed}"
            );
        }
    }

    #[test]
    fn every_command_works_on_any_storage() {
        use_test_data_dir();
        // Storage that is not a folder, as a server is not.
        let backend = promptly_vault::backend::MemoryBackend::default();
        let app = Store::open_in_memory().unwrap();
        let (vault, _code) = Vault::create(
            &backend,
            app.device_id().clone(),
            "pass",
            KdfParams::fast_for_tests(),
        )
        .unwrap();
        device_record(&app, "laptop");
        let host_id = "0192f3a0-0000-7000-8000-000000000011";
        app.put(
            Collection::Hosts,
            host_id,
            &json!({"id": host_id, "label": "web", "hostname": "10.0.0.1", "auth": {"kind": "agent"}})
                .to_string(),
        )
        .unwrap();
        app.setting_set("terminal_bell", r#""off""#).unwrap();
        app.push(&vault).unwrap();

        let unlocked = unlock(&Creds { pass: "pass" }, &backend).unwrap().unwrap();
        let text = inspect(&backend, Some(&unlocked)).unwrap();
        assert!(text.contains("hosts       1"), "{text}");
        assert!(text.contains("settings    1"), "{text}");
        let doc: Value =
            serde_json::from_str(&export(&backend, &unlocked, false).unwrap()).unwrap();
        assert_eq!(doc["hosts"][0]["label"], "web");
        assert_eq!(doc["settings"][0]["terminal_bell"], "off");
        assert!(doc["hosts"][0]["created_at"].is_string(), "{doc}");
        assert!(ssh_config(&backend, &unlocked, None)
            .unwrap()
            .contains("Host web\n"));
        let nas = "0192f3a0-0000-7000-8000-000000000012";
        let n = import(
            &backend,
            &unlocked,
            &json!({"hosts": [{"id": nas, "label": "nas", "hostname": "nas.local", "auth": {"kind": "agent"}}]})
                .to_string(),
        )
        .unwrap();
        assert_eq!(n, 1);
        assert!(sync(&backend, &unlocked).unwrap().starts_with("pulled"));
        app.pull(&vault).unwrap();
        assert!(app.get(Collection::Hosts, nas).unwrap().is_some());
        assert!(list_devices(&backend, &unlocked)
            .unwrap()
            .contains("laptop (linux)"));

        change_passphrase(&backend, &unlocked, "new pass").unwrap();
        assert!(unlock(&Creds { pass: "pass" }, &backend).is_err());
        let unlocked = unlock(&Creds { pass: "new pass" }, &backend)
            .unwrap()
            .unwrap();
        let code = rotate_dek(&backend, &unlocked, "newer pass").unwrap();
        assert!(RecoveryCode::parse(&code).is_some());
        let unlocked = unlock(&Creds { pass: "newer pass" }, &backend)
            .unwrap()
            .unwrap();
        assert_eq!(
            remove_device(&backend, &unlocked, "laptop").unwrap().name,
            "laptop"
        );
    }
}
