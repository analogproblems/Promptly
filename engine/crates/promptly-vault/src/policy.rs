//! What stays on this device, and which devices are cut off.
//!
//! A host or key marked "This device only" (`sync: local_only`), a
//! hardware-backed key, and the saved passwords and private keys they use
//! never go into the vault. When one leaves the vault, this device writes a
//! tombstone for it into its snapshots, so the copies other devices hold go
//! away, while its own stays (VAULT.md section 11).
//!
//! A removed device is one whose `devices` record another device marked
//! with `removed_after`: its files numbered above that are never applied.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Map, Value};

use crate::clock::{DeviceId, Timestamp};
use crate::model::Collection;
use crate::state::State;

/// The fields that mark a device removed. Only other devices may set them.
pub const REMOVED_AT: &str = "removed_at";
pub const REMOVED_AFTER: &str = "removed_after";

/// Records kept off the vault, each with the timestamp of the tombstone
/// this device publishes for it.
pub type Kept = BTreeMap<(Collection, String), Timestamp>;

fn is_local_only(fields: &Map<String, Value>) -> bool {
    fields.get("sync").and_then(Value::as_str) == Some("local_only")
}

fn secret_ref(fields: &Map<String, Value>, name: &str, out: &mut BTreeSet<(Collection, String)>) {
    if let Some(id) = fields.get(name).and_then(Value::as_str) {
        out.insert((Collection::Secrets, id.to_string()));
    }
}

/// Every record that must stay on this device: hosts and keys marked
/// local only, hardware keys, the secrets those use, and secrets marked
/// local only themselves (such as a storage login).
pub fn kept_on_device(state: &State) -> BTreeSet<(Collection, String)> {
    let mut out = BTreeSet::new();
    for (id, fields) in state.list(Collection::Hosts) {
        if is_local_only(&fields) {
            if let Some(auth) = fields.get("auth").and_then(Value::as_object) {
                secret_ref(auth, "password_secret_id", &mut out);
            }
            out.insert((Collection::Hosts, id));
        }
    }
    for (id, fields) in state.list(Collection::Identities) {
        let hardware = fields.get("hardware").is_some_and(|h| !h.is_null());
        if hardware || is_local_only(&fields) {
            secret_ref(&fields, "private_key_secret_id", &mut out);
            secret_ref(&fields, "passphrase_secret_id", &mut out);
            out.insert((Collection::Identities, id));
        }
    }
    for (id, fields) in state.list(Collection::Secrets) {
        if is_local_only(&fields) {
            out.insert((Collection::Secrets, id));
        }
    }
    out
}

/// What changes when the records kept on this device are worked out again.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct KeptPlan {
    /// Everything kept now, with its tombstone.
    pub kept: Kept,
    /// Some records were not kept last time: a snapshot should go out now,
    /// carrying their tombstones.
    pub newly_kept: bool,
    /// Records kept last time that go back into the vault. The vault holds
    /// a tombstone for each, so each must be written again in full, newer
    /// than that, or other devices would not see it.
    pub back: Vec<(Collection, String)>,
}

/// Compare what is kept now with `previous`. A record kept already keeps
/// its tombstone; a newly kept one gets one as new as its newest field, so
/// it hides every copy of the record this device has seen.
pub fn plan_kept(state: &State, previous: &Kept) -> KeptPlan {
    let now = kept_on_device(state);
    let mut plan = KeptPlan::default();
    for key in &now {
        if let Some(ts) = previous.get(key) {
            plan.kept.insert(key.clone(), ts.clone());
        } else if let Some(ts) = state.record(key.0, &key.1).and_then(|r| r.newest_ts()) {
            plan.kept.insert(key.clone(), ts.clone());
            plan.newly_kept = true;
        }
    }
    plan.back = previous
        .keys()
        .filter(|k| !now.contains(*k))
        .cloned()
        .collect();
    plan
}

/// Every removed device, with the number above which its files are ignored.
pub fn removed_devices(state: &State) -> BTreeMap<DeviceId, u64> {
    state
        .list(Collection::Devices)
        .into_iter()
        .filter_map(|(id, fields)| {
            let after = fields.get(REMOVED_AFTER)?.as_u64()?;
            let uuid = uuid::Uuid::parse_str(&id).ok()?;
            Some((DeviceId::from_uuid(&uuid), after))
        })
        .collect()
}

/// Kept records as JSON, for keeping between runs: `[[col, id, ts], …]`.
pub fn kept_to_json(kept: &Kept) -> String {
    let rows: Vec<(Collection, &String, &Timestamp)> =
        kept.iter().map(|((c, id), ts)| (*c, id, ts)).collect();
    serde_json::to_string(&rows).expect("kept records serialise")
}

