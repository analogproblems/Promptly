//! Pull, push and compaction, as specified in VAULT.md sections 8, 9 and 11.
//!
//! A [`Vault`] is one device's view of a vault on one backend. It holds the
//! data key and knows the device id; the caller keeps the merged [`State`],
//! the [`Clock`] and the [`SyncState`] (what has been applied so far) and
//! persists them between runs.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::backend::{Backend, BackendError, Entry};
use crate::clock::{Clock, DeviceId};
use crate::crypto::{self, CryptoError, Dek};
use crate::manifest::{KdfParams, Manifest, ManifestError, RecoveryCode};
use crate::ops::{Op, Segment};
use crate::state::{Snapshot, State};

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
    #[error("the vault's passphrase was changed on another device")]
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

/// Everything the caller persists between syncs besides the state itself.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    /// The number of the last segment this device wrote.
    pub my_seq: u64,
    /// The number of the last snapshot this device wrote.
    pub my_snap: u64,
    pub markers: BTreeMap<DeviceId, Marker>,
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
pub struct Vault<'a> {
    backend: &'a dyn Backend,
    vault_id: String,
    device: DeviceId,
    dek: Dek,
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
            Self {
                backend,
                vault_id: manifest.vault_id,
                device,
                dek,
            },
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
        }
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

    /// Apply everything new from every other device.
    pub fn pull(
        &self,
        sync: &mut SyncState,
        state: &mut State,
        clock: &mut Clock,
    ) -> Result<PullReport, SyncError> {
        let mut report = PullReport::default();
        for device in self.other_devices()? {
            report.devices_seen.push(device.clone());
            let entries = self.backend.list(&Self::device_dir(&device))?;
            let marker = sync.markers.entry(device.clone()).or_default();
            let mut files: Vec<(u64, bool, Entry)> = entries
                .into_iter()
                .filter(|e| !e.is_dir)
                .filter_map(|e| parse_name(&e.name).map(|(n, snap)| (n, snap, e)))
                .collect();
            files.sort_by_key(|(n, snap, _)| (*n, !*snap)); // snapshots before segments of the same number

            // The newest snapshot, if it is newer than what we applied. One
            // that cannot be read stands for every segment it replaced, so
            // those are not reported missing one by one.
            let mut unread_snapshot = 0;
            if let Some((n, _, entry)) = files
                .iter()
                .filter(|(_, s, _)| *s)
                .max_by_key(|(n, _, _)| *n)
            {
                if *n > marker.snap {
                    match self.read_file::<Snapshot>(&device, &entry.name) {
                        Ok(snap) => {
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
                            marker.snap = *n;
                            marker.seq = marker.seq.max(*n);
                        }
                        Err(e) => {
                            unread_snapshot = *n;
                            report
                                .warnings
                                .push(format!("{}/{}: {e}", device, entry.name));
                        }
                    }
                }
            }
            // Then every segment above the marker. Merging does not depend
            // on order, so one that cannot be read yet (damaged, still
            // syncing, or not arrived: a mirror can deliver files out of
            // order) is skipped and the rest still apply. The marker stays
            // below it, so it is read again next time and nothing in it is
            // lost if it turns up whole later.
            let mut expect = marker.seq + 1;
            let mut gap_reported = false;
            for (n, is_snap, entry) in &files {
                if *is_snap || *n <= marker.seq {
                    continue;
                }
                let first_missing = expect.max(unread_snapshot + 1);
                if *n > first_missing && !gap_reported {
                    report.warnings.push(format!(
                        "{}/{}: has not arrived yet",
                        device,
                        seg_name(first_missing)
                    ));
                    gap_reported = true;
                }
                expect = n + 1;
                if marker.ahead.contains(n) {
                    continue;
                }
                match self.read_file::<Segment>(&device, &entry.name) {
                    Ok(seg) => {
                        for op in &seg.ops {
                            clock.observe(op.ts());
                            if state.apply(op) {
                                report.ops_applied += 1;
                            }
                        }
                        report.files_applied += 1;
                        marker.ahead.insert(*n);
                    }
                    Err(e) => report
                        .warnings
                        .push(format!("{}/{}: {e}", device, entry.name)),
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
    pub fn push(&self, sync: &mut SyncState, ops: &[Op]) -> Result<u64, SyncError> {
        self.resume_numbering(sync)?;
        let mut seq = sync.my_seq + 1;
        let mut rewritten = false;
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
                        // (no hard links): only this device writes here and no
                        // one could read it, so it is written again whole.
                        Err(SyncError::Crypto(_) | SyncError::Corrupt(..)) if !rewritten => {
                            rewritten = true;
                            let dir = Self::device_dir(&self.device);
                            self.backend.delete(&format!("{dir}/{}", seg_name(seq)))?;
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

    /// Write a snapshot of `state` at this device's current segment number
    /// and drop the files it makes redundant.
    pub fn write_snapshot(
        &self,
        sync: &mut SyncState,
        state: &State,
        clock: &Clock,
    ) -> Result<(), SyncError> {
        self.resume_numbering(sync)?;
        let mut seq = sync.my_seq;
        loop {
            let snap = state.to_snapshot(self.device.clone(), seq, clock.counter());
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
        let dir = Self::device_dir(&self.device);
        for e in self.backend.list(&dir)? {
            if let Some((n, is_snap)) = parse_name(&e.name) {
                let stale = if is_snap { n < seq } else { n <= seq };
                if stale {
                    self.backend.delete(&format!("{dir}/{}", e.name))?;
                }
            }
        }
        Ok(())
    }

    /// Write a snapshot if this device's folder has grown past the limits.
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
        if segs.len() > COMPACT_AFTER_SEGMENTS || bytes > COMPACT_AFTER_BYTES {
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
            let id = DeviceId::generate();
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

        // A deletes, B still edits the same record a moment later: the later
        // edit wins field by field (the record comes back with that field).
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
        // Once A pulls B's snippets, every device holds the same state.
        a.sync(&va);
        assert_eq!(c.state, a.state);
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
    fn a_segment_cut_short_by_a_crash_is_written_again() {
        let backend = MemoryBackend::default();
        let mut a = Device::new();
        let (va, _) = Vault::create(&backend, a.id.clone(), "pw", fast()).unwrap();
        for i in 1..=2 {
            a.put(Collection::Hosts, &format!("h{i}"), json!({"label": i}));
            a.sync(&va);
        }
        assert_eq!(a.sync.my_seq, 2);
        // The app died while writing the next segment in place.
        let dir = format!("devices/{}", a.id);
        let some = backend.get(&format!("{dir}/000002.seg")).unwrap();
        backend
            .put_new(&format!("{dir}/000003.seg"), &some[..some.len() / 2])
            .unwrap();

        a.put(Collection::Hosts, "h3", json!({"label": 3}));
        a.sync(&va);
        assert_eq!(a.sync.my_seq, 3, "the same number, written whole");

        let mut b = Device::new();
        let vb = Vault::open(&backend, b.id.clone(), "pw").unwrap();
        let report = b.sync(&vb);
        assert!(report.warnings.is_empty(), "{:?}", report.warnings);
        assert_eq!(b.hosts().len(), 3);
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
