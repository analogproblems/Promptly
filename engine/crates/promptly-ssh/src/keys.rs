//! Generating and inspecting SSH keys.

use russh::keys::ssh_key::LineEnding;
use russh::keys::{self, Algorithm, EcdsaCurve, HashAlg, PrivateKey};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyKind {
    Ed25519,
    EcdsaP256,
    Rsa4096,
}

impl KeyKind {
    pub fn name(self) -> &'static str {
        match self {
            KeyKind::Ed25519 => "ed25519",
            KeyKind::EcdsaP256 => "ecdsa",
            KeyKind::Rsa4096 => "rsa",
        }
    }
}

/// A freshly generated key pair in OpenSSH text form.
#[derive(Debug, Clone)]
pub struct Generated {
    pub kind: KeyKind,
    pub private_openssh: String,
    pub public_openssh: String,
    pub fingerprint: String,
}

/// What can be read from a private key without using it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Inspected {
    /// `ed25519`, `ecdsa` or `rsa`.
    pub kind: String,
    /// The public half in OpenSSH one-line form, when readable. Encrypted
    /// PEM or PuTTY keys hide it until the passphrase is given.
    pub public_openssh: Option<String>,
    pub fingerprint: Option<String>,
    pub encrypted: bool,
    pub comment: String,
}

pub fn generate(kind: KeyKind, comment: &str) -> Result<Generated, String> {
    let algorithm = match kind {
        KeyKind::Ed25519 => Algorithm::Ed25519,
        KeyKind::EcdsaP256 => Algorithm::Ecdsa {
            curve: EcdsaCurve::NistP256,
        },
        KeyKind::Rsa4096 => Algorithm::Rsa { hash: None },
    };
    let mut rng = rand::rng();
    let mut key = PrivateKey::random(&mut rng, algorithm).map_err(|e| e.to_string())?;
    if !comment.trim().is_empty() {
        key.set_comment(comment.trim());
    }
    let private_openssh = key
        .to_openssh(LineEnding::LF)
        .map_err(|e| e.to_string())?
        .to_string();
    let public_openssh = key.public_key().to_openssh().map_err(|e| e.to_string())?;
    Ok(Generated {
        kind,
        private_openssh,
        public_openssh,
        fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
    })
}

fn kind_name(algorithm: &Algorithm) -> String {
    match algorithm {
        Algorithm::Ed25519 => "ed25519".into(),
        Algorithm::Ecdsa { .. } => "ecdsa".into(),
        Algorithm::Rsa { .. } => "rsa".into(),
        other => other.as_str().to_string(),
    }
}

/// Read what a private key is without decrypting it where possible.
pub fn inspect(private_key: &str, passphrase: Option<&str>) -> Result<Inspected, String> {
    // OpenSSH format keeps the public half in clear even when encrypted.
    if let Ok(key) = PrivateKey::from_openssh(private_key) {
        if key.is_encrypted() {
            if let Some(pw) = passphrase {
                let key = key
                    .decrypt(pw.as_bytes())
                    .map_err(|_| "wrong passphrase".to_string())?;
                return Ok(describe(&key, false));
            }
            return Ok(describe(&key, true));
        }
        return Ok(describe(&key, false));
    }
    // PEM and PuTTY forms.
    match keys::decode_secret_key(private_key, passphrase) {
        Ok(key) => Ok(describe(&key, false)),
        Err(keys::Error::KeyIsEncrypted) => Ok(Inspected {
            kind: String::new(),
            public_openssh: None,
            fingerprint: None,
            encrypted: true,
            comment: String::new(),
        }),
        Err(e) => Err(format!("not a private key: {e}")),
    }
}

/// The SHA256 fingerprint of a public key in OpenSSH one-line form.
pub fn public_fingerprint(public_openssh: &str) -> Result<String, String> {
    let key = keys::PublicKey::from_openssh(public_openssh.trim())
        .map_err(|e| format!("not a public key: {e}"))?;
    Ok(key.fingerprint(HashAlg::Sha256).to_string())
}

fn describe(key: &PrivateKey, encrypted: bool) -> Inspected {
    Inspected {
        kind: kind_name(&key.algorithm()),
        public_openssh: key.public_key().to_openssh().ok(),
        fingerprint: Some(key.fingerprint(HashAlg::Sha256).to_string()),
        encrypted,
        comment: key.comment().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_each_kind_and_inspects_it_back() {
        for kind in [KeyKind::Ed25519, KeyKind::EcdsaP256] {
            let g = generate(kind, "test@promptly").unwrap();
            assert!(g
                .private_openssh
                .starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"));
            assert!(g.public_openssh.ends_with("test@promptly"));
            assert!(g.fingerprint.starts_with("SHA256:"));
            let i = inspect(&g.private_openssh, None).unwrap();
            assert_eq!(i.kind, kind.name());
            assert_eq!(i.public_openssh.as_deref(), Some(g.public_openssh.as_str()));
            assert_eq!(i.fingerprint.as_deref(), Some(g.fingerprint.as_str()));
            assert!(!i.encrypted);
            assert_eq!(i.comment, "test@promptly");
        }
    }

    #[test]
    fn rsa_generation_works() {
        let g = generate(KeyKind::Rsa4096, "").unwrap();
        assert!(g.public_openssh.starts_with("ssh-rsa "));
        assert_eq!(inspect(&g.private_openssh, None).unwrap().kind, "rsa");
    }

    #[test]
    fn public_fingerprint_matches_the_private_one() {
        let g = generate(KeyKind::Ed25519, "x").unwrap();
        assert_eq!(
            public_fingerprint(&g.public_openssh).unwrap(),
            g.fingerprint
        );
        assert!(public_fingerprint("nope").is_err());
    }

    #[test]
    fn garbage_is_rejected() {
        assert!(inspect("not a key", None).is_err());
    }
}
