//! A saved host as a connection request, for connections the engine makes
//! on its own (SFTP sync), with the group's defaults filled in and the jump
//! hosts chained, the same way the app's connect path does it in
//! `SessionManager.requestFor` (app/lib/features/sessions/session_manager.dart,
//! with the rules in app/lib/features/hosts/inheritance.dart). Keep the two
//! in step.
//!
//! Unattended: a login that would need typing is an error that says what
//! to do.

use std::collections::{BTreeMap, BTreeSet};

use promptly_store::{Collection, SecretStore, Store};
use promptly_vault::model::{Auth, Group, GroupDefaults, Host, Identity, RecordId};

use crate::api::ssh::{SshAuthKind, SshConnectRequest, SshHop};

/// Every group, for walking from a host's group up through its parents.
struct Groups(BTreeMap<RecordId, Group>);

impl Groups {
    fn load(store: &Store) -> Result<Self, String> {
        let mut groups = BTreeMap::new();
        for r in store.list(Collection::Groups).map_err(|e| e.to_string())? {
            if let Ok(g) = serde_json::from_str::<Group>(&r.json) {
                groups.insert(g.id, g);
            }
        }
        Ok(Self(groups))
    }

    /// The first default `pick` finds, from the group up through its
    /// parents.
    fn inherited<T>(
        &self,
        group: Option<RecordId>,
        pick: impl Fn(&GroupDefaults) -> Option<T>,
    ) -> Option<T> {
        let mut seen = BTreeSet::new();
        let mut next = group;
        while let Some(id) = next {
            if !seen.insert(id) {
                break;
            }
            let g = self.0.get(&id)?;
            if let Some(v) = pick(&g.defaults) {
                return Some(v);
            }
            next = g.parent_id;
        }
        None
    }
}

/// How to reach one host: who, where, and with what.
struct Login {
    user: String,
    port: u16,
    auth: SshAuthKind,
    password: Option<String>,
    private_key: Option<String>,
}

fn host(store: &Store, id: &str) -> Result<Option<Host>, String> {
    Ok(store
        .get(Collection::Hosts, id)
        .map_err(|e| e.to_string())?
        .and_then(|r| serde_json::from_str::<Host>(&r.json).ok()))
}

/// The host's own login, with its group filling in what it leaves blank:
/// the user, a port left at 22, and a key for hosts set to Agent or Ask
/// each time.
fn login(
    host: &Host,
    groups: &Groups,
    store: &Store,
    secrets: &dyn SecretStore,
) -> Result<Login, String> {
    let user = if host.username.trim().is_empty() {
        groups
            .inherited(host.group_id, |d| {
                d.username.clone().filter(|u| !u.trim().is_empty())
            })
            .unwrap_or_default()
    } else {
        host.username.clone()
    };
    let port = if host.port == 22 {
        groups.inherited(host.group_id, |d| d.port).unwrap_or(22)
    } else {
        host.port
    };
    let mut auth = host.auth.clone();
    if matches!(auth, Auth::Agent | Auth::Interactive) {
        if let Some(identity_id) = groups.inherited(host.group_id, |d| d.identity_id) {
            auth = Auth::Identity { identity_id };
        }
    }
    let secret = |id: &RecordId, missing: String| -> Result<String, String> {
        let bytes = secrets
            .get(&id.to_string())
            .map_err(|e| e.to_string())?
            .ok_or(missing)?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    };
    let label = &host.label;
    match &auth {
        Auth::Identity { identity_id } => {
            let identity = store
                .get(Collection::Identities, &identity_id.to_string())
                .map_err(|e| e.to_string())?
                .and_then(|r| serde_json::from_str::<Identity>(&r.json).ok())
                .ok_or_else(|| format!("the key for {label} is missing"))?;
            let secret_id = identity
                .private_key_secret_id
                .ok_or_else(|| format!("the key for {label} has no private half on this device"))?;
            let private_key = secret(
                &secret_id,
                format!("the key for {label} is missing on this device"),
            )?;
            Ok(Login {
                user,
                port,
                auth: SshAuthKind::Key,
                password: None,
                private_key: Some(private_key),
            })
        }
        Auth::Password {
            password_secret_id: Some(id),
        } => Ok(Login {
            user,
            port,
            auth: SshAuthKind::Password,
            password: Some(secret(
                id,
                format!("the saved password for {label} is missing"),
            )?),
            private_key: None,
        }),
        Auth::Password {
            password_secret_id: None,
        }
        | Auth::Agent
        | Auth::Interactive
        | Auth::None => Err(format!(
            "Sync needs a stored login: edit {label} and save a password or pick a key."
        )),
    }
}

