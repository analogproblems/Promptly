//! The Promptly vault.
//!
//! Everything the user sets up (hosts, keys, snippets, themes, settings) is a
//! record in the vault. Devices exchange records through an encrypted folder
//! on storage the user owns; see `docs/VAULT.md` for the full design.
//!
//! - [`model`]: the records and their wire names.
//! - [`clock`]: logical time, so merging never depends on wall clocks.
//! - [`ops`] and [`state`]: operations, the merge rules and snapshots.
//! - [`crypto`] and [`manifest`]: the file envelope and the key hierarchy.
//! - [`backend`]: the four calls a storage needs, and the local folder.
//! - [`policy`]: what stays on this device, and which devices are cut off.
//! - [`sync`]: pull, push and compaction over any backend.

pub mod backend;
pub mod clock;
pub mod crypto;
pub mod manifest;
pub mod model;
pub mod ops;
pub mod policy;
pub mod state;
pub mod sync;

pub use backend::{Backend, BackendError, Entry, LocalFolder};
pub use clock::{Clock, DeviceId, Timestamp};
pub use crypto::Dek;
pub use manifest::{KdfParams, Manifest, RecoveryCode};
pub use ops::{Op, Segment};
pub use policy::{Kept, KeptPlan};
pub use state::{Snapshot, State};
pub use sync::{Marker, PullReport, SyncError, SyncState, Vault};
