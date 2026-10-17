//! Putting a public key on a server, as `ssh-copy-id` does: one shell
//! command, run over an ordinary login, that appends the key to
//! `~/.ssh/authorized_keys` unless it is there already.

use russh::keys::PublicKey;

/// Printed by the command when it added the key.
const ADDED: &str = "promptly-key-added";
/// Printed by the command when the key was there already.
const PRESENT: &str = "promptly-key-present";
/// Whether the file already lists the key. Comment and blank lines are
/// skipped. A line that does not start with a key type starts with its
/// options, which run to the first space outside double quotes (a quote
/// can be escaped with a backslash); the key type and key follow, and
/// anything after them is the line's comment. One line, as the command
/// may pass through a login shell that won't take a newline in quotes.
const FIND: &str = concat!(
    r#"/^[ \t]*(#|$)/{next} "#,
    r#"{s=$0; sub(/^[ \t]+/,"",s); "#,
    r#"if (s !~ /^(ssh-|ecdsa-|sk-)/) {q=0; n=length(s); "#,
    r#"for (i=1; i<=n; i++) {c=substr(s,i,1); "#,
    r#"if (c=="\\") {i++; continue} "#,
    r#"if (c=="\"") q=!q; else if (!q && (c==" " || c=="\t")) break} "#,
    r#"s=substr(s,i); sub(/^[ \t]+/,"",s)} "#,
    r#"split(s,w,/[ \t]+/); if (w[1]==t && w[2]==k) f=1} "#,
    r#"END{exit f?0:1}"#,
);

/// The one-line command that installs `public_key` (OpenSSH one-line
/// form) for the login it runs as. A missing `~/.ssh` is made with mode
/// 700 and a missing `authorized_keys` with mode 600; existing ones keep
/// their modes. A key already listed, with or without options in front,
/// is not added again. The work is done by `sh` whatever the login shell,
/// and the whole command is one line, as some shells refuse a quoted
/// newline.
pub fn command(public_key: &str) -> Result<String, String> {
    let line = public_key.trim();
    PublicKey::from_openssh(line).map_err(|e| format!("not a public key: {e}"))?;
    let mut parts = line.split_whitespace();
    let kind = parts.next().unwrap_or_default();
    let body = parts.next().unwrap_or_default();
    let comment: String = parts
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !c.is_control())
        .collect();
    let entry = if comment.is_empty() {
        format!("{kind} {body}")
    } else {
        format!("{kind} {body} {comment}")
    };
    let append = format!("printf '%s\\n' {}", quote(&entry));
    let script = [
        "umask 077".to_string(),
        r#"d="$HOME/.ssh""#.to_string(),
        r#"f="$d/authorized_keys""#.to_string(),
        r#"if [ ! -d "$d" ]; then mkdir -m 700 "$d" || exit 1; fi"#.to_string(),
        r#"if [ ! -e "$f" ]; then : > "$f" && chmod 600 "$f" || exit 1; fi"#.to_string(),
        format!(
            "if awk -v t={} -v k={} {} \"$f\"; then echo {PRESENT}; else {}; {} >> \"$f\" && echo {ADDED}; fi",
            quote(kind),
            quote(body),
            quote(FIND),
            // A last line without its newline would run into the new one.
            r#"if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then echo >> "$f"; fi"#,
            append,
        ),
    ]
    .join("; ");
    Ok(format!("sh -c {}", quote(&script)))
}

/// What the command's run says: `Ok(true)` when it added the key,
/// `Ok(false)` when the key was there already.
pub fn outcome(output: &str, exit_code: Option<i32>) -> Result<bool, String> {
    let said = |marker: &str| output.lines().any(|l| l.trim() == marker);
    if exit_code == Some(0) && said(ADDED) {
        Ok(true)
    } else if exit_code == Some(0) && said(PRESENT) {
        Ok(false)
    } else {
        let text = output.trim();
        Err(if text.is_empty() {
            "The server could not add the key to ~/.ssh/authorized_keys.".into()
        } else {
            format!("The server could not add the key to ~/.ssh/authorized_keys: {text}")
        })
    }
}

