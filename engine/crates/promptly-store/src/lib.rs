//! Local state for Promptly.
//!
//! The store is this device's copy of the vault (see `promptly-vault`): the
//! merged records with their timestamps, the device's clock, the operations
//! waiting to be pushed, and the sync markers. It works the same whether or
//! not a sync backend is set up; setting one up later just gives the
//! pending operations somewhere to go.
//!
//! Secrets never live in the record store. [`SecretStore`] is how they
//! reach the platform: owner-only files on Linux, the keychain elsewhere.

pub mod secrets;
pub mod store;

pub use promptly_vault::model::Collection;
pub use secrets::{FileSecretStore, MemorySecretStore, SecretError, SecretStore};
pub use store::{col_name, col_parse, Record, Store, StoreError};
