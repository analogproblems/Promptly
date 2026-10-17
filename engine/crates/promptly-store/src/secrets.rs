//! Where small secrets live: saved passwords, private keys and the vault key.
//!
//! They are files in the data folder, encrypted with a device key that the app
//! keeps in the platform's own secure storage (Keychain on Apple, Keystore on
//! Android, Credential Manager on Windows, the Secret Service on Linux) and
//! hands to the engine at startup. The engine never links a platform keychain
//! library directly.

pub trait SecretStore: Send + Sync {
    /// Store `value` under `key`, replacing any previous value.
    fn put(&self, key: &str, value: &[u8]) -> Result<(), SecretError>;
    /// Read the value under `key`, or `None` if there is none.
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, SecretError>;
    /// Remove the value under `key`. Removing a missing key is not an error.
    fn delete(&self, key: &str) -> Result<(), SecretError>;
    /// Every key with a value, in no particular order.
    fn list(&self) -> Result<Vec<String>, SecretError>;
}

#[derive(Debug, thiserror::Error)]
pub enum SecretError {
    #[error("the secret store is locked; unlock the device first")]
    Locked,
    #[error("the platform refused: {0}")]
    Platform(String),
}

/// An in-memory store for tests and for the CLI, which has no keychain.
#[derive(Default)]
pub struct MemorySecretStore {
    inner: std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>,
}

impl SecretStore for MemorySecretStore {
    fn put(&self, key: &str, value: &[u8]) -> Result<(), SecretError> {
        self.inner
            .lock()
            .unwrap()
            .insert(key.to_string(), value.to_vec());
        Ok(())
    }
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, SecretError> {
        Ok(self.inner.lock().unwrap().get(key).cloned())
    }
    fn delete(&self, key: &str) -> Result<(), SecretError> {
        self.inner.lock().unwrap().remove(key);
        Ok(())
    }
    fn list(&self) -> Result<Vec<String>, SecretError> {
        Ok(self.inner.lock().unwrap().keys().cloned().collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_store_round_trips() {
        let s = MemorySecretStore::default();
        assert_eq!(s.get("k").unwrap(), None);
        s.put("k", b"v").unwrap();
        assert_eq!(s.get("k").unwrap().as_deref(), Some(&b"v"[..]));
        s.delete("k").unwrap();
        s.delete("k").unwrap();
        assert_eq!(s.get("k").unwrap(), None);
    }
}

/// Secrets as files, one per id, readable only by the owner.
///
/// With a device key each file is sealed with it, bound to its id, so a copy
/// of the folder is useless without the platform's secure storage. Without
/// one (a Linux desktop with no Secret Service) the files are plain, as
/// OpenSSH keeps `~/.ssh/id_*`, and only file permissions protect them.
pub struct FileSecretStore {
    dir: std::path::PathBuf,
    key: Option<Dek>,
}

impl FileSecretStore {
    /// Plain files, protected only by file permissions.
    pub fn new(dir: std::path::PathBuf) -> Self {
        Self { dir, key: None }
    }

    /// Files encrypted with `key`, the device key.
    pub fn encrypted(dir: std::path::PathBuf, key: Dek) -> Self {
        Self {
            dir,
            key: Some(key),
        }
    }

    /// Whether secrets are encrypted on disk.
    pub fn is_encrypted(&self) -> bool {
        self.key.is_some()
    }

    fn aad(key: &str) -> Vec<u8> {
        format!("promptly-secret/{key}").into_bytes()
    }

    fn path_for(&self, key: &str) -> Result<std::path::PathBuf, SecretError> {
        let ok = !key.is_empty()
            && key.len() <= 128
            && key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
            && !key.starts_with('.');
        if !ok {
            return Err(SecretError::Platform(format!("invalid secret id {key:?}")));
        }
        Ok(self.dir.join(key))
    }

    fn ensure_dir(&self) -> Result<(), SecretError> {
        std::fs::create_dir_all(&self.dir).map_err(|e| SecretError::Platform(e.to_string()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&self.dir, std::fs::Permissions::from_mode(0o700));
        }
        Ok(())
    }
}

impl SecretStore for FileSecretStore {
    fn put(&self, key: &str, value: &[u8]) -> Result<(), SecretError> {
        self.ensure_dir()?;
        let path = self.path_for(key)?;
        let sealed;
        let value = match &self.key {
            Some(k) => {
                sealed = seal(k, &Self::aad(key), value)
                    .map_err(|e| SecretError::Platform(e.to_string()))?;
                &sealed[..]
            }
            None => value,
        };
        let tmp = path.with_extension("tmp");
        {
            let mut opts = std::fs::OpenOptions::new();
            opts.write(true).create(true).truncate(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                opts.mode(0o600);
            }
            let mut f = opts
                .open(&tmp)
                .map_err(|e| SecretError::Platform(e.to_string()))?;
            use std::io::Write;
            f.write_all(value)
                .and_then(|_| f.sync_all())
                .map_err(|e| SecretError::Platform(e.to_string()))?;
        }
        std::fs::rename(&tmp, &path).map_err(|e| SecretError::Platform(e.to_string()))
    }

    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, SecretError> {
        let path = self.path_for(key)?;
        match std::fs::read(&path) {
            Ok(bytes) => match &self.key {
                // Written while the secure storage was unavailable, as when a
                // keyring starts late; it is sealed the next time it is saved.
                Some(_) if !bytes.starts_with(MAGIC) => Ok(Some(bytes)),
                Some(k) => open(k, &Self::aad(key), &bytes).map(Some).map_err(|_| {
                    SecretError::Platform(format!(
                        "saved secret {key:?} could not be decrypted with this device's key"
                    ))
                }),
                None if bytes.starts_with(MAGIC) => Err(SecretError::Platform(format!(
                    "saved secret {key:?} is encrypted, but this device's secure storage is unavailable"
                ))),
                None => Ok(Some(bytes)),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(SecretError::Platform(e.to_string())),
        }
    }

    fn delete(&self, key: &str) -> Result<(), SecretError> {
        let path = self.path_for(key)?;
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(SecretError::Platform(e.to_string())),
        }
    }
    fn list(&self) -> Result<Vec<String>, SecretError> {
        let read = match std::fs::read_dir(&self.dir) {
            Ok(r) => r,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(SecretError::Platform(e.to_string())),
        };
        let mut out = Vec::new();
        for entry in read.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name.ends_with(".tmp") {
                continue;
            }
            if self.path_for(&name).is_ok() {
                out.push(name);
            }
        }
        Ok(out)
    }
}

use promptly_vault::crypto::{open, seal, Dek, MAGIC};

#[cfg(test)]
mod file_tests {
    use super::*;

