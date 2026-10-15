//! The records a vault holds, as specified in DESIGN.md section 6.
//!
//! Field names here are the wire names in vault files and in the JSON export,
//! so renaming one is a format change.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use time::OffsetDateTime;
use uuid::Uuid;

/// Identifier of any record. UUID v7 so ids sort by creation time.
pub type RecordId = Uuid;

pub fn new_id() -> RecordId {
    Uuid::now_v7()
}

/// Whether a record travels in the vault or stays on this device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncPolicy {
    #[default]
    Vault,
    LocalOnly,
}

/// The collections a vault contains. The wire name is the `col` field in
/// operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Collection {
    Hosts,
    Groups,
    Identities,
    Secrets,
    Snippets,
    KnownHosts,
    Themes,
    Settings,
    Devices,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum Auth {
    Identity { identity_id: RecordId },
    Password { password_secret_id: RecordId },
    Agent,
    Interactive,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ForwardKind {
    Local,
    Remote,
    Dynamic,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortForward {
    pub kind: ForwardKind,
    pub bind_host: String,
    pub bind_port: u16,
    #[serde(default)]
    pub target_host: String,
    #[serde(default)]
    pub target_port: u16,
    /// Start this forward automatically when the host connects.
    #[serde(default)]
    pub auto: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Host {
    pub id: RecordId,
    pub label: String,
    pub hostname: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default)]
    pub username: String,
    pub auth: Auth,
    #[serde(default)]
    pub group_id: Option<RecordId>,
    #[serde(default)]
    pub tags: Vec<String>,
    /// A colour token name or hex string; the UI decides how to draw it.
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub jump_host_id: Option<RecordId>,
    #[serde(default = "default_keepalive")]
    pub keepalive_seconds: u32,
    #[serde(default)]
    pub startup_command: Option<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub persistent_session: bool,
    #[serde(default)]
    pub port_forwards: Vec<PortForward>,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub last_connected_at: Option<OffsetDateTime>,
    #[serde(default)]
    pub favourite: bool,
    #[serde(default)]
    pub sync: SyncPolicy,
}

fn default_port() -> u16 {
    22
}

fn default_keepalive() -> u32 {
    30
}

impl Host {
    /// A host with sensible defaults, ready to edit.
    pub fn new(label: impl Into<String>, hostname: impl Into<String>) -> Self {
        Self {
            id: new_id(),
            label: label.into(),
            hostname: hostname.into(),
            port: default_port(),
            username: String::new(),
            auth: Auth::Agent,
            group_id: None,
            tags: Vec::new(),
            color: None,
            icon: None,
            notes: String::new(),
            jump_host_id: None,
            keepalive_seconds: default_keepalive(),
            startup_command: None,
            env: BTreeMap::new(),
            persistent_session: false,
            port_forwards: Vec::new(),
            last_connected_at: None,
            favourite: false,
            sync: SyncPolicy::Vault,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct GroupDefaults {
    #[serde(default)]
    pub username: Option<String>,
    #[serde(default)]
    pub identity_id: Option<RecordId>,
    #[serde(default)]
    pub jump_host_id: Option<RecordId>,
    #[serde(default)]
    pub port: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Group {
    pub id: RecordId,
    pub label: String,
    #[serde(default)]
    pub parent_id: Option<RecordId>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub defaults: GroupDefaults,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KeyType {
    Ed25519,
    Ecdsa,
    Rsa,
}

/// A hardware-backed key that never leaves the device. Never synced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HardwareKey {
    pub platform: String,
    pub handle: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
    pub id: RecordId,
    pub label: String,
    pub key_type: KeyType,
    /// The OpenSSH one-line public key.
    pub public_key: String,
    #[serde(default)]
    pub private_key_secret_id: Option<RecordId>,
    #[serde(default)]
    pub hardware: Option<HardwareKey>,
    #[serde(default)]
    pub passphrase_secret_id: Option<RecordId>,
    #[serde(default)]
    pub sync: SyncPolicy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SecretKind {
    Password,
    PrivateKey,
    KeyPassphrase,
    BackendCredential,
}

/// A secret as stored: already encrypted with the vault key. The engine never
/// serialises plaintext secrets into a record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Secret {
    pub id: RecordId,
    pub kind: SecretKind,
    pub ciphertext: Vec<u8>,
    #[serde(default)]
    pub sync: SyncPolicy,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnippetVariable {
    pub name: String,
    #[serde(default)]
    pub default: Option<String>,
    #[serde(default)]
    pub prompt: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snippet {
    pub id: RecordId,
    pub label: String,
    pub command: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub variables: Vec<SnippetVariable>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KnownHost {
    pub id: RecordId,
    pub host: String,
    pub port: u16,
    pub key_type: String,
    pub fingerprint_sha256: String,
    pub public_key: String,
    #[serde(with = "time::serde::rfc3339")]
    pub first_seen_at: OffsetDateTime,
    pub first_seen_device: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThemeColors {
    pub fg: String,
    pub bg: String,
    pub cursor: String,
    pub selection: String,
    pub ansi: [String; 16],
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Theme {
    pub id: RecordId,
    pub name: String,
    pub colors: ThemeColors,
    #[serde(default)]
    pub builtin: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Device {
    pub id: RecordId,
    pub name: String,
    pub platform: String,
    #[serde(with = "time::serde::rfc3339")]
    pub enrolled_at: OffsetDateTime,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub last_seen_at: Option<OffsetDateTime>,
    #[serde(default)]
    pub app_version: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_round_trips_through_json_with_defaults() {
        let mut h = Host::new("web-1", "10.0.0.11");
        h.username = "deploy".into();
        h.tags = vec!["prod".into()];
        let json = serde_json::to_string(&h).unwrap();
        let back: Host = serde_json::from_str(&json).unwrap();
        assert_eq!(back, h);

        // A minimal record from an older or hand-written file still loads.
        let minimal = format!(
            r#"{{"id":"{}","label":"x","hostname":"y","auth":{{"kind":"agent"}}}}"#,
            new_id()
        );
        let h: Host = serde_json::from_str(&minimal).unwrap();
        assert_eq!(h.port, 22);
        assert_eq!(h.keepalive_seconds, 30);
        assert_eq!(h.sync, SyncPolicy::Vault);
    }

    #[test]
    fn ids_sort_by_creation() {
        let a = new_id();
        let b = new_id();
        assert!(a < b);
    }

    #[test]
    fn collection_wire_names_are_snake_case() {
        assert_eq!(
            serde_json::to_string(&Collection::KnownHosts).unwrap(),
            "\"known_hosts\""
        );
    }
}
