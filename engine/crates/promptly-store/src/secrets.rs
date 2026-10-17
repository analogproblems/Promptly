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
/// When the secure storage has a key but refuses it, the store is locked:
/// nothing is read or written, so no secret is ever saved in the clear.
pub struct FileSecretStore {
    dir: std::path::PathBuf,
    mode: Mode,
}

enum Mode {
    Plain,
    Encrypted(Dek),
    Locked,
}

impl FileSecretStore {
    /// Plain files, protected only by file permissions. Once any secret here
    /// has been encrypted, it refuses to write, so a lost key never turns
    /// into plaintext.
    pub fn new(dir: std::path::PathBuf) -> Self {
        Self {
            dir,
            mode: Mode::Plain,
        }
    }

    /// Files encrypted with `key`, the device key. Plain files left from
    /// before the key was available are sealed now.
    pub fn encrypted(dir: std::path::PathBuf, key: Dek) -> Self {
        let s = Self {
            dir,
            mode: Mode::Encrypted(key),
        };
        s.seal_plain_files();
        s
    }

    /// Refuses every read and write, for a device whose secure storage
    /// could not be opened.
    pub fn locked(dir: std::path::PathBuf) -> Self {
        Self {
            dir,
            mode: Mode::Locked,
        }
    }

    /// Whether every secret is encrypted on disk.
    pub fn is_encrypted(&self) -> bool {
        matches!(self.mode, Mode::Encrypted(_)) && self.plain_files().is_empty()
    }

    pub fn is_locked(&self) -> bool {
        matches!(self.mode, Mode::Locked)
    }

    /// Ids whose file is not sealed, and whether any file is.
    fn scan(&self) -> (Vec<String>, bool) {
        let mut plain = Vec::new();
        let mut any_sealed = false;
        for id in self.list().unwrap_or_default() {
            match std::fs::read(self.dir.join(&id)) {
                Ok(bytes) if bytes.starts_with(MAGIC) => any_sealed = true,
                Ok(_) => plain.push(id),
                Err(_) => {}
            }
        }
        (plain, any_sealed)
    }

    fn plain_files(&self) -> Vec<String> {
        self.scan().0
    }

    /// Rewrite each plain file sealed. Each rewrite replaces its file in
    /// one rename, so a crash leaves it either plain or sealed, never torn;
    /// a file that fails stays plain and is tried again next start, and
    /// `is_encrypted` stays false until none is left.
    fn seal_plain_files(&self) {
        for id in self.plain_files() {
            if let Ok(Some(value)) = self.get(&id) {
                let _ = self.put(&id, &value);
            }
        }
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
        let path = self.path_for(key)?;
        let sealed;
        let value = match &self.mode {
            Mode::Encrypted(k) => {
                sealed = seal(k, &Self::aad(key), value)
                    .map_err(|e| SecretError::Platform(e.to_string()))?;
                &sealed[..]
            }
            Mode::Plain if self.scan().1 => return Err(SecretError::Locked),
            Mode::Plain => value,
            Mode::Locked => return Err(SecretError::Locked),
        };
        self.ensure_dir()?;
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
        if let Mode::Locked = self.mode {
            return Err(SecretError::Locked);
        }
        match std::fs::read(&path) {
            Ok(bytes) => match &self.mode {
                Mode::Locked => Err(SecretError::Locked),
                // Saved before the key was available; sealed at the next start.
                Mode::Encrypted(_) if !bytes.starts_with(MAGIC) => Ok(Some(bytes)),
                Mode::Encrypted(k) => open(k, &Self::aad(key), &bytes).map(Some).map_err(|_| {
                    SecretError::Platform(format!(
                        "saved secret {key:?} could not be decrypted with this device's key"
                    ))
                }),
                Mode::Plain if bytes.starts_with(MAGIC) => Err(SecretError::Locked),
                Mode::Plain => Ok(Some(bytes)),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(SecretError::Platform(e.to_string())),
        }
    }

    fn delete(&self, key: &str) -> Result<(), SecretError> {
        let path = self.path_for(key)?;
        if let Mode::Locked = self.mode {
            return Err(SecretError::Locked);
        }
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

        // Once anything is sealed, the plain store will not write.
        assert!(matches!(
            FileSecretStore::new(dir.clone()).put("pw", b"leak"),
            Err(SecretError::Locked)
        ));
        assert_eq!(s.get("pw").unwrap().as_deref(), Some(&b"hunter2"[..]));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn plain_secrets_are_sealed_once_a_key_is_available() {
        let dir = std::env::temp_dir().join(format!("promptly-secrets-up-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let plain = FileSecretStore::new(dir.clone());
        plain.put("pw", b"hunter2").unwrap();
        plain.put("vault-dek", &[7u8; 32]).unwrap();
        assert!(!plain.is_encrypted());

        let key = Dek::generate();
        let s = FileSecretStore::encrypted(dir.clone(), key.clone());
        assert!(s.is_encrypted(), "every file sealed at open");
        for id in ["pw", "vault-dek"] {
            assert!(std::fs::read(dir.join(id)).unwrap().starts_with(MAGIC));
        }
        // And after a restart they read back.
        let again = FileSecretStore::encrypted(dir.clone(), key);
        assert_eq!(again.get("pw").unwrap().as_deref(), Some(&b"hunter2"[..]));
        assert_eq!(
            again.get("vault-dek").unwrap().as_deref(),
            Some(&[7u8; 32][..])
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_locked_store_reads_and_writes_nothing() {
        let dir =
            std::env::temp_dir().join(format!("promptly-secrets-lock-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        FileSecretStore::encrypted(dir.clone(), Dek::generate())
            .put("pw", b"hunter2")
            .unwrap();
        let before = std::fs::read(dir.join("pw")).unwrap();
        let s = FileSecretStore::locked(dir.clone());
        assert!(s.is_locked() && !s.is_encrypted());
        assert!(matches!(s.get("pw"), Err(SecretError::Locked)));
        assert!(matches!(s.put("pw", b"leak"), Err(SecretError::Locked)));
        assert!(matches!(s.put("new", b"leak"), Err(SecretError::Locked)));
        assert!(matches!(s.delete("pw"), Err(SecretError::Locked)));
        assert_eq!(
            std::fs::read(dir.join("pw")).unwrap(),
            before,
            "ciphertext untouched"
        );
        assert!(!dir.join("new").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
