//! Where small secrets live on each platform: Keychain on Apple, Keystore on
//! Android, Credential Manager on Windows, libsecret on Linux.
//!
//! Implementations are provided by the app side through the bridge; the engine
//! never links a platform keychain library directly.

pub trait SecretStore: Send + Sync {
    /// Store `value` under `key`, replacing any previous value.
    fn put(&self, key: &str, value: &[u8]) -> Result<(), SecretError>;
    /// Read the value under `key`, or `None` if there is none.
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>, SecretError>;
    /// Remove the value under `key`. Removing a missing key is not an error.
    fn delete(&self, key: &str) -> Result<(), SecretError>;
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
/// This is how OpenSSH itself keeps `~/.ssh/id_*`: file permissions, plus
/// the key's own passphrase if it has one. It is the default on Linux
/// desktops, where a keychain service is not always present. The vault
/// passphrase (milestone 2) encrypts these at rest, and platforms with a
/// system keychain use it instead through the app side of the bridge.
pub struct FileSecretStore {
    dir: std::path::PathBuf,
}

impl FileSecretStore {
    pub fn new(dir: std::path::PathBuf) -> Self {
        Self { dir }
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
            Ok(bytes) => Ok(Some(bytes)),
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
}

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
}
