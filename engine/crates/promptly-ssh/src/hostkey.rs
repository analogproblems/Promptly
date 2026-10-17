//! Host keys: what to show the person, and where trusted keys are kept.

use std::fmt;
use std::io;
use std::path::PathBuf;

use russh::keys::{self, Algorithm, HashAlg, PublicKey};

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
    /// Marked `@revoked` in a known_hosts file: never trusted, never asked.
    Revoked,
}

/// Where trusted host keys live. The app's implementation also keeps them
/// in the vault, so a key trusted on one device is trusted on all.
pub trait KnownHosts: Send + Sync {
    fn check(&self, host: &str, port: u16, key: &PublicKey) -> HostKeyStatus;
    /// Trust `key` for this host, replacing any key trusted before.
    fn remember(&self, host: &str, port: u16, key: &PublicKey) -> io::Result<()>;
    /// The kinds of key already trusted for this host, so the handshake can
    /// ask the server for one of those first, as OpenSSH does. A server that
    /// has the trusted key then never shows a different one by accident.
    /// No default: a store that wraps another must pass this on, or a
    /// server with several keys shows the wrong one and looks changed.
    fn known_algorithms(&self, host: &str, port: u16) -> Vec<Algorithm>;
}

/// The kind of key, ignoring the signature hash an RSA key is used with.
fn family(algorithm: &Algorithm) -> String {
    match algorithm {
        Algorithm::Rsa { .. } => "rsa".into(),
        other => other.as_str().to_string(),
    }
}

/// Whether a known_hosts host field (`a,b,[c]:2222`, hashed `|1|salt|hash`
/// entries, `*` and `?` wildcards, `!` negations) covers `entry`, which is
/// `host` or `[host]:port`.
fn hosts_match(field: &str, entry: &str) -> bool {
    use hmac::{Hmac, KeyInit, Mac};
    let mut matched = false;
    for pattern in field.split(',') {
        let (negated, pattern) = match pattern.strip_prefix('!') {
            Some(p) => (true, p),
            None => (false, pattern),
        };
        let hit = if let Some(hashed) = pattern.strip_prefix("|1|") {
            let mut parts = hashed.splitn(2, '|');
            let decode = |s: Option<&str>| {
                use base64::Engine;
                s.and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok())
            };
            match (decode(parts.next()), decode(parts.next())) {
                (Some(salt), Some(hash)) => Hmac::<sha1::Sha1>::new_from_slice(&salt)
                    .map(|m| m.chain_update(entry).verify_slice(&hash).is_ok())
                    .unwrap_or(false),
                _ => false,
            }
        } else {
            wildcard(&pattern.to_ascii_lowercase(), &entry.to_ascii_lowercase())
        };
        if hit && negated {
            return false;
        }
        matched |= hit;
    }
    matched
}

/// OpenSSH's `*` and `?` patterns.
fn wildcard(pattern: &str, text: &str) -> bool {
    let (p, t): (Vec<char>, Vec<char>) = (pattern.chars().collect(), text.chars().collect());
    let (mut pi, mut ti, mut star, mut mark) = (0, 0, None, 0);
    while ti < t.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == t[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ti;
            pi += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|&c| c == '*')
}

/// The handshake's host key preferences with the kinds in `known` first.
pub fn preferred_host_key_algorithms(known: &[Algorithm]) -> Vec<Algorithm> {
    let known: Vec<String> = known.iter().map(family).collect();
    let all = russh::Preferred::DEFAULT.key.to_vec();
    let (mut first, rest): (Vec<_>, Vec<_>) =
        all.into_iter().partition(|a| known.contains(&family(a)));
    first.extend(rest);
    first
}

/// OpenSSH-format files. Reads the user's own `~/.ssh/known_hosts` too, so
/// servers they already trust are trusted here, but only ever writes to
/// Promptly's own file.
///
/// Promptly's file has the last word: once it holds a key for a host, that
/// is the key, whatever `~/.ssh/known_hosts` says, so accepting a changed
/// key sticks even though the old one is still in the user's own file.
pub struct FileKnownHosts {
    /// The user's own files, read only.
    user_paths: Vec<PathBuf>,
    write_path: PathBuf,
}

