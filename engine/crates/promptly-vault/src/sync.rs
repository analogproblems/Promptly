//! Pull, push and compaction, as specified in VAULT.md sections 8, 9 and 11.
//!
//! A [`Vault`] is one device's view of a vault on one backend. It holds the
//! data key and knows the device id; the caller keeps the merged [`State`],
//! the [`Clock`] and the [`SyncState`] (what has been applied so far) and
//! persists them between runs. The caller also says which records stay on
//! this device ([`Vault::with_kept`]); those never go out and are never
//! taken in.

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::backend::{Backend, BackendError, Entry};
use crate::clock::{Clock, DeviceId};
use crate::crypto::{self, CryptoError, Dek};
use crate::manifest::{KdfParams, Manifest, ManifestError, RecoveryCode};
use crate::model::Collection;
use crate::ops::{Op, Segment};
use crate::policy::{removed_devices, Kept, REMOVED_AFTER, REMOVED_AT};
use crate::state::{Snapshot, SnapshotRecord, State};

pub const MANIFEST_NAME: &str = "vault.json";
pub const DEVICES_DIR: &str = "devices";

/// Write a snapshot once a device's folder has more than this many
/// segments, or they total more than this many bytes.
pub const COMPACT_AFTER_SEGMENTS: usize = 20;
pub const COMPACT_AFTER_BYTES: u64 = 256 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("storage: {0}")]
    Backend(#[from] BackendError),
    #[error("{0}")]
    Manifest(#[from] ManifestError),
    #[error("{0}")]
    Crypto(#[from] CryptoError),
    #[error("{0} is not valid: {1}")]
    Corrupt(String, String),
    #[error("there is no vault in this folder")]
    NoVault,
    #[error("there is already a vault in this folder")]
    VaultExists,
    #[error("this folder now holds a different vault")]
    DifferentVault,
    #[error("the vault's passphrase or key was changed on another device")]
    KeysChanged,
}

/// What this device has applied from another device's folder.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Marker {
    /// The newest snapshot applied, by its number; 0 for none.
    pub snap: u64,
    /// Every segment up to this number has been applied.
    pub seq: u64,
    /// Segments above `seq` applied already, because one before them could
    /// not be read yet (damaged, half synced, not arrived). `seq` stays
    /// below the missing one so it is tried again; these are not re-read.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub ahead: BTreeSet<u64>,
}

impl Marker {
    /// The highest file number applied, gaps or not.
    pub fn highest(&self) -> u64 {
        let ahead = self.ahead.last().copied().unwrap_or(0);
        self.seq.max(self.snap).max(ahead)
    }
}

/// Everything the caller persists between syncs besides the state itself.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    /// The number of the last segment this device wrote.
    pub my_seq: u64,
    /// The number of the last snapshot this device wrote.
    pub my_snap: u64,
    pub markers: BTreeMap<DeviceId, Marker>,
    /// A full snapshot is owed and is written at the next chance: kept
    /// until one is written, so a failure is made up on a later sync.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub snapshot_due: bool,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PullReport {
    pub files_applied: usize,
    pub ops_applied: usize,
    /// Files that could not be read, with why. Sync carries on without them.
    pub warnings: Vec<String>,
    /// Every device with a folder, this one excluded.
    pub devices_seen: Vec<DeviceId>,
}

/// One device's handle on a vault.
#[derive(Clone)]
pub struct Vault<'a> {
    backend: &'a dyn Backend,
    vault_id: String,
    device: DeviceId,
    dek: Dek,
    kept: Kept,
}

/// What one pull read from one device's folder, before any of it applies.
struct Folder {
    device: DeviceId,
    /// Every segment number listed, in order.
    listed: Vec<u64>,
    snapshot: Option<(u64, Result<Snapshot, String>)>,
    segments: BTreeMap<u64, Result<Segment, String>>,
}

/// What a device writes about its own record is applied, except whether
/// it was removed: only another device may say that.
fn is_own_removal(device: &DeviceId, col: Collection, id: &str, field: &str) -> bool {
    col == Collection::Devices
        && (field == REMOVED_AT || field == REMOVED_AFTER)
        && id == device.as_uuid().to_string()
}

/// `NNNNNN.seg` or `NNNNNN.snap`.
fn parse_name(name: &str) -> Option<(u64, bool)> {
    let (num, ext) = name.rsplit_once('.')?;
    if num.len() != 6 || !num.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n: u64 = num.parse().ok()?;
    match ext {
        "seg" => Some((n, false)),
        "snap" => Some((n, true)),
        _ => None,
    }
}

fn seg_name(n: u64) -> String {
    format!("{n:06}.seg")
}

fn snap_name(n: u64) -> String {
    format!("{n:06}.snap")
}

impl<'a> Vault<'a> {
    /// Create a brand new vault in an empty folder.
    pub fn create(
        backend: &'a dyn Backend,
        device: DeviceId,
        passphrase: &str,
        params: KdfParams,
    ) -> Result<(Self, RecoveryCode), SyncError> {
        if backend.list("")?.iter().any(|e| e.name == MANIFEST_NAME) {
            return Err(SyncError::VaultExists);
        }
        let (manifest, dek, recovery) = Manifest::create(passphrase, params);
        backend.put_new(MANIFEST_NAME, manifest.to_json().as_bytes())?;
        Ok((
            Self::with_dek(backend, device, manifest.vault_id, dek),
            recovery,
        ))
    }

    /// Read the manifest of an existing vault.
    pub fn read_manifest(backend: &dyn Backend) -> Result<Manifest, SyncError> {
        match backend.get(MANIFEST_NAME) {
            Ok(bytes) => Ok(Manifest::from_json(&bytes)?),
            Err(BackendError::NotFound(_)) => Err(SyncError::NoVault),
            Err(e) => Err(e.into()),
        }
    }

    /// Look at the manifest again, as every sync does before anything else,
    /// and return its [`Manifest::keys_fingerprint`]. It is one small read.
    /// `known` is the fingerprint this device saw last, if it has one.
    ///
    /// - No manifest: [`SyncError::NoVault`]. The folder was deleted or
    ///   emptied, and writing into it would leave a vault no device can join.
    /// - A newer format: the manifest error saying so.
    /// - Another vault id: [`SyncError::DifferentVault`].
    /// - Rewrapped keys (a passphrase change, or a new data key):
    ///   [`SyncError::KeysChanged`], until this device unlocks it again.
    pub fn check_manifest(&self, known: Option<&str>) -> Result<String, SyncError> {
        let manifest = Self::read_manifest(self.backend)?;
        if manifest.vault_id != self.vault_id {
            return Err(SyncError::DifferentVault);
        }
        let now = manifest.keys_fingerprint();
        match known {
            Some(k) if k != now => Err(SyncError::KeysChanged),
            _ => Ok(now),
        }
    }

