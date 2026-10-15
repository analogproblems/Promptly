//! Bringing hosts in from elsewhere. Today: OpenSSH's `~/.ssh/config`, with
//! the keys it names.

use std::collections::BTreeMap;

use flutter_rust_bridge::frb;
use promptly_ssh::keys::inspect;
use promptly_store::Collection;
use promptly_vault::model::{Auth, Host, Identity, KeyType};

use crate::api::store::{record_put, secret_put, store};

/// One host from the config, as the import dialog shows it.
pub struct SshConfigHost {
    pub alias: String,
    pub hostname: String,
    pub user: String,
    pub port: u16,
    /// The first key file the config names for it, if any.
    pub identity_file: Option<String>,
    /// Whether that file can be read here.
    pub key_readable: bool,
    pub proxy_jump: Option<String>,
    /// A saved host with this label exists already.
    pub already_imported: bool,
}

pub struct ImportReport {
    pub hosts: u32,
    pub keys: u32,
    /// Aliases that could not be imported, with why.
    pub skipped: Vec<String>,
}

fn existing_labels() -> BTreeMap<String, String> {
    store()
        .ok()
        .and_then(|s| s.list(Collection::Hosts).ok())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|r| {
            serde_json::from_str::<Host>(&r.json)
                .ok()
                .map(|h| (h.label, h.id.to_string()))
        })
        .collect()
}

/// The hosts in `~/.ssh/config`, or none when there is no config.
#[frb(sync)]
pub fn ssh_config_hosts() -> Vec<SshConfigHost> {
    let existing = existing_labels();
    promptly_ssh::load_ssh_config()
        .unwrap_or_default()
        .into_iter()
        .map(|h| {
            let file = h.identity_files.first().cloned();
            SshConfigHost {
                already_imported: existing.contains_key(&h.alias),
                hostname: h.hostname,
                user: h.user.unwrap_or_default(),
                port: h.port.unwrap_or(22),
                key_readable: file.as_ref().is_some_and(|f| std::fs::metadata(f).is_ok()),
                identity_file: file.map(|f| f.display().to_string()),
                proxy_jump: h.proxy_jump,
                alias: h.alias,
            }
        })
        .collect()
}

/// Import the named hosts. A key file becomes an identity (one per file,
/// reused when its public half is already saved) with the private key as a
/// secret; a host without a key uses the SSH agent. Jump hosts are linked
/// when both ends are saved.
#[frb(sync)]
pub fn ssh_config_import(aliases: Vec<String>) -> Result<ImportReport, String> {
    let store = store()?;
    let config = promptly_ssh::load_ssh_config().unwrap_or_default();
    let mut report = ImportReport {
        hosts: 0,
        keys: 0,
        skipped: Vec::new(),
    };
    // Identities already saved, by public key, so a key is never stored twice.
    let mut identities_by_public: BTreeMap<String, uuid::Uuid> = store
        .list(Collection::Identities)
        .map_err(|e| e.to_string())?
        .into_iter()
        .filter_map(|r| serde_json::from_str::<Identity>(&r.json).ok())
        .map(|i| (i.public_key.trim().to_string(), i.id))
        .collect();
    let mut identity_by_file: BTreeMap<String, uuid::Uuid> = BTreeMap::new();
    let mut labels = existing_labels();

    let mut imported: Vec<(String, Host, Option<String>)> = Vec::new();
    for alias in &aliases {
        let Some(h) = config.iter().find(|c| &c.alias == alias) else {
            report.skipped.push(format!("{alias}: not in the config"));
            continue;
        };
        if labels.contains_key(alias) {
            report.skipped.push(format!("{alias}: already saved"));
            continue;
        }
        let mut host = Host::new(alias.clone(), h.hostname.clone());
        host.username = h.user.clone().unwrap_or_default();
        if let Some(p) = h.port {
            host.port = p;
        }
        if let Some(k) = h.keepalive_seconds {
            host.keepalive_seconds = k;
        }
        host.agent_forwarding = h.forward_agent;
        host.port_forwards = h
            .forwards
            .iter()
            .map(|f| promptly_vault::model::PortForward {
                kind: match f.kind {
                    promptly_ssh::ConfigForwardKind::Local => {
                        promptly_vault::model::ForwardKind::Local
                    }
                    promptly_ssh::ConfigForwardKind::Remote => {
                        promptly_vault::model::ForwardKind::Remote
                    }
                    promptly_ssh::ConfigForwardKind::Dynamic => {
                        promptly_vault::model::ForwardKind::Dynamic
                    }
                },
                bind_host: f.bind_host.clone(),
                bind_port: f.bind_port,
                target_host: f.target_host.clone(),
                target_port: f.target_port,
                auto: true,
            })
            .collect();
        host.auth = Auth::Agent;
        // The first key file that can be read.
        for file in &h.identity_files {
            let path = file.display().to_string();
            if let Some(id) = identity_by_file.get(&path) {
                host.auth = Auth::Identity { identity_id: *id };
                break;
            }
            let Ok(text) = std::fs::read_to_string(file) else {
                continue;
            };
            let Ok(info) = inspect(&text, None) else {
                report
                    .skipped
                    .push(format!("{alias}: {path} is not a usable private key"));
                continue;
            };
            let Some(public) = info.public_openssh.as_deref().map(|p| p.trim().to_string()) else {
                report.skipped.push(format!(
                    "{alias}: {path} hides its public key until unlocked; import it on the Keys tab with its passphrase"
                ));
                continue;
            };
            let id = if let Some(existing) = identities_by_public.get(&public) {
                *existing
            } else {
                let id = promptly_vault::model::new_id();
                let secret_id = promptly_vault::model::new_id();
                secret_put(secret_id.to_string(), "private_key".into(), text.clone())?;
                let identity = Identity {
                    id,
                    label: file
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_else(|| alias.clone()),
                    key_type: match info.kind.as_str() {
                        "ed25519" => KeyType::Ed25519,
                        k if k.starts_with("ecdsa") => KeyType::Ecdsa,
                        _ => KeyType::Rsa,
                    },
                    public_key: public.clone(),
                    private_key_secret_id: Some(secret_id),
                    hardware: None,
                    passphrase_secret_id: None,
                    sync: Default::default(),
                };
                record_put(
                    "identities".into(),
                    id.to_string(),
                    serde_json::to_string(&identity).map_err(|e| e.to_string())?,
                )?;
                identities_by_public.insert(public, id);
                report.keys += 1;
                id
            };
            identity_by_file.insert(path, id);
            host.auth = Auth::Identity { identity_id: id };
            break;
        }
        labels.insert(alias.clone(), host.id.to_string());
        imported.push((alias.clone(), host, h.proxy_jump.clone()));
    }
    // Jump hosts by alias, now that every id is known.
    for (_, host, jump) in &mut imported {
        if let Some(j) = jump.as_deref().and_then(|j| labels.get(j)) {
            host.jump_host_id = uuid::Uuid::parse_str(j).ok();
        }
    }
    for (_, host, _) in &imported {
        record_put(
            "hosts".into(),
            host.id.to_string(),
            serde_json::to_string(host).map_err(|e| e.to_string())?,
        )?;
        report.hosts += 1;
    }
    Ok(report)
}
