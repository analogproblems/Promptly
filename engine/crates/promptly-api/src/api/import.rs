//! Bringing hosts in from elsewhere: OpenSSH's `~/.ssh/config` with the
//! keys it names, and CSV files such as the one Termius exports.

use std::collections::BTreeMap;

use flutter_rust_bridge::frb;
use promptly_ssh::keys::inspect;
use promptly_store::Collection;
use promptly_vault::model::{Auth, Group, Host, Identity, KeyType};

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

// ---- CSV -------------------------------------------------------------------

/// One row of a CSV file, as the import dialog shows it.
#[derive(Debug)]
pub struct CsvHost {
    pub label: String,
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub has_password: bool,
    /// "Work/Databases" style group path, when the file names one.
    pub group: Option<String>,
    pub tags: Vec<String>,
    /// A saved host with this label exists already.
    pub already_imported: bool,
}

/// Split RFC 4180 text into rows of fields. Quotes may hold commas and line
/// breaks; a doubled quote is a literal one. Tabs separate fields when the
/// first line has tabs and no commas.
fn csv_rows(text: &str) -> Vec<Vec<String>> {
    let first = text.lines().next().unwrap_or("");
    let sep = if first.contains('\t') && !first.contains(',') {
        '\t'
    } else if first.contains(';') && !first.contains(',') {
        ';'
    } else {
        ','
    };
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if quoted {
            if c == '"' {
                if chars.peek() == Some(&'"') {
                    field.push('"');
                    chars.next();
                } else {
                    quoted = false;
                }
            } else {
                field.push(c);
            }
        } else if c == '"' {
            quoted = true;
        } else if c == sep {
            row.push(std::mem::take(&mut field));
        } else if c == '\n' || c == '\r' {
            if c == '\r' && chars.peek() == Some(&'\n') {
                chars.next();
            }
            row.push(std::mem::take(&mut field));
            if row.iter().any(|f| !f.trim().is_empty()) {
                rows.push(std::mem::take(&mut row));
            } else {
                row.clear();
            }
        } else {
            field.push(c);
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        if row.iter().any(|f| !f.trim().is_empty()) {
            rows.push(row);
        }
    }
    rows
}

/// Which column holds what, from the header line.
struct CsvColumns {
    label: Option<usize>,
    hostname: usize,
    port: Option<usize>,
    username: Option<usize>,
    password: Option<usize>,
    group: Option<usize>,
    tags: Option<usize>,
    protocol: Option<usize>,
}

fn csv_columns(header: &[String]) -> Result<CsvColumns, String> {
    let norm: Vec<String> = header
        .iter()
        .map(|h| {
            h.trim()
                .to_ascii_lowercase()
                .chars()
                .filter(|c| c.is_ascii_alphanumeric())
                .collect()
        })
        .collect();
    let find = |names: &[&str]| norm.iter().position(|n| names.contains(&n.as_str()));
    let hostname = find(&[
        "hostname", "host", "address", "ip", "hostnameip", "ipaddress", "server", "hostaddress",
    ])
    .ok_or_else(|| {
        "the first line must name the columns, and one of them must be Hostname (also understood: Label, Port, Username, Password, Group, Tags)".to_string()
    })?;
    Ok(CsvColumns {
        label: find(&["label", "name", "alias", "title", "displayname"]),
        hostname,
        port: find(&["port"]),
        username: find(&["username", "user", "login", "sshuser"]),
        password: find(&["password", "pass", "sshpassword"]),
        group: find(&["group", "groups", "folder", "parentgroup", "path"]),
        tags: find(&["tags", "tag", "labels"]),
        protocol: find(&["protocol", "type"]),
    })
}

#[derive(Debug)]
struct CsvParsed {
    hosts: Vec<CsvHost>,
    passwords: Vec<Option<String>>,
}

fn csv_parse(text: &str) -> Result<CsvParsed, String> {
    let rows = csv_rows(text.trim_start_matches('\u{feff}'));
    let Some(header) = rows.first() else {
        return Err("the file is empty".into());
    };
    let cols = csv_columns(header)?;
    let existing = existing_labels();
    let cell = |row: &[String], i: Option<usize>| -> String {
        i.and_then(|i| row.get(i))
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    };
    let mut hosts = Vec::new();
    let mut passwords = Vec::new();
    for row in rows.iter().skip(1) {
        let hostname = cell(row, Some(cols.hostname));
        if hostname.is_empty() {
            continue;
        }
        let protocol = cell(row, cols.protocol).to_ascii_lowercase();
        if !protocol.is_empty() && protocol != "ssh" {
            continue;
        }
        let label = {
            let l = cell(row, cols.label);
            if l.is_empty() {
                hostname.clone()
            } else {
                l
            }
        };
        let port = cell(row, cols.port)
            .parse()
            .ok()
            .filter(|p| *p > 0)
            .unwrap_or(22);
        let password = cell(row, cols.password);
        let group = cell(row, cols.group);
        let tags: Vec<String> = cell(row, cols.tags)
            .split([',', ';', ' '])
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .collect();
        hosts.push(CsvHost {
            already_imported: existing.contains_key(&label),
            label,
            hostname,
            port,
            username: cell(row, cols.username),
            has_password: !password.is_empty(),
            group: if group.is_empty() { None } else { Some(group) },
            tags,
        });
        passwords.push(if password.is_empty() {
            None
        } else {
            Some(password)
        });
    }
    Ok(CsvParsed { hosts, passwords })
}

