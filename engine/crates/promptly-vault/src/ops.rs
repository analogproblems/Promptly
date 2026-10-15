//! Operations and segments, as specified in VAULT.md section 6.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::clock::{DeviceId, Timestamp};
use crate::model::Collection;

/// The format number written into every segment and snapshot.
pub const FORMAT: u32 = 1;

/// One change. `put` carries only the fields that changed; `del` is a
/// tombstone for the whole record.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Op {
    Put {
        col: Collection,
        id: String,
        ts: Timestamp,
        /// Wall-clock time, RFC 3339, for display only.
        at: String,
        fields: BTreeMap<String, Value>,
    },
    Del {
        col: Collection,
        id: String,
        ts: Timestamp,
        at: String,
    },
}

impl Op {
    pub fn col(&self) -> Collection {
        match self {
            Op::Put { col, .. } | Op::Del { col, .. } => *col,
        }
    }

    pub fn id(&self) -> &str {
        match self {
            Op::Put { id, .. } | Op::Del { id, .. } => id,
        }
    }

    pub fn ts(&self) -> &Timestamp {
        match self {
            Op::Put { ts, .. } | Op::Del { ts, .. } => ts,
        }
    }

    pub fn at(&self) -> &str {
        match self {
            Op::Put { at, .. } | Op::Del { at, .. } => at,
        }
    }
}

/// The plaintext of a `.seg` file: a batch of one device's operations.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    pub format: u32,
    pub device: DeviceId,
    pub seq: u64,
    pub ops: Vec<Op>,
}

impl Segment {
    pub fn new(device: DeviceId, seq: u64, ops: Vec<Op>) -> Self {
        Self {
            format: FORMAT,
            device,
            seq,
            ops,
        }
    }
}

/// Wall-clock time now, RFC 3339, for the `at` field.
pub fn now_rfc3339() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dev() -> DeviceId {
        DeviceId::parse(&"7".repeat(32)).unwrap()
    }

    #[test]
    fn ops_serialise_as_in_the_spec() {
        let put = Op::Put {
            col: Collection::Hosts,
            id: "h1".into(),
            ts: Timestamp(812, dev()),
            at: "2026-10-15T20:12:04Z".into(),
            fields: BTreeMap::from([("label".to_string(), Value::String("web-1".into()))]),
        };
        let json = serde_json::to_string(&put).unwrap();
        assert!(
            json.starts_with(r#"{"op":"put","col":"hosts","id":"h1","ts":[812,""#),
            "{json}"
        );
        assert!(json.ends_with(r#""fields":{"label":"web-1"}}"#), "{json}");
        let del = Op::Del {
            col: Collection::KnownHosts,
            id: "k".into(),
            ts: Timestamp(813, dev()),
            at: String::new(),
        };
        let json = serde_json::to_string(&del).unwrap();
        assert!(json.contains(r#""op":"del","col":"known_hosts""#), "{json}");
        let back: Op = serde_json::from_str(&json).unwrap();
        assert_eq!(back, del);
    }
}