/// The host's own jump host, or the one its group sets.
fn jump_host_id(host: &Host, groups: &Groups) -> Option<RecordId> {
    host.jump_host_id
        .or_else(|| groups.inherited(host.group_id, |d| d.jump_host_id))
}

/// The saved host `host_id` as a request with no terminal, its jump hosts
/// nearest to this device first, and its label.
pub fn unattended_request(
    store: &Store,
    secrets: &dyn SecretStore,
    host_id: &str,
) -> Result<(SshConnectRequest, String), String> {
    let target = host(store, host_id)?.ok_or("that host is no longer saved")?;
    let groups = Groups::load(store)?;
    let login_ = login(&target, &groups, store, secrets)?;

    let mut jumps = Vec::new();
    let mut seen = BTreeSet::from([target.id]);
    let mut next = jump_host_id(&target, &groups);
    while let Some(id) = next {
        if !seen.insert(id) {
            return Err(format!(
                "The jump hosts for {} go round in a circle. Check their settings.",
                target.label
            ));
        }
        let hop = host(store, &id.to_string())?.ok_or_else(|| {
            format!(
                "The jump host for {} no longer exists. Edit the host and pick another.",
                target.label
            )
        })?;
        let l = login(&hop, &groups, store, secrets)
            .map_err(|e| format!("Jump host {}: {e}", hop.label))?;
        jumps.insert(
            0,
            SshHop {
                user: l.user,
                host: hop.hostname.clone(),
                port: l.port,
                auth: l.auth,
                password: l.password,
                private_key: l.private_key,
                passphrase: None,
            },
        );
        next = jump_host_id(&hop, &groups);
    }

    let request = SshConnectRequest {
        user: login_.user,
        host: target.hostname.clone(),
        port: login_.port,
        auth: login_.auth,
        password: login_.password,
        private_key: login_.private_key,
        passphrase: None,
        cols: 80,
        rows: 24,
        theme: String::new(),
        label: Some(target.label.clone()),
        keepalive_seconds: target.keepalive_seconds,
        reattach_session_id: None,
        jumps,
        persistent: false,
        startup_command: None,
        env: Vec::new(),
        agent_forward: false,
        forwards: Vec::new(),
    };
    Ok((request, target.label))
}

#[cfg(test)]
mod tests {
    use super::*;
    use promptly_store::MemorySecretStore;

    fn put(store: &Store, col: Collection, json: serde_json::Value) {
        let id = json["id"].as_str().unwrap().to_string();
        store.put(col, &id, &json.to_string()).unwrap();
    }

    const PROD: &str = "0190e4b6-0000-7000-8000-000000000001";
    const TEAM: &str = "0190e4b6-0000-7000-8000-000000000002";
    const BASTION: &str = "0190e4b6-0000-7000-8000-000000000010";
    const DB: &str = "0190e4b6-0000-7000-8000-000000000011";
    const KEY: &str = "0190e4b6-0000-7000-8000-000000000020";
    const KEY_SECRET: &str = "0190e4b6-0000-7000-8000-000000000021";
    const PW_SECRET: &str = "0190e4b6-0000-7000-8000-000000000022";

