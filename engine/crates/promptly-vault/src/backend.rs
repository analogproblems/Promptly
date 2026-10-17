//! Storage backends: the four calls of VAULT.md section 10, and the local
//! folder, which also serves iCloud Drive and anything a sync client mirrors.

use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
pub enum BackendError {
    #[error("{0} already exists")]
    AlreadyExists(String),
    #[error("{0} was not found")]
    NotFound(String),
    /// The file exists in the cloud but this machine only has a placeholder
    /// for it so far. It is worth asking again later.
    #[error("{0} is still downloading")]
    NotDownloaded(String),
    #[error("{0}: {1}")]
    Io(String, std::io::Error),
    #[error("{0}")]
    Other(String),
}

/// One entry of a listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
}

/// What a storage must offer. Paths are relative to the vault folder and use
/// `/` as the separator. Listing a missing folder is an empty listing, and
/// deleting a missing file is fine: readers tolerate files that vanish.
/// A file the storage knows about but cannot hand over yet (an iCloud file
/// not downloaded) is listed, and reading it is [`BackendError::NotDownloaded`].
pub trait Backend: Send + Sync {
    fn list(&self, dir: &str) -> Result<Vec<Entry>, BackendError>;
    fn get(&self, path: &str) -> Result<Vec<u8>, BackendError>;
    /// Write a file that must not exist yet, creating parent folders.
    fn put_new(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError>;
    fn delete(&self, path: &str) -> Result<(), BackendError>;

    /// Put a whole new version of a file in place of the old one. Only the
    /// manifest is ever replaced, on a key change. Without a way to swap it
    /// in one step, the old one goes first, so for a moment there is none.
    fn replace(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError> {
        self.delete(path)?;
        self.put_new(path, bytes)
    }
}

/// A folder on this machine.
pub struct LocalFolder {
    root: PathBuf,
}

impl LocalFolder {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// iCloud Drive keeps a file it has not downloaded as a hidden
    /// `.NAME.icloud` placeholder beside where NAME would be.
    fn placeholder(p: &Path) -> Option<PathBuf> {
        let name = p.file_name()?.to_str()?;
        Some(p.with_file_name(format!(".{name}.icloud")))
    }

    fn resolve(&self, path: &str) -> Result<PathBuf, BackendError> {
        let mut out = self.root.clone();
        for part in path.split('/').filter(|p| !p.is_empty()) {
            if part == "." || part == ".." || part.contains('\\') {
                return Err(BackendError::Other(format!("bad path {path:?}")));
            }
            out.push(part);
        }
        Ok(out)
    }
}

impl Backend for LocalFolder {
    fn list(&self, dir: &str) -> Result<Vec<Entry>, BackendError> {
        let path = self.resolve(dir)?;
        let read = match std::fs::read_dir(&path) {
            Ok(r) => r,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(BackendError::Io(path.display().to_string(), e)),
        };
        let mut out = Vec::new();
        for entry in read {
            let entry = entry.map_err(|e| BackendError::Io(path.display().to_string(), e))?;
            let meta = match entry.metadata() {
                Ok(m) => m,
                Err(_) => continue, // vanished between listing and stat
            };
            let name = entry.file_name().to_string_lossy().into_owned();
            if let Some(real) = icloud_placeholder_name(&name) {
                // Listed under its real name, so readers wait for it rather
                // than skip past it; reading it asks for the download.
                out.push(Entry {
                    name: real.to_string(),
                    size: 0,
                    is_dir: false,
                });
                continue;
            }
            if name.starts_with('.') {
                continue; // temp files and the sync client's own bookkeeping
            }
            out.push(Entry {
                name,
                size: meta.len(),
                is_dir: meta.is_dir(),
            });
        }
        // A file that has just finished downloading can show up both ways
        // for a moment; keep the real one, which sorts first by size.
        out.sort_by(|a, b| a.name.cmp(&b.name).then(b.size.cmp(&a.size)));
        out.dedup_by(|later, first| later.name == first.name);
        Ok(out)
    }

    fn get(&self, path: &str) -> Result<Vec<u8>, BackendError> {
        let p = self.resolve(path)?;
        std::fs::read(&p).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => match Self::placeholder(&p) {
                Some(ph) if ph.exists() => {
                    request_download(&p);
                    BackendError::NotDownloaded(path.to_string())
                }
                _ => BackendError::NotFound(path.to_string()),
            },
            _ => BackendError::Io(p.display().to_string(), e),
        })
    }

