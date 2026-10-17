//! What each subcommand does, as functions the tests can call.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
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

/// The data key plus where it came from.
pub struct Unlocked {
    pub dek: Dek,
    pub manifest: Manifest,
}

/// Unlock the vault in `folder`. Returns `None` only when nothing was given
/// and no terminal is available to ask on.
pub fn unlock(args: &(impl Credentials + HasFolder)) -> Result<Option<Unlocked>> {
    let backend = LocalFolder::new(args.folder());
    let manifest = Vault::read_manifest(&backend).map_err(|e| anyhow!("{e}"))?;
    let dek = if args.wants_recovery_code() {
        let typed;
        let code = match args.recovery_code() {
            Some(c) => c,
            None if std::io::IsTerminal::is_terminal(&std::io::stdin()) => {
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
    } else if std::io::IsTerminal::is_terminal(&std::io::stdin()) {
        let p = zeroize::Zeroizing::new(rpassword::prompt_password("Vault passphrase: ")?);
        manifest.unlock(&p)?
    } else {
        return Ok(None);
    };
    Ok(Some(Unlocked { dek, manifest }))
}

pub trait HasFolder {
    fn folder(&self) -> &Path;
}

impl<T: Credentials> HasFolder for T
where
    T: FolderPath,
{
    fn folder(&self) -> &Path {
        FolderPath::folder_path(self)
    }
}

pub trait FolderPath {
    fn folder_path(&self) -> &Path;
}

/// Where this tool keeps its own device state. One store per vault,
/// encrypted with a key derived from the vault key, so it opens only for
/// someone who could unlock the vault anyway. A key change made here
/// re-encrypts it; one made on another device leaves it unreadable, so it
/// is set aside and this tool joins again as a new device, getting back
/// everything but what it kept on this device only.
fn cli_store(folder: &Path, unlocked: &Unlocked) -> Result<Store> {
    let base = std::env::var_os("PROMPTLY_CLI_DATA_DIR")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .or_else(|| {
                    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local").join("share"))
                })
                .map(|d| d.join("promptly-cli"))
        })
        .unwrap_or_else(|| folder.join(".promptly-cli"));
    let path = base.join(format!("{}.db", unlocked.manifest.vault_id));
    Ok(Store::open(&path, Some(&DbKey::derive(&unlocked.dek)))?)
}

/// The records kept on this tool's device last time (see
/// [`promptly_vault::policy`]), under the same key the app uses.
const META_KEPT: &str = "kept_on_device";
/// Set while a snapshot under a new key is still to be written.
const META_SNAPSHOT_DUE: &str = "snapshot_due";
/// The data key from before a key change, kept while the secrets sealed
/// under it are still to be locked again under the new one.
const META_RESEAL_FROM: &str = "reseal_from";

fn open_vault<'a>(backend: &'a LocalFolder, store: &Store, unlocked: &Unlocked) -> Vault<'a> {
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
         (or ~/.local/share/promptly-cli) and it joins as a new device."
    );
    Ok(())
}

/// Write what changed here: the records kept on this device stay out (and
/// one going back into the vault is written again in full, newer than its
/// tombstone), then a snapshot when one is due or the folder has grown.
fn push_all<'a>(store: &Store, vault: Vault<'a>) -> Result<(Vault<'a>, Option<u64>)> {
    ensure_not_removed(store)?;
    if let Some(old) = store.meta_get(META_RESEAL_FROM)? {
        if let Ok(old) = serde_json::from_str::<[u8; 32]>(&old) {
            reseal(store, &Dek(old), vault.dek())?;
        }
        store.meta_delete(META_RESEAL_FROM)?;
    }
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
fn fresh<'a>(
    backend: &'a LocalFolder,
    folder: &Path,
    unlocked: &Unlocked,
) -> Result<(Store, Vault<'a>)> {
    let store = cli_store(folder, unlocked)?;
    let vault = open_vault(backend, &store, unlocked);
    let report = store.pull(&vault)?;
    for w in report.warnings {
        eprintln!("warning: {w}");
    }
    Ok((store, vault))
}

