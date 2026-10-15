//! SSH key generation and import for the Keys screen.

use flutter_rust_bridge::frb;
use promptly_ssh::KeyKind;

pub enum SshKeyKind {
    Ed25519,
    EcdsaP256,
    Rsa4096,
}

pub struct GeneratedKey {
    /// `ed25519`, `ecdsa` or `rsa`.
    pub kind: String,
    pub private_openssh: String,
    pub public_openssh: String,
    pub fingerprint: String,
}

pub struct KeyInfo {
    pub kind: String,
    pub public_openssh: Option<String>,
    pub fingerprint: Option<String>,
    pub encrypted: bool,
    pub comment: String,
}

/// Generate a key pair. The private half comes back as text for the app to
/// put in the secret store; the engine keeps nothing.
#[frb(sync)]
pub fn key_generate(kind: SshKeyKind, comment: String) -> Result<GeneratedKey, String> {
    let kind = match kind {
        SshKeyKind::Ed25519 => KeyKind::Ed25519,
        SshKeyKind::EcdsaP256 => KeyKind::EcdsaP256,
        SshKeyKind::Rsa4096 => KeyKind::Rsa4096,
    };
    let g = promptly_ssh::generate_key(kind, &comment)?;
    Ok(GeneratedKey {
        kind: g.kind.name().to_string(),
        private_openssh: g.private_openssh,
        public_openssh: g.public_openssh,
        fingerprint: g.fingerprint,
    })
}

/// Read a pasted or imported private key: its type, public half and
/// whether it needs a passphrase. Accepts OpenSSH, PEM and PuTTY text.
#[frb(sync)]
pub fn key_inspect(private_key: String, passphrase: Option<String>) -> Result<KeyInfo, String> {
    let i = promptly_ssh::inspect_key(&private_key, passphrase.as_deref())?;
    Ok(KeyInfo {
        kind: i.kind,
        public_openssh: i.public_openssh,
        fingerprint: i.fingerprint,
        encrypted: i.encrypted,
        comment: i.comment,
    })
}

/// The SHA256 fingerprint of a public key, for lists and the host key prompt.
#[frb(sync)]
pub fn key_fingerprint(public_key: String) -> Result<String, String> {
    promptly_ssh::public_fingerprint(&public_key)
}