    fn put_new(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError> {
        let p = self.resolve(path)?;
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| BackendError::Io(parent.display().to_string(), e))?;
        }
        // A placeholder means the file is already there, in the cloud.
        if p.exists() || Self::placeholder(&p).is_some_and(|ph| ph.exists()) {
            return Err(BackendError::AlreadyExists(path.to_string()));
        }
        // Write beside the target and link it into place, so a reader never
        // sees half a file.
        let tmp = p.with_file_name(format!(
            ".{}.tmp-{}",
            p.file_name()
                .map(|n| n.to_string_lossy())
                .unwrap_or_default(),
            std::process::id()
        ));
        std::fs::write(&tmp, bytes).map_err(|e| BackendError::Io(tmp.display().to_string(), e))?;
        let result = place_new(&tmp, &p, bytes, true);
        let _ = std::fs::remove_file(&tmp);
        result.map_err(|e| match e.kind() {
            std::io::ErrorKind::AlreadyExists => BackendError::AlreadyExists(path.to_string()),
            _ => BackendError::Io(p.display().to_string(), e),
        })
    }

    fn delete(&self, path: &str) -> Result<(), BackendError> {
        let p = self.resolve(path)?;
        if let Some(ph) = Self::placeholder(&p) {
            let _ = std::fs::remove_file(ph);
        }
        match std::fs::remove_file(&p) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) if p.is_dir() => std::fs::remove_dir_all(&p)
                .map_err(|e| BackendError::Io(p.display().to_string(), e)),
            Err(e) => Err(BackendError::Io(p.display().to_string(), e)),
        }
    }

    /// Written beside the old one and renamed over it, so a reader always
    /// finds one whole file, old or new.
    fn replace(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError> {
        let p = self.resolve(path)?;
        let tmp = p.with_file_name(format!(
            ".{}.tmp-{}",
            p.file_name()
                .map(|n| n.to_string_lossy())
                .unwrap_or_default(),
            std::process::id()
        ));
        let write = || -> std::io::Result<()> {
            use std::io::Write;
            let mut f = std::fs::File::create(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
            std::fs::rename(&tmp, &p)
        };
        write().map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            BackendError::Io(p.display().to_string(), e)
        })
    }
}

/// Put the file written at `tmp` in place at `target`, never replacing a
/// file already there. A hard link does that in one step and fails if the
/// target exists. Where links are not supported (some network shares, FAT)
/// the file is created with `create_new`, which refuses an existing file
/// just the same; a reader may then catch it half written, which fails its
/// check and is simply read again on the next sync.
fn place_new(tmp: &Path, target: &Path, bytes: &[u8], hard_links: bool) -> std::io::Result<()> {
    if hard_links {
        match std::fs::hard_link(tmp, target) {
            Ok(()) => return Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => return Err(e),
            Err(_) => {}
        }
    }
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)?;
    if let Err(e) = file.write_all(bytes).and_then(|()| file.sync_all()) {
        // Ours and incomplete: take it away so the retry can write it whole.
        drop(file);
        let _ = std::fs::remove_file(target);
        return Err(e);
    }
    Ok(())
}

/// `.NAME.icloud` is iCloud Drive's stand-in for NAME until it downloads.
pub fn icloud_placeholder_name(name: &str) -> Option<&str> {
    name.strip_prefix('.')?
        .strip_suffix(".icloud")
        .filter(|n| !n.is_empty())
}

/// Ask iCloud Drive to fetch a file it only has a placeholder for. On a Mac
/// `brctl` does that. iOS has no such command, so there the file arrives
/// when the system gets round to it, and a later sync picks it up.
fn request_download(path: &Path) {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("brctl")
            .arg("download")
            .arg(path)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = path;
}

/// A backend that keeps everything in memory, for tests and for a device
/// to device transfer.
#[derive(Default)]
pub struct MemoryBackend {
    files: std::sync::Mutex<std::collections::BTreeMap<String, Vec<u8>>>,
}

