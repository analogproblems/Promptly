//! The app passcode, for devices with no system way to check who is there.
//!
//! Phones, Macs and Windows unlock Promptly with the system's own check
//! (fingerprint, face, PIN, Windows Hello). Linux has no such check an app
//! can ask for, so there Promptly keeps a passcode of its own: stored only
//! as an Argon2id hash, on this device, never in the vault.

use argon2::{Algorithm, Argon2, Params, Version};
use base64::Engine as _;
use rand::Rng;

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD_NO_PAD;

fn stretch(passcode: &str, salt: &[u8], m: u32, t: u32, p: u32) -> Option<[u8; 32]> {
    let params = Params::new(m, t, p, Some(32)).ok()?;
    let mut out = [0u8; 32];
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(passcode.as_bytes(), salt, &mut out)
        .ok()?;
    Some(out)
}

/// A hash of `passcode` to keep: `argon2id$m$t$p$salt$hash`.
pub fn passcode_hash(passcode: String) -> String {
    let passcode = zeroize::Zeroizing::new(passcode);
    let mut salt = [0u8; 16];
    rand::rng().fill_bytes(&mut salt);
    let (m, t, p) = (19 * 1024, 2, 1);
    let hash = zeroize::Zeroizing::new(
        stretch(&passcode, &salt, m, t, p).expect("fixed parameters are valid"),
    );
    format!(
        "argon2id${m}${t}${p}${}${}",
        B64.encode(salt),
        B64.encode(*hash)
    )
}

/// Whether `passcode` is the one `stored` was made from.
pub fn passcode_verify(passcode: String, stored: String) -> bool {
    let passcode = zeroize::Zeroizing::new(passcode);
    let parts: Vec<&str> = stored.split('$').collect();
    let [alg, m, t, p, salt, hash] = parts.as_slice() else {
        return false;
    };
    if *alg != "argon2id" {
        return false;
    }
    let (Ok(m), Ok(t), Ok(p), Ok(salt), Ok(hash)) = (
        m.parse(),
        t.parse(),
        p.parse(),
        B64.decode(salt),
        B64.decode(hash),
    ) else {
        return false;
    };
    let Some(got) = stretch(&passcode, &salt, m, t, p) else {
        return false;
    };
    let got = zeroize::Zeroizing::new(got);
    // Compare without stopping at the first difference.
    got.len() == hash.len() && got.iter().zip(&hash).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_passcode_checks_against_its_own_hash_only() {
        let h = passcode_hash("4821".into());
        assert!(h.starts_with("argon2id$"));
        assert!(passcode_verify("4821".into(), h.clone()));
        assert!(!passcode_verify("4822".into(), h.clone()));
        assert!(!passcode_verify("4821".into(), "garbage".into()));
        assert_ne!(h, passcode_hash("4821".into()), "salted");
    }
}
