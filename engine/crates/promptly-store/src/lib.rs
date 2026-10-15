//! Local state for Promptly.
//!
//! The vault (see `promptly-vault`) is the source of truth once sync is set
//! up; this crate keeps the fast local copy the UI reads from. Records are
//! stored as JSON documents keyed by collection and id, which is the same
//! shape the vault files and the JSON export use, so nothing is translated.
//!
//! Secrets never live here. [`SecretStore`] defines how they reach the
//! platform keychain; the app implements it on its side of the bridge.

pub mod secrets;
pub mod store;

pub use promptly_vault::model::Collection;
pub use secrets::{MemorySecretStore, SecretError, SecretStore};
pub use store::{Record, Store, StoreError};