pub fn inspect(folder: &Path, unlocked: Option<&Unlocked>) -> Result<String> {
    let backend = LocalFolder::new(folder);
    let manifest = Vault::read_manifest(&backend).map_err(|e| anyhow!("{e}"))?;
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
        let (store, _vault) = fresh(&backend, folder, unlocked)?;
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

pub fn export(folder: &Path, unlocked: &Unlocked, with_secrets: bool) -> Result<String> {
    let backend = LocalFolder::new(folder);
    let (store, _vault) = fresh(&backend, folder, unlocked)?;
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
pub fn import(folder: &Path, unlocked: &Unlocked, text: &str) -> Result<usize> {
    let doc: Value = serde_json::from_str(text).context("the file is not JSON")?;
    let backend = LocalFolder::new(folder);
    let (store, vault) = fresh(&backend, folder, unlocked)?;
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

pub fn sync(folder: &Path, unlocked: &Unlocked) -> Result<String> {
    let backend = LocalFolder::new(folder);
    let store = cli_store(folder, unlocked)?;
    let vault = open_vault(&backend, &store, unlocked);
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
pub fn ssh_config(folder: &Path, unlocked: &Unlocked, keys_dir: Option<&Path>) -> Result<String> {
    let backend = LocalFolder::new(folder);
    let (store, _vault) = fresh(&backend, folder, unlocked)?;
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
    let alias_of = |label: &str| -> String {
        label
            .chars()
            .map(|c| if c.is_whitespace() { '-' } else { c })
            .collect()
    };
    let aliases: BTreeMap<String, String> = hosts
        .iter()
        .map(|h| (h.id.to_string(), alias_of(&h.label)))
        .collect();

    let mut out =
        String::from("# Generated by promptly from the vault. Edit the vault, not this file.\n");
    // Each key is written once, under a file name no other key has.
    let mut key_files: BTreeMap<String, PathBuf> = BTreeMap::new();
    for h in hosts {
        let alias = alias_of(&h.label);
        out.push_str(&format!("\nHost {alias}\n    HostName {}\n", h.hostname));
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
                format!("{}:{}", f.bind_host, f.bind_port)
            };
            match f.kind {
                ForwardKind::Local => out.push_str(&format!(
                    "    LocalForward {bind} {}:{}\n",
                    f.target_host, f.target_port
                )),
                ForwardKind::Remote => out.push_str(&format!(
                    "    RemoteForward {bind} {}:{}\n",
                    f.target_host, f.target_port
                )),
                ForwardKind::Dynamic => out.push_str(&format!("    DynamicForward {bind}\n")),
            }
        }
        if !h.username.is_empty() {
            out.push_str(&format!("    User {}\n", h.username));
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
                                    let mut path = dir.join(&safe);
                                    let mut n = 2;
                                    while key_files.values().any(|p| *p == path) {
                                        path = dir.join(format!("{safe}-{n}"));
                                        n += 1;
                                    }
                                    write_private(&path, value.as_bytes())?;
                                    key_files.insert(identity_id.to_string(), path.clone());
                                    path
                                }
                            };
                            out.push_str(&format!("    IdentityFile {}\n", path.display()));
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

fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
        }
    }
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    use std::io::Write;
    opts.open(path)?.write_all(bytes)?;
    Ok(())
}

pub fn change_passphrase(folder: &Path, unlocked: &Unlocked, new_passphrase: &str) -> Result<()> {
    let backend = LocalFolder::new(folder);
    let mut manifest = unlocked.manifest.clone();
    // Detect a race: the manifest must still be the one we unlocked.
    let current = Vault::read_manifest(&backend).map_err(|e| anyhow!("{e}"))?;
    anyhow::ensure!(
        current == manifest,
        "the vault's manifest changed under us; try again"
    );
    manifest.change_passphrase(&unlocked.dek, new_passphrase);
    // Key stretching takes a moment; look again right before writing, so
    // a change made meanwhile on another device is not overwritten.
    let current = Vault::read_manifest(&backend).map_err(|e| anyhow!("{e}"))?;
    anyhow::ensure!(
        current == unlocked.manifest,
        "the vault's manifest changed under us; try again"
    );
    // Write the new manifest beside the old one and rename it over, so the
    // folder always holds one whole manifest, old or new, whatever happens.
    let target = folder.join(promptly_vault::sync::MANIFEST_NAME);
    let tmp = folder.join(format!(".vault.json.tmp-{}", std::process::id()));
    {
        let mut f = std::fs::File::create(&tmp)?;
        std::io::Write::write_all(&mut f, manifest.to_json().as_bytes())?;
        f.sync_all()?;
    }
    if let Err(e) = std::fs::rename(&tmp, &target) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.into());
    }
    Ok(())
}

