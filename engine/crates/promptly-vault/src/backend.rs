//! Storage backends: the four calls of VAULT.md section 10, and the local
//! folder, which also serves iCloud Drive and anything a sync client mirrors.

use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
pub enum BackendError {
    #[error("{0} already exists")]
    AlreadyExists(String),
    #[error("{0} was not found")]
    NotFound(String),
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
pub trait Backend: Send + Sync {
    fn list(&self, dir: &str) -> Result<Vec<Entry>, BackendError>;
    fn get(&self, path: &str) -> Result<Vec<u8>, BackendError>;
    /// Write a file that must not exist yet, creating parent folders.
    fn put_new(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError>;
    fn delete(&self, path: &str) -> Result<(), BackendError>;
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
            if name.starts_with('.') {
                continue; // temp files and the sync client's own bookkeeping
            }
            out.push(Entry {
                name,
                size: meta.len(),
                is_dir: meta.is_dir(),
            });
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(out)
    }

    fn get(&self, path: &str) -> Result<Vec<u8>, BackendError> {
        let p = self.resolve(path)?;
        std::fs::read(&p).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => BackendError::NotFound(path.to_string()),
            _ => BackendError::Io(p.display().to_string(), e),
        })
    }

    fn put_new(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError> {
        let p = self.resolve(path)?;
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| BackendError::Io(parent.display().to_string(), e))?;
        }
        if p.exists() {
            return Err(BackendError::AlreadyExists(path.to_string()));
        }
        // Write beside the target and rename, so a reader never sees half a file.
        let tmp = p.with_file_name(format!(
            ".{}.tmp-{}",
            p.file_name()
                .map(|n| n.to_string_lossy())
                .unwrap_or_default(),
            std::process::id()
        ));
        std::fs::write(&tmp, bytes).map_err(|e| BackendError::Io(tmp.display().to_string(), e))?;
        // `hard_link` + remove is the portable "create new" step: it fails if
        // the target appeared in the meantime, and never overwrites.
        let result = std::fs::hard_link(&tmp, &p).or_else(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                Err(e)
            } else {
                // Filesystems without hard links (some network shares): rename.
                std::fs::rename(&tmp, &p)
            }
        });
        let _ = std::fs::remove_file(&tmp);
        result.map_err(|e| match e.kind() {
            std::io::ErrorKind::AlreadyExists => BackendError::AlreadyExists(path.to_string()),
            _ => BackendError::Io(p.display().to_string(), e),
        })
    }

    fn delete(&self, path: &str) -> Result<(), BackendError> {
        let p = self.resolve(path)?;
        match std::fs::remove_file(&p) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) if p.is_dir() => std::fs::remove_dir_all(&p)
                .map_err(|e| BackendError::Io(p.display().to_string(), e)),
            Err(e) => Err(BackendError::Io(p.display().to_string(), e)),
        }
    }
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
    fn memory_backend_behaves() {
        exercise(&MemoryBackend::default());
    }
}