impl Backend for MemoryBackend {
    fn list(&self, dir: &str) -> Result<Vec<Entry>, BackendError> {
        let prefix = if dir.is_empty() {
            String::new()
        } else {
            format!("{}/", dir.trim_matches('/'))
        };
        let files = self.files.lock().unwrap();
        let mut out: Vec<Entry> = Vec::new();
        for (path, bytes) in files.iter() {
            let Some(rest) = path.strip_prefix(&prefix) else {
                continue;
            };
            match rest.split_once('/') {
                Some((d, _)) => {
                    if !out.iter().any(|e| e.name == d) {
                        out.push(Entry {
                            name: d.to_string(),
                            size: 0,
                            is_dir: true,
                        });
                    }
                }
                None => out.push(Entry {
                    name: rest.to_string(),
                    size: bytes.len() as u64,
                    is_dir: false,
                }),
            }
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(out)
    }

    fn get(&self, path: &str) -> Result<Vec<u8>, BackendError> {
        self.files
            .lock()
            .unwrap()
            .get(path)
            .cloned()
            .ok_or_else(|| BackendError::NotFound(path.to_string()))
    }

    fn put_new(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError> {
        let mut files = self.files.lock().unwrap();
        if files.contains_key(path) {
            return Err(BackendError::AlreadyExists(path.to_string()));
        }
        files.insert(path.to_string(), bytes.to_vec());
        Ok(())
    }

    fn delete(&self, path: &str) -> Result<(), BackendError> {
        let mut files = self.files.lock().unwrap();
        files.remove(path);
        let prefix = format!("{path}/");
        files.retain(|k, _| !k.starts_with(&prefix));
        Ok(())
    }

    fn replace(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError> {
        self.files
            .lock()
            .unwrap()
            .insert(path.to_string(), bytes.to_vec());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "promptly-backend-{}-{}",
            std::process::id(),
            rand::random::<u32>()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn exercise(b: &dyn Backend) {
        assert!(b.list("").unwrap().is_empty());
        assert!(b.list("devices/nothing").unwrap().is_empty());
        b.put_new("vault.json", b"{}").unwrap();
        b.put_new("devices/aa/000001.seg", b"one").unwrap();
        b.put_new("devices/aa/000002.seg", b"two").unwrap();
        b.put_new("devices/bb/000001.seg", b"three").unwrap();
        assert!(matches!(
            b.put_new("devices/aa/000001.seg", b"again"),
            Err(BackendError::AlreadyExists(_))
        ));
        assert_eq!(b.get("devices/aa/000001.seg").unwrap(), b"one");
        assert!(matches!(
            b.get("devices/aa/000009.seg"),
            Err(BackendError::NotFound(_))
        ));
        let root = b.list("").unwrap();
        assert_eq!(
            root.iter()
                .map(|e| (e.name.as_str(), e.is_dir))
                .collect::<Vec<_>>(),
            [("devices", true), ("vault.json", false)]
        );
        let devices: Vec<String> = b
            .list("devices")
            .unwrap()
            .into_iter()
            .map(|e| e.name)
            .collect();
        assert_eq!(devices, ["aa", "bb"]);
        let aa = b.list("devices/aa").unwrap();
        assert_eq!(aa.len(), 2);
        assert_eq!(aa[1].size, 3);
        b.delete("devices/aa/000001.seg").unwrap();
        b.delete("devices/aa/000001.seg").unwrap();
        assert_eq!(b.list("devices/aa").unwrap().len(), 1);
        b.delete("devices/bb").unwrap();
        assert!(b.list("devices/bb").unwrap().is_empty());
        b.replace("vault.json", b"{\"new\":1}").unwrap();
        assert_eq!(b.get("vault.json").unwrap(), b"{\"new\":1}");
        assert_eq!(b.list("").unwrap().len(), 2, "one manifest, no temp file");
    }

    #[test]
    fn local_folder_behaves() {
        let dir = temp();
        let b = LocalFolder::new(&dir);
        exercise(&b);
        assert!(matches!(
            b.get("../etc/passwd"),
            Err(BackendError::Other(_))
        ));
        assert!(
            b.list("devices/aa")
                .unwrap()
                .iter()
                .all(|e| !e.name.starts_with('.')),
            "no temp files left"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn writing_a_new_file_never_replaces_one_already_there() {
        let dir = temp();
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("000001.seg");
        let tmp = dir.join(".000001.seg.tmp");
        std::fs::write(&tmp, b"new").unwrap();
        // Without hard links, the fallback creates the file itself.
        place_new(&tmp, &target, b"new", false).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        std::fs::write(&tmp, b"other").unwrap();
        for hard_links in [true, false] {
            let err = place_new(&tmp, &target, b"other", hard_links).unwrap_err();
            assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists);
            assert_eq!(std::fs::read(&target).unwrap(), b"new", "left alone");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn icloud_placeholders_are_listed_and_reported_as_still_downloading() {
        assert_eq!(
            icloud_placeholder_name(".000003.seg.icloud"),
            Some("000003.seg")
        );
        assert_eq!(icloud_placeholder_name(".icloud"), None);
        assert_eq!(icloud_placeholder_name("000003.seg"), None);

        let dir = temp();
        let b = LocalFolder::new(&dir);
        b.put_new("devices/aa/000001.seg", b"one").unwrap();
        let folder = dir.join("devices/aa");
        std::fs::write(folder.join(".000002.seg.icloud"), b"plist").unwrap();
        std::fs::write(folder.join(".vault.json.tmp-1"), b"junk").unwrap();
        let names: Vec<String> = b
            .list("devices/aa")
            .unwrap()
            .into_iter()
            .map(|e| e.name)
            .collect();
        assert_eq!(names, ["000001.seg", "000002.seg"]);
        assert!(matches!(
            b.get("devices/aa/000002.seg"),
            Err(BackendError::NotDownloaded(_))
        ));
        assert!(matches!(
            b.put_new("devices/aa/000002.seg", b"two"),
            Err(BackendError::AlreadyExists(_))
        ));
        // Once it downloads, it is listed once and reads normally.
        std::fs::write(folder.join("000002.seg"), b"two").unwrap();
        let listed = b.list("devices/aa").unwrap();
        assert_eq!(listed.len(), 2, "{listed:?}");
        assert_eq!(listed[1].size, 3);
        assert_eq!(b.get("devices/aa/000002.seg").unwrap(), b"two");
        b.delete("devices/aa/000002.seg").unwrap();
        assert_eq!(
            b.list("devices/aa").unwrap().len(),
            1,
            "placeholder gone too"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn memory_backend_behaves() {
        exercise(&MemoryBackend::default());
    }
}
