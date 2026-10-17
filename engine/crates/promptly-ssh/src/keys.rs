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
#[derive(Clone)]
pub struct Generated {
    pub kind: KeyKind,
    pub private_openssh: String,
    pub public_openssh: String,
    pub fingerprint: String,
}

impl std::fmt::Debug for Generated {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Generated")
            .field("kind", &self.kind)
            .field("public_openssh", &self.public_openssh)
            .field("fingerprint", &self.fingerprint)
            .finish_non_exhaustive()
    }
}

/// What can be read from a private key without using it.
#[derive(Clone, PartialEq, Eq)]
pub struct Inspected {
    /// `ed25519`, `ecdsa` or `rsa`.
    pub kind: String,
    /// The public half in OpenSSH one-line form, when readable. Encrypted
    /// PEM or PuTTY keys hide it until the passphrase is given.
    pub public_openssh: Option<String>,
    pub fingerprint: Option<String>,
    pub encrypted: bool,
    pub comment: String,
    /// The same key in OpenSSH form, when it could be read in full. For a
    /// PuTTY or PEM key this is what to keep instead of the original text.
    pub private_openssh: Option<String>,
    /// True when the text was not OpenSSH to begin with (PuTTY `.ppk`,
    /// PEM), so `private_openssh` is a conversion worth storing.
    pub converted: bool,
}

impl std::fmt::Debug for Inspected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Inspected")
            .field("kind", &self.kind)
            .field("public_openssh", &self.public_openssh)
            .field("fingerprint", &self.fingerprint)
            .field("encrypted", &self.encrypted)
            .field("converted", &self.converted)
            .finish_non_exhaustive()
    }
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
                return Ok(describe(&key, false, false));
            }
            return Ok(describe(&key, true, false));
        }
        return Ok(describe(&key, false, false));
    }
    // A locked PuTTY key still shows its public half and comment in clear.
    if is_ppk(private_key) && passphrase.is_none() {
        if let Some(ppk) = ppk_header(private_key) {
            if ppk.encrypted {
                let public = ppk.public.as_ref();
                return Ok(Inspected {
                    kind: public
                        .map(|p| kind_name(&p.algorithm()))
                        .unwrap_or_default(),
                    public_openssh: public.and_then(|p| p.to_openssh().ok()),
                    fingerprint: public.map(|p| p.fingerprint(HashAlg::Sha256).to_string()),
                    encrypted: true,
                    comment: ppk.comment,
                    private_openssh: None,
                    converted: true,
                });
            }
        }
    }
    // PEM and PuTTY forms.
    match keys::decode_secret_key(private_key, passphrase) {
        Ok(key) => match passphrase {
            // A locked key stays locked: its conversion is encrypted with the
            // same passphrase.
            Some(pw) if is_locked(private_key) => {
                let mut i = describe(&key, false, true);
                let locked = key
                    .encrypt(&mut rand::rng(), pw.as_bytes())
                    .map_err(|e| format!("could not convert the key: {e}"))?;
                i.private_openssh = Some(
                    locked
                        .to_openssh(LineEnding::LF)
                        .map_err(|e| format!("could not convert the key: {e}"))?
                        .to_string(),
                );
                i.encrypted = true;
                Ok(i)
            }
            _ => Ok(describe(&key, false, true)),
        },
        Err(keys::Error::KeyIsEncrypted) => Ok(Inspected {
            kind: String::new(),
            public_openssh: None,
            fingerprint: None,
            encrypted: true,
            comment: String::new(),
            private_openssh: None,
            converted: true,
        }),
        Err(e) if passphrase.is_some() && is_ppk(private_key) => Err(format!(
            "could not unlock the PuTTY key, wrong passphrase? ({e})"
        )),
        Err(e) => Err(format!("not a private key: {e}")),
    }
}

/// Whether a PEM or PuTTY key needs a passphrase to read.
fn is_locked(text: &str) -> bool {
    match ppk_header(text) {
        Some(ppk) => ppk.encrypted,
        None => matches!(
            keys::decode_secret_key(text, None),
            Err(keys::Error::KeyIsEncrypted)
        ),
    }
}