    /// Write a manifest again for a vault whose folder lost it, from the
    /// data key this device still holds: same vault id, same key, so every
    /// file still opens. Wrapped under `passphrase`, with a new recovery
    /// code; the old code stops working.
    pub fn recreate_manifest(
        &self,
        passphrase: &str,
        params: KdfParams,
    ) -> Result<(Manifest, RecoveryCode), SyncError> {
        if Self::read_manifest(self.backend).is_ok() {
            return Err(SyncError::VaultExists);
        }
        let (manifest, recovery) =
            Manifest::create_for(self.vault_id.clone(), &self.dek, passphrase, params);
        self.backend
            .put_new(MANIFEST_NAME, manifest.to_json().as_bytes())?;
        Ok((manifest, recovery))
    }

    /// Put `manifest` in place of the one this device last saw, whose
    /// [`Manifest::keys_fingerprint`] is `known`. If another device changed
    /// it meanwhile, nothing is written: [`SyncError::KeysChanged`].
    pub fn replace_manifest(&self, known: &str, manifest: &Manifest) -> Result<(), SyncError> {
        if manifest.vault_id != self.vault_id {
            return Err(SyncError::DifferentVault);
        }
        self.check_manifest(Some(known))?;
        self.backend
            .replace(MANIFEST_NAME, manifest.to_json().as_bytes())?;
        Ok(())
    }

    /// Give the vault a new data key (VAULT.md section 11): it is wrapped
    /// under `passphrase` and a new recovery code, and the manifest is
    /// replaced. The handle returned writes with the new key. The caller
    /// then encrypts its secrets again and writes a snapshot with it, which
    /// also removes this device's files under the old key. Whoever has only
    /// the old key can read nothing written from then on.
    pub fn rotate(
        &self,
        known: &str,
        passphrase: &str,
        params: KdfParams,
    ) -> Result<(Vault<'a>, Manifest, RecoveryCode), SyncError> {
        let dek = Dek::generate();
        let (manifest, recovery) =
            Manifest::create_for(self.vault_id.clone(), &dek, passphrase, params);
        self.replace_manifest(known, &manifest)?;
        let mut vault = self.clone();
        vault.dek = dek;
        Ok((vault, manifest, recovery))
    }

    /// Open an existing vault with its passphrase.
    pub fn open(
        backend: &'a dyn Backend,
        device: DeviceId,
        passphrase: &str,
    ) -> Result<Self, SyncError> {
        let manifest = Self::read_manifest(backend)?;
        let dek = manifest.unlock(passphrase)?;
        Ok(Self::with_dek(backend, device, manifest.vault_id, dek))
    }

    /// Open an existing vault with its recovery code.
    pub fn open_with_recovery(
        backend: &'a dyn Backend,
        device: DeviceId,
        code: &RecoveryCode,
    ) -> Result<Self, SyncError> {
        let manifest = Self::read_manifest(backend)?;
        let dek = manifest.unlock_with_recovery(code)?;
        Ok(Self::with_dek(backend, device, manifest.vault_id, dek))
    }

    /// Open with a data key already in hand (from a QR enrolment, or kept
    /// locally after the first unlock).
    pub fn with_dek(
        backend: &'a dyn Backend,
        device: DeviceId,
        vault_id: String,
        dek: Dek,
    ) -> Self {
        Self {
            backend,
            vault_id,
            device,
            dek,
            kept: Kept::new(),
        }
    }

    /// The records that stay on this device (see [`crate::policy`]). Their
    /// operations are never pushed, snapshots carry only their tombstones,
    /// and whatever other devices say about them is not applied.
    pub fn with_kept(mut self, kept: Kept) -> Self {
        self.kept = kept;
        self
    }

    pub fn kept(&self) -> &Kept {
        &self.kept
    }

    /// The same vault, writing into another device folder: for a device
    /// that was removed and joins again as a new one.
    pub fn for_device(&self, device: DeviceId) -> Self {
        let mut vault = self.clone();
        vault.device = device;
        vault
    }

    pub fn vault_id(&self) -> &str {
        &self.vault_id
    }

    pub fn device(&self) -> &DeviceId {
        &self.device
    }

    pub fn dek(&self) -> &Dek {
        &self.dek
    }

    fn device_dir(device: &DeviceId) -> String {
        format!("{DEVICES_DIR}/{device}")
    }

    fn read_file<T: serde::de::DeserializeOwned>(
        &self,
        device: &DeviceId,
        name: &str,
    ) -> Result<T, SyncError> {
        let path = format!("{}/{name}", Self::device_dir(device));
        let bytes = self.backend.get(&path)?;
        let plain = crypto::open(
            &self.dek,
            &crypto::aad(&self.vault_id, device, name),
            &bytes,
        )?;
        serde_json::from_slice(&plain).map_err(|e| SyncError::Corrupt(path, e.to_string()))
    }

    fn write_file<T: serde::Serialize>(&self, name: &str, value: &T) -> Result<(), SyncError> {
        let plain = serde_json::to_vec(value).expect("vault files serialise");
        let bytes = crypto::seal(
            &self.dek,
            &crypto::aad(&self.vault_id, &self.device, name),
            &plain,
        )?;
        let path = format!("{}/{name}", Self::device_dir(&self.device));
        Ok(self.backend.put_new(&path, &bytes)?)
    }

    /// The other devices' folders.
    pub fn other_devices(&self) -> Result<Vec<DeviceId>, SyncError> {
        Ok(self
            .backend
            .list(DEVICES_DIR)?
            .into_iter()
            .filter(|e| e.is_dir)
            .filter_map(|e| DeviceId::parse(&e.name))
            .filter(|d| *d != self.device)
            .collect())
    }