/// Give the vault a new data key (VAULT.md section 11), wrapped under
/// `new_passphrase` and a new recovery code, which is returned. Everything
/// is synced first; the secrets are encrypted again and a snapshot under
/// the new key replaces this tool's files. Whoever has only the old key,
/// a removed device included, can read nothing written from now on.
pub fn rotate_dek(folder: &Path, unlocked: &Unlocked, new_passphrase: &str) -> Result<String> {
    anyhow::ensure!(
        unlocked.manifest.unlock(new_passphrase).is_err(),
        "choose a passphrase the vault does not have now: whoever knows the current one could open the new key with it"
    );
    let backend = LocalFolder::new(folder);
    let (store, vault) = fresh(&backend, folder, unlocked)?;
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
    let (vault, _manifest, code) = vault
        .rotate(&known, new_passphrase, params)
        .map_err(|e| anyhow!("{e}"))?;
    // The vault has the new key from here, so the new code must reach the
    // person whatever follows. What fails is reported, and the next run
    // with the new passphrase finishes it.
    let mut trouble = Vec::new();
    // This tool's own records are locked with a key made from the vault's.
    if let Err(e) = store.rekey(&DbKey::derive(vault.dek())) {
        trouble.push(format!(
            "this tool's records could not be locked with the new key: {e}"
        ));
    }
    let finished = (|| -> Result<()> {
        store.meta_set(META_RESEAL_FROM, &json!(unlocked.dek.0).to_string())?;
        store.meta_set(META_SNAPSHOT_DUE, "true")?;
        push_all(&store, vault)?;
        Ok(())
    })();
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

/// Lock every secret record sealed under `old` again under `new`. Records
/// `new` opens already are left as they are, so this can run again after
/// stopping part way.
fn reseal(store: &Store, old: &Dek, new: &Dek) -> Result<()> {
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
        let Ok(plain) = crypto::open(old, aad.as_bytes(), &ct) else {
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
pub fn list_devices(folder: &Path, unlocked: &Unlocked) -> Result<String> {
    let backend = LocalFolder::new(folder);
    let (store, _vault) = fresh(&backend, folder, unlocked)?;
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

/// Mark a device removed (VAULT.md section 11), found by its id or its
/// name. Every device then ignores what it writes after the last of its
/// files read here, and it stops syncing once it finds out. Returns its
/// name. It keeps the copy it has: rotate the key as well if it was lost.
pub fn remove_device(folder: &Path, unlocked: &Unlocked, who: &str) -> Result<String> {
    let backend = LocalFolder::new(folder);
    let (store, vault) = fresh(&backend, folder, unlocked)?;
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
    anyhow::ensure!(
        record.get(policy::REMOVED_AFTER).is_none_or(Value::is_null),
        "that device was removed already"
    );
    let after = store
        .sync_state()?
        .markers
        .get(&device)
        .map_or(0, Marker::highest);
    record[policy::REMOVED_AT] = json!(promptly_vault::ops::now_rfc3339());
    record[policy::REMOVED_AFTER] = json!(after);
    store.put(Col::Devices, &record_id_of(&device), &record.to_string())?;
    push_all(&store, vault)?;
    Ok(record["name"]
        .as_str()
        .filter(|n| !n.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| record_id_of(&device)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use promptly_vault::{DeviceId, KdfParams};

    struct Creds<'a> {
        folder: &'a Path,
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
    impl FolderPath for Creds<'_> {
        fn folder_path(&self) -> &Path {
            self.folder
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

        let creds = Creds {
            folder: &vault_dir,
            pass: "pass",
        };
        let unlocked = unlock(&creds).unwrap().unwrap();
        let list = list_devices(&vault_dir, &unlocked).unwrap();
        assert!(list.contains("laptop (linux)"), "{list}");
        assert!(list.contains("phone (linux)"), "{list}");

        // Not this tool, nor a name nobody has.
        let me = cli_store(&vault_dir, &unlocked)
            .unwrap()
            .device_id()
            .clone();
        assert!(remove_device(&vault_dir, &unlocked, &record_id_of(&me)).is_err());
        assert!(remove_device(&vault_dir, &unlocked, "tablet").is_err());

        // The phone is removed: the laptop stops listening to it.
        assert_eq!(
            remove_device(&vault_dir, &unlocked, "Phone").unwrap(),
            "phone"
        );
        let list = list_devices(&vault_dir, &unlocked).unwrap();
        assert!(
            list.contains("phone (linux), joined 2026-01-01, removed "),
            "{list}"
        );
        assert!(remove_device(&vault_dir, &unlocked, "phone").is_err());
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
        import(&vault_dir, &unlocked, &json!({
            "hosts": [{"id": local, "label": "here only", "hostname": "h", "sync": "local_only"}]
        }).to_string())
        .unwrap();
        laptop.pull(&vault).unwrap();
        assert!(laptop.get(Collection::Hosts, local).unwrap().is_none());

        // A new key: the old one opens nothing new, the new passphrase and
        // code open the vault, and everything is there under the new key.
        assert!(
            rotate_dek(&vault_dir, &unlocked, "pass").is_err(),
            "not the same passphrase"
        );
        let code = rotate_dek(&vault_dir, &unlocked, "new pass").unwrap();
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
        let creds = Creds {
            folder: &vault_dir,
            pass: "new pass",
        };
        let renewed = unlock(&creds).unwrap().unwrap();
        let again = cli_store(&vault_dir, &renewed).unwrap();
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
        again
            .meta_set(META_RESEAL_FROM, &json!(unlocked.dek.0).to_string())
            .unwrap();
        drop(again);
        import(&vault_dir, &renewed, "{}").unwrap();
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
        assert!(cli_store(&vault_dir, &renewed)
            .unwrap()
            .meta_get(META_RESEAL_FROM)
            .unwrap()
            .is_none());
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

        let creds = Creds {
            folder: &vault_dir,
            pass: "pass",
        };
        let unlocked = unlock(&creds).unwrap().unwrap();

        let text = inspect(&vault_dir, Some(&unlocked)).unwrap();
        assert!(text.contains("hosts       2"), "{text}");
        assert!(text.contains("devices    1"), "{text}");

        let exported = export(&vault_dir, &unlocked, true).unwrap();
        let doc: Value = serde_json::from_str(&exported).unwrap();
        assert_eq!(doc["hosts"][0]["label"], "web 1");
        assert!(doc["secrets"][0]["value"]
            .as_str()
            .unwrap()
            .contains("PRIVATE KEY"));
        let without = export(&vault_dir, &unlocked, false).unwrap();
        assert!(!without.contains("PRIVATE KEY"));

        let keys = dir.join("keys");
        let config = ssh_config(&vault_dir, &unlocked, Some(&keys)).unwrap();
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

        // Import a new host and a secret in plain text; the app pulls it back.
        let n = import(&vault_dir, &unlocked, &json!({
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

        let report = sync(&vault_dir, &unlocked).unwrap();
        assert!(report.starts_with("pulled"), "{report}");

        change_passphrase(&vault_dir, &unlocked, "new pass").unwrap();
        assert!(unlock(&Creds {
            folder: &vault_dir,
            pass: "pass"
        })
        .is_err());
        assert!(unlock(&Creds {
            folder: &vault_dir,
            pass: "new pass"
        })
        .unwrap()
        .is_some());
        // The device id of the CLI is stable across runs.
        let a = cli_store(&vault_dir, &unlocked)
            .unwrap()
            .device_id()
            .clone();
        let b = cli_store(&vault_dir, &unlocked)
            .unwrap()
            .device_id()
            .clone();
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
}