pub fn kept_from_json(json: &str) -> Kept {
    serde_json::from_str::<Vec<(Collection, String, Timestamp)>>(json)
        .map(|rows| rows.into_iter().map(|(c, id, ts)| ((c, id), ts)).collect())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::Clock;
    use crate::ops::Op;
    use serde_json::json;

    fn put(state: &mut State, clock: &mut Clock, col: Collection, id: &str, fields: Value) {
        let fields = fields.as_object().unwrap().clone();
        let op = state
            .put_diff(col, id, &fields, clock.tick(), String::new())
            .unwrap();
        state.apply(&op);
    }

    #[test]
    fn local_only_hosts_and_keys_keep_their_secrets_with_them() {
        let mut s = State::new();
        let mut c = Clock::new(DeviceId::generate());
        put(
            &mut s,
            &mut c,
            Collection::Hosts,
            "h1",
            json!({"label": "home", "sync": "local_only", "auth": {"kind": "password", "password_secret_id": "p1"}}),
        );
        put(
            &mut s,
            &mut c,
            Collection::Hosts,
            "h2",
            json!({"label": "work", "sync": "vault", "auth": {"kind": "password", "password_secret_id": "p2"}}),
        );
        put(
            &mut s,
            &mut c,
            Collection::Identities,
            "k1",
            json!({"label": "laptop", "sync": "local_only", "private_key_secret_id": "s1", "passphrase_secret_id": "s2"}),
        );
        put(
            &mut s,
            &mut c,
            Collection::Identities,
            "k2",
            json!({"label": "chip", "hardware": {"platform": "ios", "handle": "x"}, "private_key_secret_id": null}),
        );
        put(
            &mut s,
            &mut c,
            Collection::Identities,
            "k3",
            json!({"label": "shared", "hardware": null}),
        );
        put(
            &mut s,
            &mut c,
            Collection::Secrets,
            "b1",
            json!({"kind": "backend_credential", "sync": "local_only"}),
        );
        let kept = kept_on_device(&s);
        let ids: Vec<&str> = kept.iter().map(|(_, id)| id.as_str()).collect();
        assert_eq!(ids, ["h1", "k1", "k2", "b1", "p1", "s1", "s2"]);
    }

    #[test]
    fn a_record_leaving_the_vault_gets_a_tombstone_once_and_coming_back_is_noticed() {
        let mut s = State::new();
        let mut c = Clock::new(DeviceId::generate());
        put(
            &mut s,
            &mut c,
            Collection::Hosts,
            "h",
            json!({"label": "web", "sync": "vault"}),
        );
        let first = plan_kept(&s, &Kept::new());
        assert!(first.kept.is_empty() && !first.newly_kept && first.back.is_empty());

        put(
            &mut s,
            &mut c,
            Collection::Hosts,
            "h",
            json!({"label": "web", "sync": "local_only"}),
        );
        let plan = plan_kept(&s, &first.kept);
        assert!(plan.newly_kept);
        let ts = plan.kept[&(Collection::Hosts, "h".to_string())].clone();
        assert_eq!(
            Some(&ts),
            s.record(Collection::Hosts, "h").unwrap().newest_ts()
        );

        // Edited while kept: the tombstone stays where it was.
        put(
            &mut s,
            &mut c,
            Collection::Hosts,
            "h",
            json!({"label": "web-1", "sync": "local_only"}),
        );
        let again = plan_kept(&s, &plan.kept);
        assert!(!again.newly_kept);
        assert_eq!(again.kept, plan.kept);
        let round = kept_from_json(&kept_to_json(&again.kept));
        assert_eq!(round, again.kept);

        put(
            &mut s,
            &mut c,
            Collection::Hosts,
            "h",
            json!({"label": "web-1", "sync": "vault"}),
        );
        let back = plan_kept(&s, &again.kept);
        assert!(back.kept.is_empty());
        assert_eq!(back.back, [(Collection::Hosts, "h".to_string())]);
        // A record deleted while kept is simply forgotten.
        let mut gone = s.clone();
        gone.apply(&Op::Del {
            col: Collection::Hosts,
            id: "h".into(),
            ts: c.tick(),
            at: String::new(),
        });
        assert!(kept_on_device(&gone).is_empty());
    }

    #[test]
    fn removed_devices_are_read_from_their_records() {
        let mut s = State::new();
        let mut c = Clock::new(DeviceId::generate());
        let gone = DeviceId::generate();
        let here = DeviceId::generate();
        put(
            &mut s,
            &mut c,
            Collection::Devices,
            &gone.as_uuid().to_string(),
            json!({"name": "old phone", REMOVED_AT: "2026-10-17T10:00:00Z", REMOVED_AFTER: 7}),
        );
        put(
            &mut s,
            &mut c,
            Collection::Devices,
            &here.as_uuid().to_string(),
            json!({"name": "laptop"}),
        );
        assert_eq!(removed_devices(&s), BTreeMap::from([(gone, 7)]));
    }
}