    #[test]
    fn file_store_round_trips_with_owner_only_permissions() {
        let dir = std::env::temp_dir().join(format!("promptly-secrets-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let s = FileSecretStore::new(dir.clone());
        assert_eq!(s.get("k1").unwrap(), None);
        s.put("k1", b"hello").unwrap();
        assert_eq!(s.get("k1").unwrap().as_deref(), Some(&b"hello"[..]));
        s.put("k1", b"replaced").unwrap();
        assert_eq!(s.get("k1").unwrap().as_deref(), Some(&b"replaced"[..]));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.join("k1"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600);
            let dmode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
            assert_eq!(dmode, 0o700);
        }
        s.delete("k1").unwrap();
        s.delete("k1").unwrap();
        assert_eq!(s.get("k1").unwrap(), None);
        assert!(s.get("../etc/passwd").is_err(), "ids are never paths");
        assert!(s.put(".hidden", b"x").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn encrypted_store_seals_each_file_to_its_id() {
        let dir = std::env::temp_dir().join(format!("promptly-secrets-enc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let key = Dek::generate();
        let s = FileSecretStore::encrypted(dir.clone(), key.clone());
        assert!(s.is_encrypted());
        s.put("pw", b"hunter2").unwrap();
        let raw = std::fs::read(dir.join("pw")).unwrap();
        assert!(raw.starts_with(MAGIC));
        assert!(
            !raw.windows(7).any(|w| w == b"hunter2"),
            "no plaintext on disk"
        );
        assert_eq!(s.get("pw").unwrap().as_deref(), Some(&b"hunter2"[..]));
        assert_eq!(s.list().unwrap(), vec!["pw".to_string()]);

        // A file moved to another id does not open.
        std::fs::copy(dir.join("pw"), dir.join("other")).unwrap();
        assert!(s.get("other").is_err());
        // Nor does it open with another key, or with no key at all.
        assert!(FileSecretStore::encrypted(dir.clone(), Dek::generate())
            .get("pw")
            .is_err());
        assert!(FileSecretStore::new(dir.clone()).get("pw").is_err());

        // A plain file, saved while the key was unavailable, still reads.
        FileSecretStore::new(dir.clone())
            .put("plain", b"x")
            .unwrap();
        assert_eq!(s.get("plain").unwrap().as_deref(), Some(&b"x"[..]));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
