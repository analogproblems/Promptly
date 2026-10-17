//! `vault.json`, the key hierarchy of VAULT.md section 4.
//!
//! The data key is wrapped twice: once under a key derived from the
//! passphrase, once under a key derived from a recovery code shown once at
//! setup. Nothing in the manifest needs secrecy.

use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use rand::Rng;
use serde::{Deserialize, Serialize};

use crate::crypto::{unwrap, wrap, Dek};

pub const FORMAT: u32 = 1;

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("the passphrase is wrong")]
    WrongPassphrase,
    #[error("the recovery code is wrong")]
    WrongRecoveryCode,
    #[error("this vault needs a newer version of Promptly (format {0})")]
    NewerFormat(u32),
    #[error("the manifest is not valid: {0}")]
    Invalid(String),
    #[error("the manifest has no {0} entry")]
    MissingKey(&'static str),
}

/// Argon2id parameters. The defaults follow the design: 64 MiB, 3 passes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KdfParams {
    pub memory_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
}

impl Default for KdfParams {
    fn default() -> Self {
        Self {
            memory_kib: 65536,
            iterations: 3,
            parallelism: 1,
        }
    }
}

impl KdfParams {
    /// Weak and fast, for tests only.
    pub fn fast_for_tests() -> Self {
        Self {
            memory_kib: 1024,
            iterations: 1,
            parallelism: 1,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Kdf {
    pub alg: String,
    pub salt: String,
    pub memory_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WrappedKey {
    pub kind: String,
    pub nonce: String,
    pub wrapped_dek: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    pub format: u32,
    pub vault_id: String,
    pub created_at: String,
    pub kdf: Kdf,
    pub keys: Vec<WrappedKey>,
}

/// A recovery code as shown to the user: 160 random bits as Crockford
/// base32, in groups of four.
#[derive(Clone, PartialEq, Eq)]
pub struct RecoveryCode(String);

impl Drop for RecoveryCode {
    fn drop(&mut self) {
        zeroize::Zeroize::zeroize(&mut self.0);
    }
}

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

impl RecoveryCode {
    pub fn generate() -> Self {
        let mut bytes = [0u8; 20];
        rand::rng().fill_bytes(&mut bytes);
        Self(Self::format(&bytes))
    }

    fn format(bytes: &[u8; 20]) -> String {
        let mut chars = String::with_capacity(32);
        let mut acc: u32 = 0;
        let mut bits = 0;
        for &b in bytes {
            acc = (acc << 8) | u32::from(b);
            bits += 8;
            while bits >= 5 {
                bits -= 5;
                chars.push(ALPHABET[((acc >> bits) & 31) as usize] as char);
            }
        }
        chars
            .as_bytes()
            .chunks(4)
            .map(|c| std::str::from_utf8(c).unwrap())
            .collect::<Vec<_>>()
            .join("-")
    }

    /// Parse what the user typed: case and dashes do not matter, and the
    /// letters people confuse (O, I, L) are read as the digits they resemble.
    pub fn parse(text: &str) -> Option<Self> {
        let mut bytes = Vec::with_capacity(20);
        let mut acc: u32 = 0;
        let mut bits = 0;
        let mut n = 0;
        for c in text.chars() {
            if c == '-' || c.is_whitespace() {
                continue;
            }
            let c = match c.to_ascii_uppercase() {
                'O' => '0',
                'I' | 'L' => '1',
                other => other,
            };
            let v = ALPHABET.iter().position(|&a| a as char == c)? as u32;
            acc = (acc << 5) | v;
            bits += 5;
            n += 1;
            if bits >= 8 {
                bits -= 8;
                bytes.push(((acc >> bits) & 0xFF) as u8);
            }
        }
        if n != 32 || bytes.len() != 20 {
            return None;
        }
        let arr: [u8; 20] = bytes.try_into().ok()?;
        Some(Self(Self::format(&arr)))
    }

    /// The code as the user should write it down.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The first four characters, to tell codes apart.
    pub fn hint(&self) -> String {
        self.0.chars().take(4).collect()
    }

    fn secret_bytes(&self) -> zeroize::Zeroizing<Vec<u8>> {
        zeroize::Zeroizing::new(self.0.replace('-', "").into_bytes())
    }
}

impl std::fmt::Debug for RecoveryCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "RecoveryCode({}…)", self.hint())
    }
}

/// The wrapping key; wiped when dropped.
type WrapKey = zeroize::Zeroizing<[u8; 32]>;

fn derive(secret: &[u8], kdf: &Kdf) -> Result<WrapKey, ManifestError> {
    if kdf.alg != "argon2id" {
        return Err(ManifestError::Invalid(format!("unknown kdf {}", kdf.alg)));
    }
    let salt = B64
        .decode(&kdf.salt)
        .map_err(|e| ManifestError::Invalid(format!("salt: {e}")))?;
    let params = Params::new(kdf.memory_kib, kdf.iterations, kdf.parallelism, Some(32))
        .map_err(|e| ManifestError::Invalid(format!("kdf parameters: {e}")))?;
    let mut out = zeroize::Zeroizing::new([0u8; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(secret, &salt, out.as_mut())
        .map_err(|e| ManifestError::Invalid(format!("kdf: {e}")))?;
    Ok(out)
}

impl Manifest {
    /// A new vault: fresh id, salt, data key and recovery code.
    pub fn create(passphrase: &str, params: KdfParams) -> (Self, Dek, RecoveryCode) {
        let mut salt = [0u8; 16];
        rand::rng().fill_bytes(&mut salt);
        let kdf = Kdf {
            alg: "argon2id".into(),
            salt: B64.encode(salt),
            memory_kib: params.memory_kib,
            iterations: params.iterations,
            parallelism: params.parallelism,
        };
        let dek = Dek::generate();
        let recovery = RecoveryCode::generate();
        let mut m = Self {
            format: FORMAT,
            vault_id: uuid::Uuid::new_v4().to_string(),
            created_at: crate::ops::now_rfc3339(),
            kdf,
            keys: Vec::new(),
        };
        m.keys
            .push(m.wrap_entry("passphrase", passphrase.as_bytes(), &dek, None));
        m.keys.push(m.wrap_entry(
            "recovery",
            &recovery.secret_bytes(),
            &dek,
            Some(recovery.hint()),
        ));
        (m, dek, recovery)
    }

    fn wrap_entry(&self, kind: &str, secret: &[u8], dek: &Dek, hint: Option<String>) -> WrappedKey {
        let key = derive(secret, &self.kdf).expect("fresh parameters are valid");
        let aad = format!("{}/{kind}", self.vault_id);
        let (nonce, ct) = wrap(&key, aad.as_bytes(), &dek.0);
        WrappedKey {
            kind: kind.into(),
            nonce: B64.encode(nonce),
            wrapped_dek: B64.encode(ct),
            hint,
        }
    }

    fn unwrap_entry(&self, kind: &'static str, secret: &[u8]) -> Result<Dek, ManifestError> {
        let entry = self
            .keys
            .iter()
            .find(|k| k.kind == kind)
            .ok_or(ManifestError::MissingKey(kind))?;
        let key = derive(secret, &self.kdf)?;
        let aad = format!("{}/{kind}", self.vault_id);
        let nonce = B64
            .decode(&entry.nonce)
            .map_err(|e| ManifestError::Invalid(format!("nonce: {e}")))?;
        let ct = B64
            .decode(&entry.wrapped_dek)
            .map_err(|e| ManifestError::Invalid(format!("wrapped key: {e}")))?;
        let plain = unwrap(&key, aad.as_bytes(), &nonce, &ct)
            .map(zeroize::Zeroizing::new)
            .map_err(|_| match kind {
                "recovery" => ManifestError::WrongRecoveryCode,
                _ => ManifestError::WrongPassphrase,
            })?;
        Dek::from_slice(&plain).ok_or(ManifestError::Invalid("wrapped key length".into()))
    }

    pub fn unlock(&self, passphrase: &str) -> Result<Dek, ManifestError> {
        self.unwrap_entry("passphrase", passphrase.as_bytes())
    }

    pub fn unlock_with_recovery(&self, code: &RecoveryCode) -> Result<Dek, ManifestError> {
        self.unwrap_entry("recovery", &code.secret_bytes())
    }

    /// The hint of the recovery code, so the user knows which one to find.
    pub fn recovery_hint(&self) -> Option<&str> {
        self.keys
            .iter()
            .find(|k| k.kind == "recovery")
            .and_then(|k| k.hint.as_deref())
    }

    /// Re-wrap the data key under a new passphrase; the data is untouched.
    pub fn change_passphrase(&mut self, dek: &Dek, new_passphrase: &str) {
        let entry = self.wrap_entry("passphrase", new_passphrase.as_bytes(), dek, None);
        self.keys.retain(|k| k.kind != "passphrase");
        self.keys.push(entry);
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("manifest serialises")
    }

    pub fn from_json(json: &[u8]) -> Result<Self, ManifestError> {
        let m: Self =
            serde_json::from_slice(json).map_err(|e| ManifestError::Invalid(e.to_string()))?;
        if m.format > FORMAT {
            return Err(ManifestError::NewerFormat(m.format));
        }
        Ok(m)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_unlock_recover_and_change_passphrase() {
        let (mut m, dek, code) = Manifest::create("correct horse", KdfParams::fast_for_tests());
        let json = m.to_json();
        assert!(json.contains(r#""alg": "argon2id""#));
        assert!(!json.contains("correct horse"));
        let back = Manifest::from_json(json.as_bytes()).unwrap();
        assert_eq!(back.unlock("correct horse").unwrap(), dek);
        assert!(matches!(
            back.unlock("wrong"),
            Err(ManifestError::WrongPassphrase)
        ));
        assert_eq!(back.unlock_with_recovery(&code).unwrap(), dek);
        assert_eq!(back.recovery_hint(), Some(code.hint().as_str()));
        let wrong = RecoveryCode::generate();
        assert!(matches!(
            back.unlock_with_recovery(&wrong),
            Err(ManifestError::WrongRecoveryCode)
        ));

        m.change_passphrase(&dek, "battery staple");
        assert_eq!(m.keys.len(), 2);
        assert_eq!(m.unlock("battery staple").unwrap(), dek);
        assert!(m.unlock("correct horse").is_err());
        assert_eq!(
            m.unlock_with_recovery(&code).unwrap(),
            dek,
            "recovery still works"
        );
    }

    #[test]
    fn recovery_codes_read_back_however_they_are_typed() {
        let code = RecoveryCode::generate();
        let s = code.as_str();
        assert_eq!(s.len(), 32 + 7, "eight groups of four: {s}");
        assert!(s.chars().all(|c| c == '-' || ALPHABET.contains(&(c as u8))));
        assert_eq!(RecoveryCode::parse(s), Some(code.clone()));
        let sloppy = s
            .to_lowercase()
            .replace('-', " ")
            .replace('0', "o")
            .replace('1', "l");
        assert_eq!(RecoveryCode::parse(&sloppy), Some(code.clone()));
        assert!(RecoveryCode::parse("ABCD").is_none());
        assert!(
            RecoveryCode::parse(&format!("{s}U")).is_none(),
            "U is not in the alphabet"
        );
    }

    #[test]
    fn newer_formats_are_refused() {
        let (m, _, _) = Manifest::create("x", KdfParams::fast_for_tests());
        let json = m.to_json().replace(r#""format": 1"#, r#""format": 7"#);
        assert!(matches!(
            Manifest::from_json(json.as_bytes()),
            Err(ManifestError::NewerFormat(7))
        ));
    }
}