    /// A store with a group (inside a parent group) that sets a user, a
    /// key, a port and a jump host, and a host that leaves all four to it.
    fn fixture() -> (Store, MemorySecretStore) {
        let store = Store::open_in_memory().unwrap();
        let secrets = MemorySecretStore::default();
        put(
            &store,
            Collection::Groups,
            serde_json::json!({"id": TEAM, "label": "Team", "defaults": {"username": "ops", "jump_host_id": BASTION}}),
        );
        put(
            &store,
            Collection::Groups,
            serde_json::json!({"id": PROD, "label": "Production", "parent_id": TEAM,
                "defaults": {"identity_id": KEY, "port": 2222}}),
        );
        put(
            &store,
            Collection::Identities,
            serde_json::json!({"id": KEY, "label": "work", "key_type": "ed25519",
                "public_key": "ssh-ed25519 AAAA", "private_key_secret_id": KEY_SECRET}),
        );
        secrets.put(KEY_SECRET, b"PRIVATE KEY").unwrap();
        secrets.put(PW_SECRET, b"hunter2").unwrap();
        put(
            &store,
            Collection::Hosts,
            serde_json::json!({"id": BASTION, "label": "bastion", "hostname": "bastion.example.com",
                "port": 22, "username": "jump",
                "auth": {"kind": "password", "password_secret_id": PW_SECRET}}),
        );
        put(
            &store,
            Collection::Hosts,
            serde_json::json!({"id": DB, "label": "db", "hostname": "10.0.0.5", "port": 22,
                "username": "", "auth": {"kind": "agent"}, "group_id": PROD, "keepalive_seconds": 0}),
        );
        (store, secrets)
    }

    #[test]
    fn a_synced_host_takes_its_groups_defaults_and_jump_host() {
        let (store, secrets) = fixture();
        let (mut request, label) = unattended_request(&store, &secrets, DB).unwrap();
        assert_eq!(label, "db");
        assert_eq!(request.user, "ops", "from the parent group");
        assert_eq!(
            request.port, 2222,
            "a host left on 22 takes the group's port"
        );
        assert!(matches!(request.auth, SshAuthKind::Key));
        assert_eq!(request.private_key.as_deref(), Some("PRIVATE KEY"));
        assert_eq!(request.keepalive_seconds, 0);
        assert_eq!(request.jumps.len(), 1);
        let hop = &request.jumps[0];
        assert_eq!(
            (hop.user.as_str(), hop.host.as_str(), hop.port),
            ("jump", "bastion.example.com", 22)
        );
        assert_eq!(hop.password.as_deref(), Some("hunter2"));

        // Through the same parameters the terminal's connect path uses.
        let endpoint = promptly_ssh::Endpoint {
            user: request.user.clone(),
            host: request.host.clone(),
            port: request.port,
        };
        let params = crate::api::ssh::params_for(
            &mut request,
            endpoint,
            promptly_term::TermSize::default(),
            None,
        );
        assert_eq!(params.endpoint.port, 2222);
        assert!(params.keepalive.is_zero(), "zero keeps keep-alives off");
        let jump = params.jump.expect("the jump host");
        assert_eq!(jump.endpoint.host, "bastion.example.com");
    }

    #[test]
    fn a_hosts_own_settings_beat_its_groups() {
        let (store, secrets) = fixture();
        put(
            &store,
            Collection::Hosts,
            serde_json::json!({"id": DB, "label": "db", "hostname": "10.0.0.5", "port": 2200,
                "username": "postgres", "auth": {"kind": "password", "password_secret_id": PW_SECRET},
                "group_id": PROD, "jump_host_id": null}),
        );
        let (request, _) = unattended_request(&store, &secrets, DB).unwrap();
        assert_eq!(request.user, "postgres");
        assert_eq!(request.port, 2200);
        assert!(matches!(request.auth, SshAuthKind::Password));
        assert_eq!(
            request.jumps.len(),
            1,
            "the group's jump host still applies"
        );
    }

    #[test]
    fn jump_hosts_in_a_circle_and_logins_that_need_typing_are_refused() {
        let (store, secrets) = fixture();
        // The bastion jumps through the db host, which jumps through it.
        put(
            &store,
            Collection::Hosts,
            serde_json::json!({"id": BASTION, "label": "bastion", "hostname": "b", "port": 22,
                "username": "jump", "auth": {"kind": "password", "password_secret_id": PW_SECRET},
                "jump_host_id": DB}),
        );
        let err = unattended_request(&store, &secrets, DB)
            .err()
            .expect("refused");
        assert!(err.contains("round in a circle"), "{err}");

        put(
            &store,
            Collection::Hosts,
            serde_json::json!({"id": BASTION, "label": "bastion", "hostname": "b", "port": 22,
                "username": "jump", "auth": {"kind": "interactive"}}),
        );
        let err = unattended_request(&store, &secrets, DB)
            .err()
            .expect("refused");
        assert!(
            err.starts_with("Jump host bastion: Sync needs a stored login"),
            "{err}"
        );
    }
}
