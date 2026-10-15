//! The Promptly vault.
//!
//! Everything the user sets up (hosts, keys, snippets, themes, settings) is a
//! record in the vault. Devices exchange records through an encrypted folder
//! on storage the user owns; see `docs/VAULT.md` for the full design.
//!
//! Milestone 0 ships the data model and the logical clock. The operation log,
//! merge, encryption and backends arrive in milestone 2.

pub mod clock;
pub mod model;

pub use clock::{DeviceId, Timestamp};
