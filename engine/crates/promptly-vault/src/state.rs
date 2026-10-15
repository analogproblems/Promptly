//! The merged state and the merge rules of VAULT.md section 7, plus
//! snapshots (section 8).
//!
//! Every rule is "higher timestamp wins" and timestamps are unique, so
//! applying operations in any order, or twice, gives the same result.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::clock::{DeviceId, Timestamp};
use crate::model::Collection;
use crate::ops::{Op, FORMAT};

/// A field's value and the timestamp that last set it.
#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    pub value: Value,
    pub ts: Timestamp,
}

/// One record as merged: its fields with their timestamps, and the
/// timestamp of its deletion if it was ever deleted.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Record {
    pub deleted: Option<Timestamp>,
    pub fields: BTreeMap<String, Field>,
}

impl Record {
    /// The fields that are not hidden by a deletion.
    pub fn visible_fields(&self) -> Map<String, Value> {
        self.fields
            .iter()
            .filter(|(_, f)| self.deleted.as_ref().is_none_or(|d| f.ts > *d))
            .map(|(k, f)| (k.clone(), f.value.clone()))
            .collect()
    }

    /// A record shows up in lists while it has at least one visible field.
    pub fn is_visible(&self) -> bool {
        self.fields
            .values()
            .any(|f| self.deleted.as_ref().is_none_or(|d| f.ts > *d))
    }

    /// The newest timestamp this record carries, deletion included.
    pub fn newest_ts(&self) -> Option<&Timestamp> {
        self.fields
            .values()
            .map(|f| &f.ts)
            .chain(self.deleted.iter())
            .max()
    }
}

/// The whole vault as one device sees it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct State {
    records: BTreeMap<(Collection, String), Record>,
}

impl State {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apply one operation. Returns true if anything changed, which is
    /// false for duplicates and for anything older than what is stored.
    pub fn apply(&mut self, op: &Op) -> bool {
        let key = (op.col(), op.id().to_string());
        match op {
            Op::Put { ts, fields, .. } => {
                let rec = self.records.entry(key).or_default();
                let mut changed = false;
                for (name, value) in fields {
                    let newer = rec.fields.get(name).is_none_or(|f| *ts > f.ts);
                    if newer {
                        rec.fields.insert(
                            name.clone(),
                            Field {
                                value: value.clone(),
                                ts: ts.clone(),
                            },
                        );
                        changed = true;
                    }
                }
                changed
            }
            Op::Del { ts, .. } => {
                let rec = self.records.entry(key).or_default();
                if rec.deleted.as_ref().is_none_or(|d| *ts > *d) {
                    rec.deleted = Some(ts.clone());
                    true
                } else {
                    false
                }
            }
        }
    }

    /// Apply a snapshot: a pre-merged bag of fields and tombstones. Returns
    /// how many records changed.
    pub fn apply_snapshot(&mut self, snap: &Snapshot) -> usize {
        let mut changed = 0;
        for r in &snap.records {
            let rec = self.records.entry((r.col, r.id.clone())).or_default();
            let mut this = false;
            if let Some(d) = &r.deleted {
                if rec.deleted.as_ref().is_none_or(|have| d > have) {
                    rec.deleted = Some(d.clone());
                    this = true;
                }
            }
            for (name, (value, ts)) in &r.fields {
                if rec.fields.get(name).is_none_or(|f| *ts > f.ts) {
                    rec.fields.insert(
                        name.clone(),
                        Field {
                            value: value.clone(),
                            ts: ts.clone(),
                        },
                    );
                    this = true;
                }
            }
            if this {
                changed += 1;
            }
        }
        changed
    }

    /// The visible record as a JSON object, if it exists and is not deleted.
    pub fn get(&self, col: Collection, id: &str) -> Option<Map<String, Value>> {
        let rec = self.records.get(&(col, id.to_string()))?;
        rec.is_visible().then(|| rec.visible_fields())
    }

