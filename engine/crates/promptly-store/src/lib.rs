//! Local state for Promptly.
//!
//! The vault (see `promptly-vault`) is the source of truth; this crate keeps
//! the fast local copy the UI reads from (SQLite, encrypted at rest) and
//! defines how secrets reach the platform keychain. Milestone 0 only fixes
//! the secret-store contract so the app and the engine agree on it.

/// Where small secrets live on each platform: Keychain on Apple, Keystore on
/// Android, Credential Manager on Windows, libsecret on Linux.
///
/// Implementations are provided by the app side through the bridge; the engine
/// never links a platform keychain library directly.
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