    /// An operation from `device` as it may be applied here: `None` for a
    /// record kept on this device, and never a device's say about its own
    /// removal.
    fn admit<'o>(&self, device: &DeviceId, op: &'o Op) -> Option<Cow<'o, Op>> {
        if self.kept.contains_key(&(op.col(), op.id().to_string())) {
            return None;
        }
        match op {
            Op::Put {
                col,
                id,
                ts,
                at,
                fields,
            } if fields.keys().any(|f| is_own_removal(device, *col, id, f)) => {
                let fields: BTreeMap<_, _> = fields
                    .iter()
                    .filter(|(f, _)| !is_own_removal(device, *col, id, f))
                    .map(|(f, v)| (f.clone(), v.clone()))
                    .collect();
                (!fields.is_empty()).then(|| {
                    Cow::Owned(Op::Put {
                        col: *col,
                        id: id.clone(),
                        ts: ts.clone(),
                        at: at.clone(),
                        fields,
                    })
                })
            }
            _ => Some(Cow::Borrowed(op)),
        }
    }

    /// A snapshot from `device` as it may be applied here, as [`Self::admit`].
    fn admit_snapshot(&self, device: &DeviceId, snap: &Snapshot) -> Snapshot {
        let mut snap = snap.clone();
        snap.records
            .retain(|r| !self.kept.contains_key(&(r.col, r.id.clone())));
        for r in &mut snap.records {
            let (col, id) = (r.col, r.id.clone());
            r.fields.retain(|f, _| !is_own_removal(device, col, &id, f));
        }
        snap
    }

    /// Apply everything new from every other device.
    ///
    /// Everything new is read first and applied after, so that a device
    /// removed in a file read now is cut off in this same pull, whatever
    /// order the folders come in: removals are worked out from every file,
    /// then each device's files apply up to its cut-off.
    pub fn pull(
        &self,
        sync: &mut SyncState,
        state: &mut State,
        clock: &mut Clock,
    ) -> Result<PullReport, SyncError> {
        let mut report = PullReport::default();
        let removed_before = removed_devices(state);
        let mut folders = Vec::new();
        for device in self.other_devices()? {
            report.devices_seen.push(device.clone());
            let limit = removed_before.get(&device).copied().unwrap_or(u64::MAX);
            let marker = sync.markers.get(&device).cloned().unwrap_or_default();
            let mut snaps = Vec::new();
            let mut listed = Vec::new();
            for e in self.backend.list(&Self::device_dir(&device))? {
                match parse_name(&e.name) {
                    Some((n, true)) if !e.is_dir => snaps.push(n),
                    Some((n, false)) if !e.is_dir => listed.push(n),
                    _ => {}
                }
            }
            listed.sort_unstable();
            // The newest snapshot, if it is newer than what we applied.
            let mut covered = marker.seq;
            let snapshot = snaps
                .into_iter()
                .filter(|n| *n <= limit)
                .max()
                .filter(|n| *n > marker.snap)
                .map(|n| {
                    let read = self.read_file::<Snapshot>(&device, &snap_name(n));
                    if read.is_ok() {
                        covered = covered.max(n);
                    }
                    (n, read.map_err(|e| e.to_string()))
                });
            let segments = listed
                .iter()
                .filter(|n| **n > covered && **n <= limit && !marker.ahead.contains(n))
                .map(|n| {
                    let read = self.read_file::<Segment>(&device, &seg_name(*n));
                    (*n, read.map_err(|e| e.to_string()))
                })
                .collect();
            folders.push(Folder {
                device,
                listed,
                snapshot,
                segments,
            });
        }

        // Who is removed, counting what was just read.
        let mut devices = State::new();
        for (col, id, r) in state.records() {
            if col == Collection::Devices {
                devices.insert_record(col, id.to_string(), r.clone());
            }
        }
        for f in &folders {
            if let Some((_, Ok(snap))) = &f.snapshot {
                let mut snap = self.admit_snapshot(&f.device, snap);
                snap.records.retain(|r| r.col == Collection::Devices);
                devices.apply_snapshot(&snap);
            }
            for seg in f.segments.values().flatten() {
                for op in seg.ops.iter().filter(|op| op.col() == Collection::Devices) {
                    if let Some(op) = self.admit(&f.device, op) {
                        devices.apply(&op);
                    }
                }
            }
        }
        let removed = removed_devices(&devices);

        for f in folders {
            let device = f.device;
            let limit = removed.get(&device).copied().unwrap_or(u64::MAX);
            let marker = sync.markers.entry(device.clone()).or_default();
            // One snapshot that cannot be read stands for every segment it
            // replaced, so those are not reported missing one by one.
            let mut unread_snapshot = 0;
            if let Some((n, read)) = f.snapshot.filter(|(n, _)| *n <= limit) {
                match read {
                    Ok(snap) => {
                        let snap = self.admit_snapshot(&device, &snap);
                        let changed = state.apply_snapshot(&snap);
                        for r in &snap.records {
                            for (_, ts) in r.fields.values() {
                                clock.observe(ts);
                            }
                            if let Some(d) = &r.deleted {
                                clock.observe(d);
                            }
                        }
                        report.files_applied += 1;
                        report.ops_applied += changed;
                        marker.snap = n;
                        marker.seq = marker.seq.max(n);
                    }
                    Err(e) => {
                        unread_snapshot = n;
                        report
                            .warnings
                            .push(format!("{}/{}: {e}", device, snap_name(n)));
                    }
                }
            }
            // Then every segment above the marker, up to its cut-off if it
            // was removed. Merging does not depend on order, so one that
            // cannot be read yet (damaged, still syncing, or not arrived: a
            // mirror can deliver files out of order) is skipped and the rest
            // still apply. The marker stays below it, so it is read again
            // next time and nothing in it is lost if it turns up whole later.
            let mut segments = f.segments;
            let mut expect = marker.seq + 1;
            let mut gap_reported = false;
            for n in f.listed {
                if n <= marker.seq || n > limit {
                    continue;
                }
                let first_missing = expect.max(unread_snapshot + 1);
                if n > first_missing && !gap_reported {
                    report.warnings.push(format!(
                        "{}/{}: has not arrived yet",
                        device,
                        seg_name(first_missing)
                    ));
                    gap_reported = true;
                }
                expect = n + 1;
                if marker.ahead.contains(&n) {
                    continue;
                }
                // Not read: a snapshot covered it, then turned out to be
                // past the device's cut-off. It is read next time.
                let Some(read) = segments.remove(&n) else {
                    continue;
                };
                match read {
                    Ok(seg) => {
                        for op in &seg.ops {
                            clock.observe(op.ts());
                            if let Some(op) = self.admit(&device, op) {
                                if state.apply(&op) {
                                    report.ops_applied += 1;
                                }
                            }
                        }
                        report.files_applied += 1;
                        marker.ahead.insert(n);
                    }
                    Err(e) => report
                        .warnings
                        .push(format!("{}/{}: {e}", device, seg_name(n))),
                }
            }
            let seq = marker.seq;
            marker.ahead.retain(|n| *n > seq);
            while marker.ahead.remove(&(marker.seq + 1)) {
                marker.seq += 1;
            }
        }
        Ok(report)
    }

    /// Before this device's first write since its sync state was reset (a
    /// fresh device, or one that disconnected and joined again), carry on
    /// numbering after whatever its folder already holds. Other devices have
    /// applied those numbers, so reusing them would hide the new files.
    fn resume_numbering(&self, sync: &mut SyncState) -> Result<(), SyncError> {
        if sync.my_seq == 0 {
            let dir = Self::device_dir(&self.device);
            for e in self.backend.list(&dir)? {
                if let Some((n, _)) = parse_name(&e.name) {
                    sync.my_seq = sync.my_seq.max(n);
                }
            }
        }
        Ok(())
    }

    /// Write pending operations as the next segment. Returns its number.
    /// Operations on records kept on this device are left out; when that
    /// leaves nothing, nothing is written and the last number is returned.
    pub fn push(&self, sync: &mut SyncState, ops: &[Op]) -> Result<u64, SyncError> {
        self.resume_numbering(sync)?;
        let ops: Vec<Op> = ops
            .iter()
            .filter(|op| !self.kept.contains_key(&(op.col(), op.id().to_string())))
            .cloned()
            .collect();
        if ops.is_empty() {
            return Ok(sync.my_seq);
        }
        let ops = &ops[..];
        let mut seq = sync.my_seq + 1;
        loop {
            let segment = Segment::new(self.device.clone(), seq, ops.to_vec());
            match self.write_file(&seg_name(seq), &segment) {
                Ok(()) => break,
                Err(SyncError::Backend(BackendError::AlreadyExists(_))) => {
                    // A previous push wrote this file but we never heard. If it
                    // holds these same operations we are done; if not (more were
                    // queued since), it stands as it is and these go in the next.
                    match self.read_file::<Segment>(&self.device, &seg_name(seq)) {
                        Ok(existing) if existing.ops == ops => break,
                        Ok(_) => seq += 1,
                        // Cut short by a crash where files are written in place
                        // (no hard links), or damaged since. Another device may
                        // have read it whole before, so its number stays used:
                        // these go in the next, and a snapshot owed now carries
                        // everything to those that could not read it.
                        Err(SyncError::Crypto(_) | SyncError::Corrupt(..)) => {
                            sync.snapshot_due = true;
                            seq += 1;
                        }
                        Err(e) => return Err(e),
                    }
                }
                Err(e) => return Err(e),
            }
        }
        sync.my_seq = seq;
        Ok(seq)
    }

    /// The snapshot this device writes: everything, except that a record
    /// kept on this device is only its tombstone.
    fn snapshot_of(&self, state: &State, seq: u64, clock: &Clock) -> Snapshot {
        let mut snap = state.to_snapshot(self.device.clone(), seq, clock.counter());
        snap.records
            .retain(|r| !self.kept.contains_key(&(r.col, r.id.clone())));
        snap.records
            .extend(self.kept.iter().map(|((col, id), ts)| SnapshotRecord {
                col: *col,
                id: id.clone(),
                deleted: Some(ts.clone()),
                fields: BTreeMap::new(),
            }));
        snap
    }

    /// Write a snapshot of `state` at this device's current segment number
    /// and drop the files it makes redundant; then tidy away the folders of
    /// removed devices it now covers.
    pub fn write_snapshot(
        &self,
        sync: &mut SyncState,
        state: &State,
        clock: &Clock,
    ) -> Result<(), SyncError> {
        self.resume_numbering(sync)?;
        let mut seq = sync.my_seq;
        loop {
            let snap = self.snapshot_of(state, seq, clock);
            match self.write_file(&snap_name(seq), &snap) {
                Ok(()) => break,
                // An older snapshot holds this number. Take the next one, which
                // no segment uses yet, rather than leave that one standing.
                Err(SyncError::Backend(BackendError::AlreadyExists(_))) => seq += 1,
                Err(e) => return Err(e),
            }
        }
        sync.my_seq = seq;
        sync.my_snap = seq;
        sync.snapshot_due = false;
        let dir = Self::device_dir(&self.device);
        for e in self.backend.list(&dir)? {
            if let Some((n, is_snap)) = parse_name(&e.name) {
                let stale = if is_snap { n < seq } else { n <= seq };
                if stale {
                    self.backend.delete(&format!("{dir}/{}", e.name))?;
                }
            }
        }
        self.tidy_removed(sync, state);
        Ok(())
    }

    /// Delete the folder of every removed device whose files, up to its
    /// cut-off, this device has all applied: a snapshot of ours then holds
    /// everything it had, and nothing past the cut-off counts. Returns the
    /// devices tidied away. A folder that will not go now is tried again at
    /// the next snapshot.
    pub fn tidy_removed(&self, sync: &SyncState, state: &State) -> Vec<DeviceId> {
        let mut tidied = Vec::new();
        for (other, after) in removed_devices(state) {
            if other == self.device {
                continue;
            }
            let covered = sync
                .markers
                .get(&other)
                .map_or(after == 0, |m| m.seq >= after);
            let present = self
                .backend
                .list(&Self::device_dir(&other))
                .is_ok_and(|files| !files.is_empty());
            if covered && present {
                match self.delete_device_folder(&other) {
                    Ok(()) => tidied.push(other),
                    Err(e) => tracing::warn!("could not tidy away a removed device: {e}"),
                }
            }
        }
        tidied
    }

    /// Write a snapshot if one is owed or this device's folder has grown
    /// past the limits.
    pub fn maybe_compact(
        &self,
        sync: &mut SyncState,
        state: &State,
        clock: &Clock,
    ) -> Result<bool, SyncError> {
        let dir = Self::device_dir(&self.device);
        let segs: Vec<Entry> = self
            .backend
            .list(&dir)?
            .into_iter()
            .filter(|e| matches!(parse_name(&e.name), Some((_, false))))
            .collect();
        let bytes: u64 = segs.iter().map(|e| e.size).sum();
        if sync.snapshot_due || segs.len() > COMPACT_AFTER_SEGMENTS || bytes > COMPACT_AFTER_BYTES {
            self.write_snapshot(sync, state, clock)?;
            return Ok(true);
        }
        Ok(false)
    }

    /// Remove another device's folder, once a snapshot of ours carries
    /// everything it had.
    pub fn delete_device_folder(&self, other: &DeviceId) -> Result<(), SyncError> {
        if *other == self.device {
            return Ok(());
        }
        let dir = Self::device_dir(other);
        for e in self.backend.list(&dir)? {
            self.backend.delete(&format!("{dir}/{}", e.name))?;
        }
        self.backend.delete(&dir)?;
        Ok(())
    }

    /// Size of every file in the vault, for the status line.
    pub fn total_bytes(&self) -> Result<u64, SyncError> {
        let mut total = 0;
        for e in self.backend.list("")? {
            total += e.size;
        }
        for d in self.backend.list(DEVICES_DIR)? {
            for e in self.backend.list(&format!("{DEVICES_DIR}/{}", d.name))? {
                total += e.size;
            }
        }
        Ok(total)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::MemoryBackend;
    use crate::model::Collection;
    use serde_json::{json, Map, Value};

    struct Device {
        id: DeviceId,
        state: State,
        clock: Clock,
        sync: SyncState,
        pending: Vec<Op>,
    }

    impl Device {
        fn new() -> Self {
            Self::with_id(DeviceId::generate())
        }

        /// A device with an id made of one repeated hex digit, so tests can
        /// choose which folder lists first.
        fn named(c: char) -> Self {
            Self::with_id(DeviceId::parse(&c.to_string().repeat(32)).unwrap())
        }

        fn with_id(id: DeviceId) -> Self {
            Self {
                id: id.clone(),
                state: State::new(),
                clock: Clock::new(id),
                sync: SyncState::default(),
                pending: Vec::new(),
            }
        }

        fn put(&mut self, col: Collection, id: &str, fields: Value) {
            let fields: Map<String, Value> = fields.as_object().unwrap().clone();
            let ts = self.clock.tick();
            if let Some(op) = self.state.put_diff(col, id, &fields, ts, String::new()) {
                self.state.apply(&op);
                self.pending.push(op);
            }
        }

        fn del(&mut self, col: Collection, id: &str) {
            let op = Op::Del {
                col,
                id: id.into(),
                ts: self.clock.tick(),
                at: String::new(),
            };
            self.state.apply(&op);
            self.pending.push(op);
        }

        fn sync(&mut self, vault: &Vault) -> PullReport {
            let report = vault
                .pull(&mut self.sync, &mut self.state, &mut self.clock)
                .unwrap();
            if !self.pending.is_empty() {
                vault.push(&mut self.sync, &self.pending).unwrap();
                self.pending.clear();
            }
            vault
                .maybe_compact(&mut self.sync, &self.state, &self.clock)
                .unwrap();
            report
        }

        fn hosts(&self) -> Vec<(String, Map<String, Value>)> {
            self.state.list(Collection::Hosts)
        }
    }

    fn fast() -> KdfParams {
        KdfParams::fast_for_tests()
    }

    #[test]
    fn two_devices_converge_through_a_shared_folder_and_a_third_catches_up() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let mut b = Device::new();

        // A creates the vault and adds a host.
        let (va, recovery) = Vault::create(&backend, a.id.clone(), "pass", fast()).unwrap();
        assert!(matches!(
            Vault::create(&backend, a.id.clone(), "pass", fast()),
            Err(SyncError::VaultExists)
        ));
        a.put(
            Collection::Hosts,
            "h1",
            json!({"label": "web-1", "port": 22}),
        );
        a.sync(&va);
        // A always leaves a snapshot behind after enrolling.
        va.write_snapshot(&mut a.sync, &a.state, &a.clock).unwrap();
        assert_eq!(
            backend.list(&format!("devices/{}", a.id)).unwrap().len(),
            1,
            "segment compacted into the snapshot"
        );

        // B joins with the passphrase and sees the host.
        assert!(matches!(
            Vault::open(&backend, b.id.clone(), "nope"),
            Err(SyncError::Manifest(_))
        ));
        let vb = Vault::open(&backend, b.id.clone(), "pass").unwrap();
        let report = b.sync(&vb);
        assert_eq!(report.files_applied, 1);
        assert_eq!(b.hosts().len(), 1);
        assert_eq!(b.hosts()[0].1["label"], "web-1");
        assert!(
            b.clock.counter() >= a.clock.counter(),
            "B's clock caught up"
        );

        // Both edit the same host, different fields, before either syncs.
        b.put(
            Collection::Hosts,
            "h1",
            json!({"label": "web-1", "port": 2222}),
        );
        a.put(
            Collection::Hosts,
            "h1",
            json!({"label": "web-one", "port": 22}),
        );
        b.sync(&vb);
        a.sync(&va);
        b.sync(&vb);
        let expect = json!({"label": "web-one", "port": 2222});
        assert_eq!(Value::Object(a.hosts()[0].1.clone()), expect);
        assert_eq!(Value::Object(b.hosts()[0].1.clone()), expect);

        // A deletes; B hears of it on its next sync.
        a.del(Collection::Hosts, "h1");
        a.sync(&va);
        b.sync(&vb);
        assert!(b.hosts().is_empty(), "the deletion arrived");

        // Lots of small pushes trigger compaction.
        for i in 0..25 {
            b.put(
                Collection::Snippets,
                &format!("s{i}"),
                json!({"label": format!("snip {i}"), "command": "ls"}),
            );
            b.sync(&vb);
        }
        let b_files = backend.list(&format!("devices/{}", b.id)).unwrap();
        assert!(
            b_files.iter().any(|e| e.name.ends_with(".snap")),
            "{b_files:?}"
        );
        assert!(b_files.len() < 25, "compacted: {}", b_files.len());

        // A third device from scratch, by recovery code, sees everything.
        let mut c = Device::new();
        let vc = Vault::open_with_recovery(&backend, c.id.clone(), &recovery).unwrap();
        let report = c.sync(&vc);
        assert!(report.warnings.is_empty(), "{:?}", report.warnings);
        assert_eq!(c.state.list(Collection::Snippets).len(), 25);
        assert!(c.hosts().is_empty());
        // Once A pulls B's snippets, every device shows the same records.
        // (Snapshots leave out fields a deletion hides, so C, which came in
        // from snapshots, holds less bookkeeping than A.)
        a.sync(&va);
        assert_eq!(c.hosts(), a.hosts());
        assert_eq!(
            c.state.list(Collection::Snippets),
            a.state.list(Collection::Snippets)
        );
        assert_eq!(report.devices_seen.len(), 2);
    }

    #[test]
    fn a_segment_that_arrives_late_is_still_applied() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        a.put(Collection::Hosts, "h1", json!({"label": "one"}));
        a.sync(&va);
        a.put(Collection::Hosts, "h2", json!({"label": "two"}));
        a.sync(&va);

        // A mirror delivers segment 2 before segment 1.
        let first = format!("devices/{}/000001.seg", a.id);
        let held = backend.get(&first).unwrap();
        backend.delete(&first).unwrap();

        let mut b = Device::new();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        let report = b.sync(&vb);
        assert_eq!(b.hosts().len(), 1, "the later segment applied anyway");
        assert_eq!(report.warnings.len(), 1, "{:?}", report.warnings);
        assert!(report.warnings[0].contains("000001.seg: has not arrived yet"));
        assert_eq!(b.sync.markers[&a.id].seq, 0, "still waiting for the first");
        let report = b.sync(&vb);
        assert_eq!(report.files_applied, 0, "the one applied is not read again");

        backend.put_new(&first, &held).unwrap();
        let report = b.sync(&vb);
        assert!(report.warnings.is_empty(), "{:?}", report.warnings);
        assert_eq!(b.hosts().len(), 2);
        assert_eq!(b.sync.markers[&a.id].seq, 2);
        assert!(b.sync.markers[&a.id].ahead.is_empty());
    }

    #[test]
    fn a_damaged_file_is_skipped_and_read_again_once_it_is_whole() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        for i in 1..=3 {
            a.put(Collection::Hosts, &format!("h{i}"), json!({"label": i}));
            a.sync(&va);
        }
        // The first segment is only partly synced, as a cloud folder can be.
        let path = format!("devices/{}/000001.seg", a.id);
        let whole = backend.get(&path).unwrap();
        backend.delete(&path).unwrap();
        backend.put_new(&path, &whole[..whole.len() / 2]).unwrap();

        let mut b = Device::new();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        let report = b.sync(&vb);
        assert_eq!(report.warnings.len(), 1, "{:?}", report.warnings);
        assert!(report.warnings[0].contains("000001.seg"));
        let labels: Vec<String> = b.hosts().into_iter().map(|(id, _)| id).collect();
        assert_eq!(labels, ["h2", "h3"], "everything after it still applied");
        assert_eq!(b.sync.markers[&a.id].seq, 0);

        // A's own later work is not held up either.
        a.put(Collection::Hosts, "h4", json!({"label": 4}));
        a.sync(&va);
        b.sync(&vb);
        assert_eq!(b.hosts().len(), 3);

        // The rest of the file arrives: it is read again and nothing is lost.
        backend.delete(&path).unwrap();
        backend.put_new(&path, &whole).unwrap();
        let report = b.sync(&vb);
        assert!(report.warnings.is_empty(), "{:?}", report.warnings);
        assert_eq!(b.hosts().len(), 4);
        assert_eq!(b.sync.markers[&a.id].seq, 4);
    }

    #[test]
    fn a_damaged_segment_keeps_its_number_and_a_snapshot_carries_it() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        for i in 1..=2 {
            a.put(Collection::Hosts, &format!("h{i}"), json!({"label": i}));
            a.sync(&va);
        }
        let mut b = Device::new();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        b.sync(&vb);

        // A writes segment 3 but dies before it records that, so h3 is
        // still queued. B reads segment 3 meanwhile.
        a.put(Collection::Hosts, "h3", json!({"label": 3}));
        let mut unsaved = a.sync.clone();
        va.push(&mut unsaved, &a.pending).unwrap();
        b.sync(&vb);
        assert_eq!(b.hosts().len(), 3);
        assert_eq!(b.sync.markers[&a.id].seq, 3);

        // Then the file is damaged, as a crash mid-write or a mirror can
        // leave it, and A queues more before it tries again.
        let path = format!("devices/{}/000003.seg", a.id);
        let whole = backend.get(&path).unwrap();
        backend.delete(&path).unwrap();
        backend.put_new(&path, &whole[..whole.len() / 2]).unwrap();
        a.put(Collection::Hosts, "h4", json!({"label": 4}));
        a.sync(&va);
        assert_eq!(a.sync.my_seq, 4, "number 3 stays used");
        assert!(!a.sync.snapshot_due, "the owed snapshot was written");

        // B, which read the old 3, still gets h4; a new device gets it all.
        let report = b.sync(&vb);
        assert!(report.warnings.is_empty(), "{:?}", report.warnings);
        assert_eq!(b.hosts().len(), 4);
        let mut c = Device::new();
        let vc = Vault::open(&backend, c.id.clone(), "pw").unwrap();
        let report = c.sync(&vc);
        assert!(report.warnings.is_empty(), "{:?}", report.warnings);
        assert_eq!(c.hosts().len(), 4);
    }

    #[test]
    fn an_icloud_file_not_downloaded_yet_is_waited_for() {
        let dir = std::env::temp_dir().join(format!("promptly-icloud-{}", rand::random::<u32>()));
        let backend = crate::backend::LocalFolder::new(&dir);
        let mut a = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        for i in 1..=2 {
            a.put(Collection::Hosts, &format!("h{i}"), json!({"label": i}));
            a.sync(&va);
        }
        // iCloud evicted the first segment, leaving its placeholder.
        let folder = dir.join("devices").join(a.id.to_string());
        let real = folder.join("000001.seg");
        let held = std::fs::read(&real).unwrap();
        std::fs::remove_file(&real).unwrap();
        std::fs::write(folder.join(".000001.seg.icloud"), b"bplist").unwrap();

        let mut b = Device::new();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        let report = b.sync(&vb);
        assert_eq!(report.warnings.len(), 1, "{:?}", report.warnings);
        assert!(
            report.warnings[0].contains("still downloading"),
            "{:?}",
            report.warnings
        );
        assert_eq!(b.hosts().len(), 1);
        assert_eq!(b.sync.markers[&a.id].seq, 0, "not skipped past");

        std::fs::write(&real, held).unwrap();
        std::fs::remove_file(folder.join(".000001.seg.icloud")).unwrap();
        let report = b.sync(&vb);
        assert!(report.warnings.is_empty(), "{:?}", report.warnings);
        assert_eq!(b.hosts().len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_damaged_snapshot_does_not_report_every_segment_it_replaced() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        for i in 0..3 {
            a.put(Collection::Hosts, &format!("h{i}"), json!({"label": i}));
            a.sync(&va);
        }
        va.write_snapshot(&mut a.sync, &a.state, &a.clock).unwrap();
        a.put(Collection::Hosts, "late", json!({"label": "late"}));
        a.sync(&va);
        let snap = format!("devices/{}/000003.snap", a.id);
        let whole = backend.get(&snap).unwrap();
        backend.delete(&snap).unwrap();
        backend.put_new(&snap, b"PVLT not really").unwrap();

        let mut b = Device::new();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        let report = b.sync(&vb);
        assert_eq!(report.warnings.len(), 1, "{:?}", report.warnings);
        assert!(report.warnings[0].contains("000003.snap"));
        assert_eq!(b.hosts().len(), 1, "the segment after it applied");
        assert_eq!(b.sync.markers[&a.id].seq, 0);

        backend.delete(&snap).unwrap();
        backend.put_new(&snap, &whole).unwrap();
        let report = b.sync(&vb);
        assert!(report.warnings.is_empty(), "{:?}", report.warnings);
        assert_eq!(b.hosts().len(), 4);
        assert_eq!(b.sync.markers[&a.id].seq, 4);
    }

    #[test]
    fn every_sync_notices_a_missing_newer_or_rewrapped_manifest() {
        let backend = MemoryBackend::default();
        let a = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        let seen = va.check_manifest(None).unwrap();
        assert_eq!(va.check_manifest(Some(&seen)).unwrap(), seen);

        // The passphrase is changed on another device.
        let mut m = Vault::read_manifest(&backend).unwrap();
        m.change_passphrase(va.dek(), "new pass");
        backend.delete(MANIFEST_NAME).unwrap();
        backend
            .put_new(MANIFEST_NAME, m.to_json().as_bytes())
            .unwrap();
        assert!(matches!(
            va.check_manifest(Some(&seen)),
            Err(SyncError::KeysChanged)
        ));
        // Unlocking with the new one gives the same key, and a new fingerprint to keep.
        let reopened = Vault::open(&backend, a.id.clone(), "new pass").unwrap();
        assert_eq!(reopened.dek(), va.dek());
        let seen = reopened.check_manifest(None).unwrap();

        // A newer app wrote the folder.
        let newer = m.to_json().replace(r#""format": 1"#, r#""format": 2"#);
        backend.delete(MANIFEST_NAME).unwrap();
        backend.put_new(MANIFEST_NAME, newer.as_bytes()).unwrap();
        assert!(matches!(
            va.check_manifest(Some(&seen)),
            Err(SyncError::Manifest(ManifestError::NewerFormat(2)))
        ));

        // Someone made a different vault in the same place.
        let other = MemoryBackend::default();
        Vault::create(&other, a.id.clone(), "pw", fast()).unwrap();
        backend.delete(MANIFEST_NAME).unwrap();
        backend
            .put_new(MANIFEST_NAME, &other.get(MANIFEST_NAME).unwrap())
            .unwrap();
        assert!(matches!(
            va.check_manifest(Some(&seen)),
            Err(SyncError::DifferentVault)
        ));

        // The folder is gone. It can be set up again from the key this
        // device holds, and its files still open.
        backend.delete(MANIFEST_NAME).unwrap();
        assert!(matches!(
            va.check_manifest(Some(&seen)),
            Err(SyncError::NoVault)
        ));
        let (_, code) = va.recreate_manifest("fresh pass", fast()).unwrap();
        assert!(matches!(
            va.recreate_manifest("again", fast()),
            Err(SyncError::VaultExists)
        ));
        assert!(matches!(
            va.check_manifest(Some(&seen)),
            Err(SyncError::KeysChanged)
        ));
        let by_code = Vault::open_with_recovery(&backend, a.id.clone(), &code).unwrap();
        assert_eq!(by_code.vault_id(), va.vault_id());
        assert_eq!(by_code.dek(), va.dek());
    }

    #[test]
    fn a_retried_push_with_more_operations_publishes_all_of_them() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        a.put(Collection::Hosts, "h1", json!({"label": "one"}));
        // The upload lands but A never records it.
        let mut lost = a.sync.clone();
        va.push(&mut lost, &a.pending).unwrap();
        a.put(Collection::Hosts, "h2", json!({"label": "two"}));
        a.sync(&va);
        assert_eq!(a.sync.my_seq, 2, "the retry took the next number");

        let mut b = Device::new();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        b.sync(&vb);
        assert_eq!(b.hosts().len(), 2);

        // Retrying the very same operations reuses the file already there.
        a.put(Collection::Hosts, "h3", json!({"label": "three"}));
        let mut lost = a.sync.clone();
        va.push(&mut lost, &a.pending).unwrap();
        va.push(&mut a.sync, &a.pending).unwrap();
        assert_eq!(lost.my_seq, a.sync.my_seq);
    }

    #[test]
    fn rejoining_a_vault_keeps_numbering_after_the_old_files() {
        for compacted in [false, true] {
            let backend = MemoryBackend::default();
            let mut a = Device::new();
            let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
            for i in 0..3 {
                a.put(Collection::Hosts, &format!("h{i}"), json!({"label": "x"}));
                a.sync(&va);
            }
            if compacted {
                va.write_snapshot(&mut a.sync, &a.state, &a.clock).unwrap();
            }
            let mut b = Device::new();
            let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
            b.sync(&vb);
            assert_eq!(b.hosts().len(), 3);

            // A disconnects, adds a host offline, and joins again.
            a.sync = SyncState::default();
            a.put(Collection::Hosts, "new", json!({"label": "offline"}));
            a.sync(&va);
            va.write_snapshot(&mut a.sync, &a.state, &a.clock).unwrap();

            b.sync(&vb);
            assert_eq!(b.hosts().len(), 4, "compacted: {compacted}");
            let mut c = Device::new();
            let vc = Vault::open(&backend, c.id.clone(), "pw").unwrap();
            c.sync(&vc);
            assert_eq!(c.hosts().len(), 4, "compacted: {compacted}");
        }
    }

    #[test]
    fn a_tampered_file_is_skipped_with_a_warning_and_a_stale_snapshot_is_harmless() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        a.put(Collection::Hosts, "h", json!({"label": "one"}));
        a.sync(&va);
        a.put(Collection::Hosts, "h", json!({"label": "two"}));
        a.sync(&va);
        // Corrupt the second segment.
        let path = format!("devices/{}/000002.seg", a.id);
        let mut bytes = backend.get(&path).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 0xFF;
        backend.delete(&path).unwrap();
        backend.put_new(&path, &bytes).unwrap();

        let mut b = Device::new();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        let report = b.sync(&vb);
        assert_eq!(report.warnings.len(), 1, "{:?}", report.warnings);
        assert!(report.warnings[0].contains("tampered"));
        assert_eq!(b.hosts()[0].1["label"], "one", "the good segment applied");
        assert_eq!(
            b.sync.markers[&a.id].seq, 1,
            "the bad one is retried next time"
        );

        // Fix the file (A writes a snapshot) and B catches up.
        va.write_snapshot(&mut a.sync, &a.state, &a.clock).unwrap();
        let report = b.sync(&vb);
        assert!(report.warnings.is_empty());
        assert_eq!(b.hosts()[0].1["label"], "two");
    }

    /// Mark `who` removed on `by`, as far as `by` has read its files.
    fn remove(by: &mut Device, who: &DeviceId) {
        let after = by.sync.markers.get(who).map_or(0, Marker::highest);
        by.put(
            Collection::Devices,
            &who.as_uuid().to_string(),
            json!({"name": "gone", REMOVED_AT: "2026-10-17T10:00:00Z", REMOVED_AFTER: after}),
        );
    }

    #[test]
    fn a_removed_device_is_cut_off_even_in_the_pull_that_learns_of_it() {
        let backend = MemoryBackend::default();
        // B's folder lists before A's, so a fresh reader meets B's files
        // before the file that removes it.
        let mut a = Device::named('f');
        let mut b = Device::named('1');
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        b.put(Collection::Hosts, "h1", json!({"label": "before"}));
        b.sync(&vb);
        a.sync(&va);
        assert_eq!(a.hosts().len(), 1);

        remove(&mut a, &b.id);
        a.sync(&va);
        // B has not noticed yet and carries on, and tries to put itself back.
        b.put(Collection::Hosts, "h2", json!({"label": "after"}));
        b.put(
            Collection::Devices,
            &b.id.as_uuid().to_string(),
            json!({REMOVED_AFTER: null, "name": "still here"}),
        );
        vb.push(&mut b.sync, &b.pending).unwrap();
        b.pending.clear();

        a.sync(&va);
        assert_eq!(a.hosts().len(), 1, "nothing new from B is taken in");
        let mut c = Device::new();
        let vc = Vault::open(&backend, c.id.clone(), "pw").unwrap();
        let report = c.sync(&vc);
        assert!(report.warnings.is_empty(), "{:?}", report.warnings);
        let labels: Vec<_> = c.hosts().into_iter().map(|(id, _)| id).collect();
        assert_eq!(
            labels,
            ["h1"],
            "B's earlier work stays, its later work does not"
        );
        assert_eq!(
            removed_devices(&c.state).get(&b.id),
            Some(&1),
            "B could not undo its own removal"
        );

        // A's next snapshot covers everything B had, so B's folder goes.
        va.write_snapshot(&mut a.sync, &a.state, &a.clock).unwrap();
        assert!(backend
            .list(&format!("devices/{}", b.id))
            .unwrap()
            .is_empty());
        let mut d = Device::new();
        let vd = Vault::open(&backend, d.id.clone(), "pw").unwrap();
        d.sync(&vd);
        assert_eq!(d.hosts().len(), 1, "a newcomer still gets B's earlier host");
    }

    #[test]
    fn a_removed_device_folder_stays_until_everything_before_its_cut_off_is_read() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let mut b = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        for i in 1..=2 {
            b.put(Collection::Hosts, &format!("h{i}"), json!({"label": i}));
            b.sync(&vb);
        }
        // B's first file has not reached A yet; its second has.
        let first = format!("devices/{}/000001.seg", b.id);
        let held = backend.get(&first).unwrap();
        backend.delete(&first).unwrap();
        a.sync(&va);
        remove(&mut a, &b.id);
        a.sync(&va);
        va.write_snapshot(&mut a.sync, &a.state, &a.clock).unwrap();
        assert!(
            !backend
                .list(&format!("devices/{}", b.id))
                .unwrap()
                .is_empty(),
            "kept while a file before the cut-off is still to come"
        );

        backend.put_new(&first, &held).unwrap();
        a.sync(&va);
        assert_eq!(a.hosts().len(), 2, "it still counts: it was written before");
        va.write_snapshot(&mut a.sync, &a.state, &a.clock).unwrap();
        assert!(backend
            .list(&format!("devices/{}", b.id))
            .unwrap()
            .is_empty());
    }

    #[test]
    fn records_kept_on_a_device_never_leave_it_and_leave_the_vault_when_switched() {
        use crate::policy::{kept_on_device, plan_kept};
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let mut b = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        a.put(
            Collection::Hosts,
            "h",
            json!({"label": "home", "sync": "vault", "auth": {"kind": "password", "password_secret_id": "p"}}),
        );
        a.put(
            Collection::Secrets,
            "p",
            json!({"kind": "password", "ciphertext": [1, 2, 3]}),
        );
        a.sync(&va);
        b.sync(&vb);
        assert_eq!(b.hosts().len(), 1);

        // A keeps the host to itself from now on, and renames it.
        a.put(
            Collection::Hosts,
            "h",
            json!({"label": "home (private)", "sync": "local_only", "auth": {"kind": "password", "password_secret_id": "p"}}),
        );
        a.put(
            Collection::Secrets,
            "p",
            json!({"kind": "password", "ciphertext": [4, 5, 6]}),
        );
        let plan = plan_kept(&a.state, &Kept::new());
        assert!(plan.newly_kept);
        assert_eq!(plan.kept.len(), 2, "the host and its password");
        let kept = va.clone().with_kept(plan.kept.clone());
        assert_eq!(a.sync.my_seq, 1);
        a.sync(&kept);
        assert_eq!(a.sync.my_seq, 1, "nothing about it was written");
        // The snapshot carries the tombstones, and B's copies go.
        kept.write_snapshot(&mut a.sync, &a.state, &a.clock)
            .unwrap();
        b.sync(&vb);
        assert!(b.hosts().is_empty());
        assert!(b.state.list(Collection::Secrets).is_empty());
        assert_eq!(a.hosts()[0].1["label"], "home (private)", "A keeps its own");

        // B edits its old copy all the same; A takes none of it.
        b.put(Collection::Hosts, "h", json!({"label": "from b"}));
        b.sync(&vb);
        a.sync(&kept);
        assert_eq!(a.hosts()[0].1["label"], "home (private)");
        assert_eq!(
            a.state.get(Collection::Secrets, "p").unwrap()["ciphertext"],
            json!([4, 5, 6])
        );

        // A newcomer never sees the new name or the new password.
        let mut c = Device::new();
        let vc = Vault::open(&backend, c.id.clone(), "pw").unwrap();
        c.sync(&vc);
        assert!(c
            .hosts()
            .iter()
            .all(|(_, h)| h["label"] != "home (private)"));
        assert!(c.state.get(Collection::Secrets, "p").is_none());

        // Back into the vault: the record goes out again in full.
        a.put(
            Collection::Hosts,
            "h",
            json!({"label": "home (private)", "sync": "vault", "auth": {"kind": "password", "password_secret_id": "p"}}),
        );
        let back = plan_kept(&a.state, &plan.kept);
        assert!(back.kept.is_empty());
        assert_eq!(back.back.len(), 2);
        for (col, id) in &back.back {
            // As the store does it: deleted, then written whole, which
            // stamps the record as created again.
            let mut fields = a.state.get(*col, id).unwrap();
            fields.insert(crate::model::CREATED_AT.into(), json!("2026-10-18T00:00:00Z"));
            a.del(*col, id);
            a.put(*col, id, Value::Object(fields));
        }
        assert!(kept_on_device(&a.state).is_empty());
        a.sync(&va);
        c.sync(&vc);
        assert_eq!(c.hosts()[0].1["label"], "home (private)");
        assert_eq!(
            c.state.get(Collection::Secrets, "p").unwrap()["ciphertext"],
            json!([4, 5, 6])
        );
    }

    #[test]
    fn a_new_key_shuts_out_the_old_one() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let mut b = Device::new();
        let (va, old_code) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        a.put(Collection::Hosts, "h1", json!({"label": "before"}));
        a.sync(&va);
        b.sync(&vb);
        let known = va.check_manifest(None).unwrap();

        // Someone changed the manifest since A last looked: nothing happens.
        assert!(matches!(
            va.rotate("stale", "new pass", fast()),
            Err(SyncError::KeysChanged)
        ));
        assert_eq!(va.check_manifest(None).unwrap(), known);

        let (va2, manifest, code) = va.rotate(&known, "new pass", fast()).unwrap();
        assert_ne!(va2.dek(), va.dek());
        assert_eq!(manifest.vault_id, va.vault_id());
        va2.write_snapshot(&mut a.sync, &a.state, &a.clock).unwrap();
        let files = backend.list(&format!("devices/{}", a.id)).unwrap();
        assert_eq!(
            files.len(),
            1,
            "only the snapshot under the new key: {files:?}"
        );
        a.put(Collection::Hosts, "h2", json!({"label": "after"}));
        a.sync(&va2);

        // The old key, as a removed device still holds it, reads nothing new.
        let mut thief = Device::new();
        let old = Vault::with_dek(
            &backend,
            thief.id.clone(),
            va.vault_id().into(),
            va.dek().clone(),
        );
        let report = thief.sync(&old);
        assert!(thief.hosts().is_empty());
        assert!(!report.warnings.is_empty());
        assert!(Vault::open(&backend, thief.id.clone(), "pw").is_err());
        assert!(Vault::open_with_recovery(&backend, thief.id.clone(), &old_code).is_err());

        // B notices, and the passphrase gives it the new key.
        assert!(matches!(
            vb.check_manifest(Some(&known)),
            Err(SyncError::KeysChanged)
        ));
        let vb2 = Vault::open(&backend, b.id.clone(), "new pass").unwrap();
        assert_eq!(vb2.dek(), va2.dek());
        b.sync(&vb2);
        assert_eq!(b.hosts().len(), 2);
        let by_code = Vault::open_with_recovery(&backend, b.id.clone(), &code).unwrap();
        assert_eq!(by_code.dek(), va2.dek());
    }

    #[test]
    fn file_names_are_strict() {
        assert_eq!(parse_name("000001.seg"), Some((1, false)));
        assert_eq!(parse_name("000123.snap"), Some((123, true)));
        assert_eq!(parse_name("1.seg"), None);
        assert_eq!(parse_name("000001.txt"), None);
        assert_eq!(parse_name("000001.seg (conflicted copy)"), None);
        assert_eq!(seg_name(7), "000007.seg");
    }
}
