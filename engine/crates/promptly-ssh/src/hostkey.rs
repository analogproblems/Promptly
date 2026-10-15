//! Host keys: what to show the person, and where trusted keys are kept.

use std::fmt;
use std::io;
use std::path::PathBuf;

use russh::keys::{self, HashAlg, PublicKey};

/// Everything the host key prompt shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKeyInfo {
    pub host: String,
    pub port: u16,
    /// Human name such as `ED25519` or `RSA`.
    pub algorithm: String,
    pub bits: u32,
    /// `SHA256:` followed by the base64 digest, as OpenSSH prints it.
    pub fingerprint: String,
    /// The key in OpenSSH one-line form, for known_hosts and for sharing.
    pub public_key: String,
    /// The OpenSSH "randomart" picture of the fingerprint.
    pub randomart: String,
}

impl HostKeyInfo {
    pub fn from_key(host: &str, port: u16, key: &PublicKey) -> Self {
        let (algorithm, bits) = describe(key);
        let fingerprint = key.fingerprint(HashAlg::Sha256);
        let randomart = Randomart(fingerprint, format!("[{algorithm} {bits}]")).to_string();
        Self {
            host: host.to_string(),
            port,
            algorithm,
            bits,
            fingerprint: fingerprint.to_string(),
            public_key: key.to_openssh().unwrap_or_default(),
            randomart,
        }
    }
}

fn describe(key: &PublicKey) -> (String, u32) {
    use keys::ssh_key::public::KeyData;
    match key.key_data() {
        KeyData::Ed25519(_) => ("ED25519".into(), 256),
        KeyData::Ecdsa(k) => {
            let bits = match k.curve() {
                keys::EcdsaCurve::NistP256 => 256,
                keys::EcdsaCurve::NistP384 => 384,
                keys::EcdsaCurve::NistP521 => 521,
            };
            ("ECDSA".into(), bits)
        }
        KeyData::Rsa(k) => {
            let bits = k
                .n()
                .as_positive_bytes()
                .map(|b| b.len() as u32 * 8)
                .unwrap_or(0);
            ("RSA".into(), bits)
        }
        other => (other.algorithm().as_str().to_uppercase(), 0),
    }
}

struct Randomart(keys::ssh_key::Fingerprint, String);

impl fmt::Display for Randomart {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt_randomart(&self.1, f)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKeyStatus {
    /// Seen before with this exact key: connect without asking.
    Known,
    /// Never seen: ask once, then remember.
    Unknown,
    /// Seen before with a different key: warn loudly and ask.
    Changed,
}

/// Where trusted host keys live. The vault's `known_hosts` collection
/// implements this in milestone 2; until then, files.
pub trait KnownHosts: Send + Sync {
    fn check(&self, host: &str, port: u16, key: &PublicKey) -> HostKeyStatus;
    fn remember(&self, host: &str, port: u16, key: &PublicKey) -> io::Result<()>;
}

/// OpenSSH-format files. Reads the user's own `~/.ssh/known_hosts` too, so
/// servers they already trust are trusted here, but only ever writes to
/// Promptly's own file.
pub struct FileKnownHosts {
    read_paths: Vec<PathBuf>,
    write_path: PathBuf,
}

impl FileKnownHosts {
    pub fn new(read_paths: Vec<PathBuf>, write_path: PathBuf) -> Self {
        let mut read_paths = read_paths;
        if !read_paths.contains(&write_path) {
            read_paths.push(write_path.clone());
        }
        Self {
            read_paths,
            write_path,
        }
    }

    /// `~/.ssh/known_hosts` for reading plus `<data_dir>/known_hosts` for both.
    pub fn default_paths(data_dir: &std::path::Path) -> Self {
        let mut read = Vec::new();
        if let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) {
            read.push(PathBuf::from(home).join(".ssh").join("known_hosts"));
        }
        Self::new(read, data_dir.join("known_hosts"))
    }
}

impl KnownHosts for FileKnownHosts {
    fn check(&self, host: &str, port: u16, key: &PublicKey) -> HostKeyStatus {
        for path in &self.read_paths {
            if !path.exists() {
                continue;
            }
            match keys::check_known_hosts_path(host, port, key, path) {
                Ok(true) => return HostKeyStatus::Known,
                Ok(false) => {}
                Err(keys::Error::KeyChanged { .. }) => return HostKeyStatus::Changed,
                Err(e) => tracing::warn!("could not read {}: {e}", path.display()),
            }
        }
        HostKeyStatus::Unknown
    }

    fn remember(&self, host: &str, port: u16, key: &PublicKey) -> io::Result<()> {
        if let Some(parent) = self.write_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // OpenSSH format: `host keytype base64`, with `[host]:port` for other ports.
        let entry = if port == 22 {
            host.to_string()
        } else {
            format!("[{host}]:{port}")
        };
        // Without a comment: the checker compares the whole key, comment included,
        // and keys from the wire never carry one.
        let mut bare = key.clone();
        bare.set_comment("");
        let key_line = bare
            .to_openssh()
            .map_err(|e| io::Error::other(e.to_string()))?;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.write_path)?;
        use std::io::Write;
        writeln!(file, "{entry} {key_line}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> PublicKey {
        PublicKey::from_openssh(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGjYnK4hJ8Sg4bD4sJ+VgM1a2y2hRc8KpsaBvZJ8x6kG",
        )
        .unwrap()
    }

    #[test]
    fn info_has_fingerprint_and_art() {
        let info = HostKeyInfo::from_key("example.test", 22, &key());
        assert_eq!(info.algorithm, "ED25519");
        assert_eq!(info.bits, 256);
        assert!(info.fingerprint.starts_with("SHA256:"));
        assert!(info.randomart.starts_with("+--[ED25519 256]"));
        assert_eq!(info.randomart.lines().count(), 11);
        assert!(info.public_key.starts_with("ssh-ed25519 "));
    }

    #[test]
    fn file_store_learns_and_detects_changes() {
        let dir = std::env::temp_dir().join(format!("promptly-kh-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let store = FileKnownHosts::new(vec![], dir.join("known_hosts"));
        let k = key();
        assert_eq!(store.check("example.test", 22, &k), HostKeyStatus::Unknown);
        store.remember("example.test", 22, &k).unwrap();
        assert_eq!(store.check("example.test", 22, &k), HostKeyStatus::Known);
        assert_eq!(
            store.check("example.test", 2222, &k),
            HostKeyStatus::Unknown,
            "port is part of the identity"
        );

        let other = PublicKey::from_openssh(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBzqY1Sy2Yv3n4Ck9Q3h8s9Dq7mEcKq2FjG5lHhq6pQZ",
        )
        .unwrap();
        assert_eq!(
            store.check("example.test", 22, &other),
            HostKeyStatus::Changed
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