/// The hosts a CSV file describes, without saving anything.
#[frb(sync)]
pub fn csv_hosts_preview(text: String) -> Result<Vec<CsvHost>, String> {
    Ok(csv_parse(&text)?.hosts)
}

/// Import the rows at these indexes of the preview. A password becomes a
/// saved secret; a group path such as "Work/Databases" is created level by
/// level when missing.
#[frb(sync)]
pub fn csv_hosts_import(text: String, rows: Vec<u32>) -> Result<ImportReport, String> {
    let parsed = csv_parse(&text)?;
    let store = store()?;
    let mut report = ImportReport {
        hosts: 0,
        keys: 0,
        skipped: Vec::new(),
    };
    let mut labels = existing_labels();
    // Groups by (parent id, label), so paths reuse what exists.
    let mut groups: BTreeMap<(Option<uuid::Uuid>, String), uuid::Uuid> = store
        .list(Collection::Groups)
        .map_err(|e| e.to_string())?
        .into_iter()
        .filter_map(|r| serde_json::from_str::<Group>(&r.json).ok())
        .map(|g| ((g.parent_id, g.label.clone()), g.id))
        .collect();
    for index in rows {
        let Some(h) = parsed.hosts.get(index as usize) else {
            report.skipped.push(format!("row {index}: not in the file"));
            continue;
        };
        if labels.contains_key(&h.label) {
            report.skipped.push(format!("{}: already saved", h.label));
            continue;
        }
        let mut host = Host::new(h.label.clone(), h.hostname.clone());
        host.port = h.port;
        host.username = h.username.clone();
        host.tags = h.tags.clone();
        if let Some(path) = &h.group {
            let mut parent: Option<uuid::Uuid> = None;
            for part in path.split('/').map(str::trim).filter(|p| !p.is_empty()) {
                let key = (parent, part.to_string());
                let id = match groups.get(&key) {
                    Some(id) => *id,
                    None => {
                        let group = Group {
                            id: promptly_vault::model::new_id(),
                            label: part.to_string(),
                            parent_id: parent,
                            color: None,
                            defaults: Default::default(),
                        };
                        record_put(
                            "groups".into(),
                            group.id.to_string(),
                            serde_json::to_string(&group).map_err(|e| e.to_string())?,
                        )?;
                        groups.insert(key, group.id);
                        group.id
                    }
                };
                parent = Some(id);
            }
            host.group_id = parent;
        }
        host.auth = match &parsed.passwords[index as usize] {
            Some(password) => {
                let secret_id = promptly_vault::model::new_id();
                secret_put(secret_id.to_string(), "password".into(), password.clone())?;
                Auth::Password {
                    password_secret_id: secret_id,
                }
            }
            None => Auth::Interactive,
        };
        record_put(
            "hosts".into(),
            host.id.to_string(),
            serde_json::to_string(&host).map_err(|e| e.to_string())?,
        )?;
        labels.insert(h.label.clone(), host.id.to_string());
        report.hosts += 1;
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn csv_rows_handle_quotes_and_line_endings() {
        let rows = csv_rows("a,b\r\n\"x, y\",\"say \"\"hi\"\"\"\n\n1,2");
        assert_eq!(
            rows,
            vec![vec!["a", "b"], vec!["x, y", "say \"hi\""], vec!["1", "2"]]
        );
        let tabs = csv_rows("Label\tHostname\nweb\t10.0.0.1\n");
        assert_eq!(tabs[1], vec!["web", "10.0.0.1"]);
    }

    #[test]
    fn termius_columns_are_understood() {
        let text = "Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password\n\
                    Work/Web,web-1,prod web,10.0.0.1,ssh,2222,deploy,s3cret\n\
                    ,,,10.0.0.2,telnet,23,,\n\
                    ,,,db.example,ssh,,root,\n";
        let parsed = csv_parse(text).unwrap();
        assert_eq!(parsed.hosts.len(), 2, "the telnet row is left out");
        let web = &parsed.hosts[0];
        assert_eq!(web.label, "web-1");
        assert_eq!(web.hostname, "10.0.0.1");
        assert_eq!(web.port, 2222);
        assert_eq!(web.username, "deploy");
        assert!(web.has_password);
        assert_eq!(web.group.as_deref(), Some("Work/Web"));
        assert_eq!(web.tags, vec!["prod", "web"]);
        assert_eq!(parsed.passwords[0].as_deref(), Some("s3cret"));
        let db = &parsed.hosts[1];
        assert_eq!(
            db.label, "db.example",
            "a row without a label is named after its host"
        );
        assert_eq!(db.port, 22);
        assert!(!db.has_password);
    }

    #[test]
    fn a_file_without_a_hostname_column_is_refused() {
        let err = csv_parse("name,user\nweb,root\n").unwrap_err();
        assert!(err.contains("Hostname"), "{err}");
    }
}