    /// Every visible record of a collection, by id.
    pub fn list(&self, col: Collection) -> Vec<(String, Map<String, Value>)> {
        self.records
            .range((col, String::new())..)
            .take_while(|((c, _), _)| *c == col)
            .filter(|(_, r)| r.is_visible())
            .map(|((_, id), r)| (id.clone(), r.visible_fields()))
            .collect()
    }

    /// Every record, visible or not, with its merge bookkeeping.
    pub fn records(&self) -> impl Iterator<Item = (Collection, &str, &Record)> {
        self.records.iter().map(|((c, id), r)| (*c, id.as_str(), r))
    }

    pub fn record(&self, col: Collection, id: &str) -> Option<&Record> {
        self.records.get(&(col, id.to_string()))
    }

    /// Replace one record's bookkeeping wholesale, for loading from a store.
    pub fn insert_record(&mut self, col: Collection, id: String, record: Record) {
        self.records.insert((col, id), record);
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// The newest timestamp anywhere in the state.
    pub fn max_ts(&self) -> Option<Timestamp> {
        self.records
            .values()
            .filter_map(|r| r.newest_ts())
            .max()
            .cloned()
    }

    /// The `put` that turns the stored record into `fields`, carrying only
    /// what differs; `None` when nothing differs. A record that is absent
    /// or deleted gets every field, so it comes back whole.
    pub fn put_diff(
        &self,
        col: Collection,
        id: &str,
        fields: &Map<String, Value>,
        ts: Timestamp,
        at: String,
    ) -> Option<Op> {
        let current = self.get(col, id).unwrap_or_default();
        let changed: BTreeMap<String, Value> = fields
            .iter()
            .filter(|(k, v)| current.get(*k) != Some(*v))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        if changed.is_empty() {
            return None;
        }
        Some(Op::Put {
            col,
            id: id.to_string(),
            ts,
            at,
            fields: changed,
        })
    }

    /// The whole state as a snapshot written by `device` at `seq`.
    pub fn to_snapshot(&self, device: DeviceId, seq: u64, clock: u64) -> Snapshot {
        Snapshot {
            format: FORMAT,
            device,
            seq,
            clock,
            records: self
                .records
                .iter()
                .map(|((col, id), r)| SnapshotRecord {
                    col: *col,
                    id: id.clone(),
                    deleted: r.deleted.clone(),
                    fields: r
                        .fields
                        .iter()
                        .map(|(k, f)| (k.clone(), (f.value.clone(), f.ts.clone())))
                        .collect(),
                })
                .collect(),
        }
    }

    /// A state holding exactly what a snapshot says.
    pub fn from_snapshot(snap: &Snapshot) -> Self {
        let mut s = Self::new();
        s.apply_snapshot(snap);
        s
    }
}

/// The plaintext of a `.snap` file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    pub format: u32,
    pub device: DeviceId,
    pub seq: u64,
    pub clock: u64,
    pub records: Vec<SnapshotRecord>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SnapshotRecord {
    pub col: Collection,
    pub id: String,
    pub deleted: Option<Timestamp>,
    pub fields: BTreeMap<String, (Value, Timestamp)>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn dev(c: char) -> DeviceId {
        DeviceId::parse(&std::iter::repeat_n(c, 32).collect::<String>()).unwrap()
    }

    fn put(id: &str, n: u64, d: char, fields: Value) -> Op {
        Op::Put {
            col: Collection::Hosts,
            id: id.into(),
            ts: Timestamp(n, dev(d)),
            at: String::new(),
            fields: fields
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
        }
    }

    fn del(id: &str, n: u64, d: char) -> Op {
        Op::Del {
            col: Collection::Hosts,
            id: id.into(),
            ts: Timestamp(n, dev(d)),
            at: String::new(),
        }
    }

    #[test]
    fn field_by_field_last_writer_wins_in_any_order() {
        let ops = [
            put("h", 1, 'a', json!({"label": "web", "port": 22})),
            put("h", 5, 'b', json!({"port": 2222})),
            put("h", 3, 'a', json!({"label": "web-1", "port": 23})),
        ];
        let expected = json!({"label": "web-1", "port": 2222});
        // Every permutation lands on the same answer.
        let perms = [
            [0, 1, 2],
            [0, 2, 1],
            [1, 0, 2],
            [1, 2, 0],
            [2, 0, 1],
            [2, 1, 0],
        ];
        for p in perms {
            let mut s = State::new();
            for i in p {
                s.apply(&ops[i]);
            }
            assert_eq!(
                Value::Object(s.get(Collection::Hosts, "h").unwrap()),
                expected,
                "{p:?}"
            );
        }
        // Applying twice changes nothing the second time.
        let mut s = State::new();
        assert!(s.apply(&ops[0]));
        assert!(!s.apply(&ops[0]));
    }

    #[test]
    fn deletion_hides_older_fields_and_later_puts_resurrect() {
        let mut s = State::new();
        s.apply(&put("h", 1, 'a', json!({"label": "web", "port": 22})));
        s.apply(&del("h", 2, 'a'));
        assert!(s.get(Collection::Hosts, "h").is_none());
        assert!(s.list(Collection::Hosts).is_empty());
        // An older put arriving late stays hidden.
        s.apply(&put("h", 1, 'b', json!({"notes": "late"})));
        assert!(s.get(Collection::Hosts, "h").is_none());
        // A newer put brings the record back with the fields it carries.
        s.apply(&put("h", 3, 'b', json!({"label": "back"})));
        assert_eq!(
            Value::Object(s.get(Collection::Hosts, "h").unwrap()),
            json!({"label": "back"})
        );
        // An older deletion arriving late changes nothing.
        assert!(!s.apply(&del("h", 1, 'c')));
    }

    #[test]
    fn put_diff_carries_only_changes_and_everything_for_a_deleted_record() {
        let mut s = State::new();
        s.apply(&put("h", 1, 'a', json!({"label": "web", "port": 22})));
        let want = json!({"label": "web", "port": 2222})
            .as_object()
            .unwrap()
            .clone();
        let op = s
            .put_diff(
                Collection::Hosts,
                "h",
                &want,
                Timestamp(2, dev('a')),
                String::new(),
            )
            .unwrap();
        match &op {
            Op::Put { fields, .. } => assert_eq!(fields.len(), 1, "{fields:?}"),
            _ => panic!(),
        }
        s.apply(&op);
        let same = s.put_diff(
            Collection::Hosts,
            "h",
            &want,
            Timestamp(3, dev('a')),
            String::new(),
        );
        assert!(same.is_none(), "nothing changed");
        s.apply(&del("h", 4, 'a'));
        let back = s
            .put_diff(
                Collection::Hosts,
                "h",
                &want,
                Timestamp(5, dev('a')),
                String::new(),
            )
            .unwrap();
        match &back {
            Op::Put { fields, .. } => assert_eq!(fields.len(), 2, "whole record again"),
            _ => panic!(),
        }
    }

    #[test]
    fn snapshots_round_trip_and_merge_like_ops() {
        let mut a = State::new();
        a.apply(&put("h", 1, 'a', json!({"label": "web"})));
        a.apply(&put("g", 2, 'a', json!({"label": "prod"})));
        a.apply(&del("g", 3, 'a'));
        let snap = a.to_snapshot(dev('a'), 1, 3);
        let json = serde_json::to_string(&snap).unwrap();
        assert!(json.contains(r#""fields":{"label":["web",[1,""#), "{json}");
        let back: Snapshot = serde_json::from_str(&json).unwrap();
        let b = State::from_snapshot(&back);
        assert_eq!(a, b);
        // Applying it again on top of a state that moved on changes nothing old.
        let mut c = b.clone();
        c.apply(&put("h", 9, 'b', json!({"label": "newer"})));
        assert_eq!(c.apply_snapshot(&back), 0);
        assert_eq!(c.get(Collection::Hosts, "h").unwrap()["label"], "newer");
        assert_eq!(c.max_ts(), Some(Timestamp(9, dev('b'))));
    }
}