impl FileKnownHosts {
    pub fn new(read_paths: Vec<PathBuf>, write_path: PathBuf) -> Self {
        let user_paths = read_paths
            .into_iter()
            .filter(|p| *p != write_path)
            .collect();
        Self {
            user_paths,
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

    /// Every key on record for the host in one file. `@revoked` keys come
    /// back too, flagged, so they are refused rather than ignored; lines
    /// this reader does not understand (`@cert-authority`, damaged ones)
    /// are skipped without hiding the rest of the file.
    fn recorded(path: &std::path::Path, host: &str, port: u16) -> Vec<(PublicKey, bool)> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Vec::new(),
            Err(e) => {
                tracing::warn!("could not read {}: {e}", path.display());
                return Vec::new();
            }
        };
        let entry = Self::entry(host, port);
        let mut out = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut fields = line.split_whitespace();
            let mut first = fields.next().unwrap_or("");
            let mut revoked = false;
            if first.starts_with('@') {
                if first != "@revoked" {
                    continue;
                }
                revoked = true;
                first = fields.next().unwrap_or("");
            }
            if !hosts_match(first, &entry) {
                continue;
            }
            let (Some(kind), Some(data)) = (fields.next(), fields.next()) else {
                continue;
            };
            if let Ok(key) = PublicKey::from_openssh(&format!("{kind} {data}")) {
                out.push((key, revoked));
            }
        }
        out
    }

    /// The keys that decide for this host: Promptly's own when it has any,
    /// otherwise the user's.
    fn deciding(&self, host: &str, port: u16) -> Vec<(PublicKey, bool)> {
        let user: Vec<_> = self
            .user_paths
            .iter()
            .flat_map(|p| Self::recorded(p, host, port))
            .collect();
        let own = Self::recorded(&self.write_path, host, port);
        if own.is_empty() {
            return user;
        }
        // A key the user revoked in their own file stays revoked.
        own.into_iter()
            .chain(user.into_iter().filter(|(_, revoked)| *revoked))
            .collect()
    }

    fn entry(host: &str, port: u16) -> String {
        if port == 22 {
            host.to_string()
        } else {
            format!("[{host}]:{port}")
        }
    }
}

/// Held while a known_hosts file is rewritten.
static WRITING: std::sync::Mutex<()> = std::sync::Mutex::new(());
static TMP_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

impl KnownHosts for FileKnownHosts {
    fn check(&self, host: &str, port: u16, key: &PublicKey) -> HostKeyStatus {
        let recorded = self.deciding(host, port);
        let same = |k: &PublicKey| k.key_data() == key.key_data();
        if recorded.iter().any(|(k, revoked)| *revoked && same(k)) {
            HostKeyStatus::Revoked
        } else if recorded.iter().all(|(_, revoked)| *revoked) {
            HostKeyStatus::Unknown
        } else if recorded.iter().any(|(k, _)| same(k)) {
            HostKeyStatus::Known
        } else {
            // A key of another kind counts as changed too: a server that
            // has the trusted key is asked for it first, so offering a
            // different one is exactly what an impostor would do.
            HostKeyStatus::Changed
        }
    }