fn is_ppk(text: &str) -> bool {
    text.trim_start().starts_with("PuTTY-User-Key-File-")
}

/// What a PuTTY key file says about itself before any decryption.
struct PpkHeader {
    encrypted: bool,
    comment: String,
    public: Option<keys::PublicKey>,
}

fn ppk_header(text: &str) -> Option<PpkHeader> {
    let mut lines = text.lines().map(str::trim_end);
    let first = lines.next()?;
    if !first.starts_with("PuTTY-User-Key-File-") {
        return None;
    }
    let mut encrypted = false;
    let mut comment = String::new();
    let mut public = None;
    while let Some(line) = lines.next() {
        if let Some(v) = line.strip_prefix("Encryption:") {
            encrypted = v.trim() != "none";
        } else if let Some(v) = line.strip_prefix("Comment:") {
            comment = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("Public-Lines:") {
            let n: usize = v.trim().parse().ok()?;
            let b64: String = lines.by_ref().take(n).map(str::trim).collect();
            use base64::Engine;
            let bytes = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
            public = keys::PublicKey::from_bytes(&bytes).ok();
            break;
        }
    }
    Some(PpkHeader {
        encrypted,
        comment,
        public,
    })
}

/// A private key for saving outside Promptly. Without `new_passphrase` it
/// is the text exactly as stored, locked or not. With one, the key is
/// unlocked (with `passphrase` if it has one) and written out in OpenSSH
/// form behind the new passphrase instead.
pub fn export(
    private_key: &str,
    passphrase: Option<&str>,
    new_passphrase: Option<&str>,
) -> Result<String, String> {
    let Some(new) = new_passphrase else {
        return Ok(private_key.to_string());
    };
    if new.is_empty() {
        return Err("Choose a new passphrase.".into());
    }
    let key = match keys::decode_secret_key(private_key, passphrase) {
        Ok(key) => key,
        Err(keys::Error::KeyIsEncrypted) => {
            return Err(
                "This key has a passphrase. Type it to lock the copy with a new one.".into(),
            )
        }
        Err(_) if passphrase.is_some() => return Err("That passphrase is wrong.".into()),
        Err(e) => return Err(format!("not a private key: {e}")),
    };
    let locked = key
        .encrypt(&mut rand::rng(), new.as_bytes())
        .map_err(|e| format!("could not lock the key: {e}"))?;
    Ok(locked
        .to_openssh(LineEnding::LF)
        .map_err(|e| format!("could not write the key: {e}"))?
        .to_string())
}

/// The SHA256 fingerprint of a public key in OpenSSH one-line form.
pub fn public_fingerprint(public_openssh: &str) -> Result<String, String> {
    let key = keys::PublicKey::from_openssh(public_openssh.trim())
        .map_err(|e| format!("not a public key: {e}"))?;
    Ok(key.fingerprint(HashAlg::Sha256).to_string())
}

fn describe(key: &PrivateKey, encrypted: bool, converted: bool) -> Inspected {
    Inspected {
        kind: kind_name(&key.algorithm()),
        public_openssh: key.public_key().to_openssh().ok(),
        fingerprint: Some(key.fingerprint(HashAlg::Sha256).to_string()),
        encrypted,
        comment: key.comment().to_string(),
        private_openssh: if encrypted {
            None
        } else {
            key.to_openssh(LineEnding::LF).ok().map(|s| s.to_string())
        },
        converted,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn public_of(fixture: &str) -> String {
        let text = std::fs::read_to_string(format!("testdata/{fixture}.pub")).unwrap();
        // puttygen writes "ssh-ed25519 AAAA... comment"; compare type and key only.
        let mut parts = text.split_whitespace();
        format!("{} {}", parts.next().unwrap(), parts.next().unwrap())
    }

    fn key_only(public_openssh: &str) -> String {
        let mut parts = public_openssh.split_whitespace();
        format!("{} {}", parts.next().unwrap(), parts.next().unwrap())
    }

    #[test]
    fn putty_keys_convert_to_openssh() {
        // A PPK version 3 key without a passphrase.
        let plain = std::fs::read_to_string("testdata/ed25519-plain.ppk").unwrap();
        let i = inspect(&plain, None).unwrap();
        assert_eq!(i.kind, "ed25519");
        assert!(!i.encrypted);
        assert!(i.converted);
        assert_eq!(
            key_only(i.public_openssh.as_deref().unwrap()),
            public_of("ed25519-plain")
        );
        let openssh = i.private_openssh.as_deref().unwrap();
        assert!(openssh.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"));
        // The conversion is the same key.
        let again = inspect(openssh, None).unwrap();
        assert_eq!(again.public_openssh, i.public_openssh);
        assert!(!again.converted);

        // A PPK version 2 key behind a passphrase: locked until given.
        let locked = std::fs::read_to_string("testdata/ed25519-locked-v2.ppk").unwrap();
        let i = inspect(&locked, None).unwrap();
        assert!(i.encrypted);
        assert!(i.private_openssh.is_none());
        assert_eq!(i.comment, "promptly test locked");
        assert_eq!(
            key_only(i.public_openssh.as_deref().unwrap()),
            public_of("ed25519-locked-v2"),
            "the public half is readable without the passphrase"
        );
        assert!(inspect(&locked, Some("nope"))
            .unwrap_err()
            .contains("passphrase"));
        let i = inspect(&locked, Some("letmein")).unwrap();
        assert_eq!(
            key_only(i.public_openssh.as_deref().unwrap()),
            public_of("ed25519-locked-v2")
        );
        // Its conversion needs the same passphrase.
        let openssh = i.private_openssh.as_deref().unwrap();
        let stored = PrivateKey::from_openssh(openssh).unwrap();
        assert!(stored.is_encrypted());
        assert!(stored.clone().decrypt(b"nope").is_err());
        assert_eq!(
            key_only(
                &stored
                    .decrypt(b"letmein")
                    .unwrap()
                    .public_key()
                    .to_openssh()
                    .unwrap()
            ),
            public_of("ed25519-locked-v2")
        );

        // A PPK version 3 RSA key (Argon2 key derivation).
        let rsa = std::fs::read_to_string("testdata/rsa-locked-v3.ppk").unwrap();
        let i = inspect(&rsa, Some("letmein")).unwrap();
        assert_eq!(i.kind, "rsa");
        assert_eq!(
            key_only(i.public_openssh.as_deref().unwrap()),
            public_of("rsa-locked-v3")
        );
    }

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
    fn export_gives_the_key_as_stored_or_locked_with_a_new_passphrase() {
        let g = generate(KeyKind::Ed25519, "x").unwrap();
        assert_eq!(
            export(&g.private_openssh, None, None).unwrap(),
            g.private_openssh
        );
        assert!(export(&g.private_openssh, None, Some("")).is_err());

        let locked = export(&g.private_openssh, None, Some("first")).unwrap();
        assert!(inspect(&locked, None).unwrap().encrypted);
        let unlocked = inspect(&locked, Some("first")).unwrap();
        assert_eq!(
            unlocked.public_openssh.as_deref(),
            Some(g.public_openssh.as_str())
        );

        // A locked key needs its passphrase before it can take a new one.
        assert!(export(&locked, None, Some("second"))
            .unwrap_err()
            .contains("has a passphrase"));
        assert!(export(&locked, Some("nope"), Some("second"))
            .unwrap_err()
            .contains("wrong"));
        let relocked = export(&locked, Some("first"), Some("second")).unwrap();
        assert!(inspect(&relocked, Some("first")).is_err());
        assert!(inspect(&relocked, Some("second")).is_ok());
        // As stored, a locked key stays locked.
        assert_eq!(export(&locked, None, None).unwrap(), locked);
    }

    #[test]
    fn garbage_is_rejected() {
        assert!(inspect("not a key", None).is_err());
    }
}
