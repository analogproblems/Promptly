//! The file envelope of VAULT.md section 5: zstd, then XChaCha20-Poly1305
//! under the vault's data key, bound to the file's place by associated data.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use rand::Rng;

use crate::clock::DeviceId;

pub const MAGIC: &[u8; 4] = b"PVLT";
pub const ENVELOPE_VERSION: u8 = 1;
const NONCE_LEN: usize = 24;
const HEADER_LEN: usize = 4 + 1 + NONCE_LEN;
const TAG_LEN: usize = 16;

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("not a vault file")]
    NotAVaultFile,
    #[error("vault file envelope version {0} is newer than this app understands")]
    NewerEnvelope(u8),
    #[error("the file is corrupt or was tampered with")]
    Authentication,
    #[error("compression failed: {0}")]
    Compression(#[from] std::io::Error),
}

/// The data encryption key: 32 random bytes made once per vault.
#[derive(Clone, PartialEq, Eq)]
pub struct Dek(pub [u8; 32]);

impl Dek {
    pub fn generate() -> Self {
        let mut k = [0u8; 32];
        rand::rng().fill_bytes(&mut k);
        Self(k)
    }

    pub fn from_slice(bytes: &[u8]) -> Option<Self> {
        bytes.try_into().ok().map(Self)
    }
}

impl Drop for Dek {
    fn drop(&mut self) {
        zeroize::Zeroize::zeroize(&mut self.0);
    }
}

impl std::fmt::Debug for Dek {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Dek(…)")
    }
}

/// The associated data that binds a file to its place in the vault.
pub fn aad(vault_id: &str, device: &DeviceId, file_name: &str) -> Vec<u8> {
    format!("{vault_id}/{device}/{file_name}").into_bytes()
}

/// Compress and encrypt, producing a complete file.
pub fn seal(dek: &Dek, aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
    let compressed = zstd::encode_all(plaintext, 3)?;
    let mut nonce = [0u8; NONCE_LEN];
    rand::rng().fill_bytes(&mut nonce);
    let cipher = XChaCha20Poly1305::new(&Key::from(dek.0));
    let ciphertext = cipher
        .encrypt(
            &XNonce::from(nonce),
            Payload {
                msg: &compressed,
                aad,
            },
        )
        .map_err(|_| CryptoError::Authentication)?;
    let mut out = Vec::with_capacity(HEADER_LEN + ciphertext.len());
    out.extend_from_slice(MAGIC);
    out.push(ENVELOPE_VERSION);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

/// Verify, decrypt and decompress a complete file.
pub fn open(dek: &Dek, aad: &[u8], bytes: &[u8]) -> Result<Vec<u8>, CryptoError> {
    if bytes.len() < HEADER_LEN + TAG_LEN || &bytes[..4] != MAGIC {
        return Err(CryptoError::NotAVaultFile);
    }
    if bytes[4] != ENVELOPE_VERSION {
        return Err(CryptoError::NewerEnvelope(bytes[4]));
    }
    let nonce = XNonce::try_from(&bytes[5..HEADER_LEN]).map_err(|_| CryptoError::NotAVaultFile)?;
    let cipher = XChaCha20Poly1305::new(&Key::from(dek.0));
    let compressed = cipher
        .decrypt(
            &nonce,
            Payload {
                msg: &bytes[HEADER_LEN..],
                aad,
            },
        )
        .map_err(|_| CryptoError::Authentication)?;
    Ok(zstd::decode_all(&compressed[..])?)
}

/// Encrypt a small value with a key other than the data key, no
/// compression: used for wrapping the data key itself.
pub(crate) fn wrap(key: &[u8; 32], aad: &[u8], plaintext: &[u8]) -> ([u8; NONCE_LEN], Vec<u8>) {
    let mut nonce = [0u8; NONCE_LEN];
    rand::rng().fill_bytes(&mut nonce);
    let cipher = XChaCha20Poly1305::new(&Key::from(*key));
    let ct = cipher
        .encrypt(
            &XNonce::from(nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .expect("encryption cannot fail for small inputs");
    (nonce, ct)
}

pub(crate) fn unwrap(
    key: &[u8; 32],
    aad: &[u8],
    nonce: &[u8],
    ciphertext: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    if nonce.len() != NONCE_LEN {
        return Err(CryptoError::Authentication);
    }
    let cipher = XChaCha20Poly1305::new(&Key::from(*key));
    cipher
        .decrypt(
            &XNonce::try_from(nonce).map_err(|_| CryptoError::Authentication)?,
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|_| CryptoError::Authentication)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dev() -> DeviceId {
        DeviceId::parse(&"a".repeat(32)).unwrap()
    }

    #[test]
    fn seal_and_open_round_trip_with_compression() {
        let dek = Dek::generate();
        let text = r#"{"ops":["#.repeat(200);
        let aad = aad("vault", &dev(), "000001.seg");
        let file = seal(&dek, &aad, text.as_bytes()).unwrap();
        assert!(file.starts_with(b"PVLT\x01"));
        assert!(
            file.len() < text.len() / 4,
            "json compresses well: {} vs {}",
            file.len(),
            text.len()
        );
        assert_eq!(open(&dek, &aad, &file).unwrap(), text.as_bytes());
    }

    #[test]
    fn tampering_renaming_and_wrong_keys_are_rejected() {
        let dek = Dek::generate();
        let aad1 = aad("vault", &dev(), "000001.seg");
        let mut file = seal(&dek, &aad1, b"hello").unwrap();
        // Another place in the vault.
        let aad2 = aad("vault", &dev(), "000002.seg");
        assert!(matches!(
            open(&dek, &aad2, &file),
            Err(CryptoError::Authentication)
        ));
        // Another key.
        assert!(matches!(
            open(&Dek::generate(), &aad1, &file),
            Err(CryptoError::Authentication)
        ));
        // A flipped byte.
        let last = file.len() - 1;
        file[last] ^= 1;
        assert!(matches!(
            open(&dek, &aad1, &file),
            Err(CryptoError::Authentication)
        ));
        // Not a vault file at all, or from the future.
        assert!(matches!(
            open(&dek, &aad1, b"hello"),
            Err(CryptoError::NotAVaultFile)
        ));
        let mut future = seal(&dek, &aad1, b"x").unwrap();
        future[4] = 9;
        assert!(matches!(
            open(&dek, &aad1, &future),
            Err(CryptoError::NewerEnvelope(9))
        ));
    }

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    /// Files and wrapped keys written by Promptly 1.0.1 must still open, so
    /// a crypto library update can never lock anyone out of their vault.
    #[test]
    fn opens_files_written_by_1_0_1() {
        let file = hex("50564c54015a2d1f94dd238754e22d6ae84ccddc4768fca61d3b08ff844702f7fc4fa49b8ee0fcf8aa1f356aadafc8159b67e0ac3167aa7511f9a2a7175a4c815ce306bd54fc");
        let aad = aad("vault", &dev(), "000001.seg");
        assert_eq!(
            open(&Dek([7u8; 32]), &aad, &file).unwrap(),
            b"hello from 1.0.1"
        );

        let nonce = hex("94609502705e6ae050b377b11f33c40994286ad0988d5850");
        let wrapped = hex("78c4ca7f61fa6a73b5fa36a2eaf72790107f6e4c76168116b5ad517194dbac36373ae3f6d0ab035ebf4942e9ace03da8");
        assert_eq!(
            unwrap(&[9u8; 32], b"wrap", &nonce, &wrapped).unwrap(),
            [7u8; 32]
        );
    }
}