    fn remember(&self, host: &str, port: u16, key: &PublicKey) -> io::Result<()> {
        // Two handshakes, or a handshake and a sync, can remember keys at
        // once. Reading, editing and replacing the file is one step, or one
        // of them loses the other's key.
        let _writing = WRITING.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(parent) = self.write_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let entry = Self::entry(host, port);
        // Without a comment: keys from the wire never carry one.
        let mut bare = key.clone();
        bare.set_comment("");
        let key_line = bare
            .to_openssh()
            .map_err(|e| io::Error::other(e.to_string()))?;
        // Drop whatever this file trusted for the host before, so the new
        // key replaces it rather than sitting beside it.
        let existing = match std::fs::read_to_string(&self.write_path) {
            Ok(s) => s,
            Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(e),
        };
        let mut out = String::new();
        for line in existing.lines() {
            let first = line.split_whitespace().next().unwrap_or("");
            if first.split(',').any(|h| h == entry) {
                continue;
            }
            out.push_str(line);
            out.push('\n');
        }
        out.push_str(&format!("{entry} {key_line}\n"));
        let tmp = self.write_path.with_extension(format!(
            "tmp-{}-{}",
            std::process::id(),
            TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::write(&tmp, out)?;
        std::fs::rename(&tmp, &self.write_path).inspect_err(|_| {
            let _ = std::fs::remove_file(&tmp);
        })
    }

    fn known_algorithms(&self, host: &str, port: u16) -> Vec<Algorithm> {
        self.deciding(host, port)
            .iter()
            .filter(|(_, revoked)| !revoked)
            .map(|(k, _)| k.algorithm())
            .collect()
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

    fn ecdsa_key() -> PublicKey {
        let g = crate::keys::generate(crate::keys::KeyKind::EcdsaP256, "").unwrap();
        PublicKey::from_openssh(&g.public_openssh).unwrap()
    }

    #[test]
    fn trusting_a_changed_key_sticks_over_the_users_own_file() {
        let dir = std::env::temp_dir().join(format!("promptly-kh2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let user = dir.join("user_known_hosts");
        let old = key();
        std::fs::write(
            &user,
            format!("example.test {}\n", old.to_openssh().unwrap()),
        )
        .unwrap();
        let store = FileKnownHosts::new(vec![user.clone()], dir.join("known_hosts"));
        assert_eq!(store.check("example.test", 22, &old), HostKeyStatus::Known);

        let new = PublicKey::from_openssh(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBzqY1Sy2Yv3n4Ck9Q3h8s9Dq7mEcKq2FjG5lHhq6pQZ",
        )
        .unwrap();
        assert_eq!(
            store.check("example.test", 22, &new),
            HostKeyStatus::Changed
        );
        store.remember("example.test", 22, &new).unwrap();
        assert_eq!(store.check("example.test", 22, &new), HostKeyStatus::Known);
        assert_eq!(
            store.check("example.test", 22, &old),
            HostKeyStatus::Changed,
            "the old key is no longer trusted"
        );
        // Trusting again replaces rather than piling up lines.
        store.remember("example.test", 22, &old).unwrap();
        store.remember("example.test", 22, &new).unwrap();
        store.remember("other.test", 22, &old).unwrap();
        let own = std::fs::read_to_string(dir.join("known_hosts")).unwrap();
        assert_eq!(
            own.lines()
                .filter(|l| l.starts_with("example.test "))
                .count(),
            1
        );
        assert_eq!(own.lines().count(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reads_hashed_wildcard_negated_and_revoked_lines() {
        assert!(hosts_match("web,example.test", "example.test"));
        assert!(hosts_match("*.test", "example.test"));
        assert!(hosts_match("[example.test]:2222", "[example.test]:2222"));
        assert!(!hosts_match("*.test,!example.test", "example.test"));
        assert!(!hosts_match("example.test", "[example.test]:2222"));
        // `ssh-keygen -H` of "example.test" with a fixed salt.
        use base64::Engine;
        use hmac::{Hmac, KeyInit, Mac};
        let salt = [7u8; 20];
        let hash = Hmac::<sha1::Sha1>::new_from_slice(&salt)
            .unwrap()
            .chain_update("example.test")
            .finalize()
            .into_bytes();
        let b64 = base64::engine::general_purpose::STANDARD;
        let hashed = format!("|1|{}|{}", b64.encode(salt), b64.encode(hash));
        assert!(hosts_match(&hashed, "example.test"));
        assert!(!hosts_match(&hashed, "other.test"));

        let dir = std::env::temp_dir().join(format!("promptly-kh4-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let user = dir.join("user_known_hosts");
        let k = key().to_openssh().unwrap();
        std::fs::write(
            &user,
            format!(
                "# comment\n@cert-authority *.test ssh-ed25519 AAAA\ngarbage line\n{hashed} {k}\n"
            ),
        )
        .unwrap();
        let store = FileKnownHosts::new(vec![user.clone()], dir.join("known_hosts"));
        assert_eq!(
            store.check("example.test", 22, &key()),
            HostKeyStatus::Known,
            "odd lines do not hide the good one"
        );
        std::fs::write(&user, format!("@revoked example.test {k}\n")).unwrap();
        assert_eq!(
            store.check("example.test", 22, &key()),
            HostKeyStatus::Revoked
        );
        store.remember("example.test", 22, &key()).unwrap();
        assert_eq!(
            store.check("example.test", 22, &key()),
            HostKeyStatus::Revoked,
            "a revoked key stays revoked"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn keys_remembered_at_once_by_separate_stores_all_survive() {
        let dir = std::env::temp_dir().join(format!("promptly-kh5-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("known_hosts");
        let threads: Vec<_> = (0..16)
            .map(|i| {
                let path = path.clone();
                std::thread::spawn(move || {
                    let store = FileKnownHosts::new(vec![], path);
                    store
                        .remember(&format!("host{i}.test"), 22, &key())
                        .unwrap();
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        let store = FileKnownHosts::new(vec![], path);
        for i in 0..16 {
            assert_eq!(
                store.check(&format!("host{i}.test"), 22, &key()),
                HostKeyStatus::Known,
                "host{i} kept"
            );
        }
        let leftovers = std::fs::read_dir(&dir).unwrap().count();
        assert_eq!(leftovers, 1, "no temporary files left behind");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_key_of_another_kind_is_a_change_not_a_first_meeting() {
        let dir = std::env::temp_dir().join(format!("promptly-kh3-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let store = FileKnownHosts::new(vec![], dir.join("known_hosts"));
        store.remember("example.test", 22, &key()).unwrap();
        let ecdsa = ecdsa_key();
        assert_eq!(
            store.check("example.test", 22, &ecdsa),
            HostKeyStatus::Changed
        );
        let prefs = preferred_host_key_algorithms(&store.known_algorithms("example.test", 22));
        assert_eq!(
            prefs[0],
            Algorithm::Ed25519,
            "the trusted kind is asked for first"
        );
        assert_eq!(prefs.len(), russh::Preferred::DEFAULT.key.len());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