/// `text` in single quotes for a POSIX shell, its own quotes closed and
/// reopened around an escaped one.
fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    use crate::keys::{generate, KeyKind};

    fn home() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "promptly-authorized-keys-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn run(home: &Path, command: &str) -> (String, Option<i32>) {
        let out = Command::new("sh")
            .arg("-c")
            .arg(command)
            .env("HOME", home)
            .output()
            .unwrap();
        (
            String::from_utf8_lossy(&out.stdout).into_owned()
                + &String::from_utf8_lossy(&out.stderr),
            out.status.code(),
        )
    }

    fn mode(path: &Path) -> u32 {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn installs_once_with_owner_only_modes() {
        let home = home();
        let key = generate(KeyKind::Ed25519, "it's me@laptop").unwrap();
        let cmd = command(&key.public_openssh).unwrap();
        let (out, code) = run(&home, &cmd);
        assert_eq!(outcome(&out, code), Ok(true), "{out}");
        let file = home.join(".ssh/authorized_keys");
        assert_eq!(mode(&home.join(".ssh")), 0o700);
        assert_eq!(mode(&file), 0o600);
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            format!("{}\n", key.public_openssh)
        );

        // Again: already there, nothing added.
        let (out, code) = run(&home, &cmd);
        assert_eq!(outcome(&out, code), Ok(false), "{out}");
        assert_eq!(std::fs::read_to_string(&file).unwrap().lines().count(), 1);
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn keeps_existing_entries_and_modes_and_spots_a_key_behind_options() {
        let home = home();
        let ssh = home.join(".ssh");
        std::fs::create_dir_all(&ssh).unwrap();
        std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o750)).unwrap();
        let file = ssh.join("authorized_keys");
        let other = generate(KeyKind::Ed25519, "other").unwrap();
        // No newline at the end: the new key must not run into it.
        std::fs::write(&file, other.public_openssh.as_bytes()).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o640)).unwrap();

        let key = generate(KeyKind::EcdsaP256, "").unwrap();
        let (out, code) = run(&home, &command(&key.public_openssh).unwrap());
        assert_eq!(outcome(&out, code), Ok(true), "{out}");
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            format!("{}\n{}\n", other.public_openssh, key.public_openssh)
        );
        assert_eq!(mode(&ssh), 0o750, "an existing folder keeps its mode");
        assert_eq!(mode(&file), 0o640, "an existing file keeps its mode");

        // Listed with options in front and another comment: still there.
        let mut parts = key.public_openssh.split_whitespace();
        let bare = format!("{} {}", parts.next().unwrap(), parts.next().unwrap());
        std::fs::write(&file, format!("from=\"10.0.0.0/8\" {bare} old name\n")).unwrap();
        let (out, code) = run(&home, &command(&key.public_openssh).unwrap());
        assert_eq!(outcome(&out, code), Ok(false), "{out}");

        // Turned off with a #, or only quoted in another key's comment:
        // not there, so it is added.
        std::fs::write(
            &file,
            format!(
                "# {bare} disabled\n  #{bare}\n{} see {bare}\n",
                other.public_openssh
            ),
        )
        .unwrap();
        let (out, code) = run(&home, &command(&key.public_openssh).unwrap());
        assert_eq!(outcome(&out, code), Ok(true), "{out}");
        assert!(std::fs::read_to_string(&file)
            .unwrap()
            .ends_with(&format!("\n{}\n", key.public_openssh)));

        // Behind options whose quoted values hold spaces, escaped quotes
        // and words that look like key types: found, and nothing is added
        // that would get round the options.
        for options in [
            r#"command="echo ssh-rsa notice",restrict"#,
            r#"command="say \" ssh-ed25519 x",no-pty"#,
        ] {
            let line = format!("{options} {bare} restricted\n");
            std::fs::write(&file, &line).unwrap();
            let (out, code) = run(&home, &command(&key.public_openssh).unwrap());
            assert_eq!(outcome(&out, code), Ok(false), "{options}: {out}");
            assert_eq!(std::fs::read_to_string(&file).unwrap(), line);
        }
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn refuses_what_is_not_a_public_key_and_reports_failures() {
        assert!(command("ssh-ed25519 not-base64").is_err());
        assert!(command("-----BEGIN OPENSSH PRIVATE KEY-----").is_err());
        assert!(outcome("Permission denied", Some(1))
            .unwrap_err()
            .contains("Permission denied"));
        assert!(outcome("", None).is_err());
    }
}
