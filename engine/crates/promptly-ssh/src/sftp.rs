//! The vault on a server you already have: a [`Backend`] over SFTP, using
//! the same connect flow as a terminal session.
//!
//! The vault's writers never overwrite, so the one subtle call, `put_new`,
//! is a write to a temporary name followed by a rename, which SFTP refuses
//! when the target exists.

use std::sync::Arc;

use promptly_vault::{Backend, BackendError, Entry};
use russh_sftp::client::SftpSession;
use russh_sftp::protocol::{OpenFlags, StatusCode};
use tokio::io::AsyncWriteExt;

use crate::connect::{connect_handle, ConnectError, ConnectParams, ConnectStep, Prompter};
use crate::forward::Connection;
use crate::hostkey::{HostKeyInfo, HostKeyStatus, KnownHosts};

#[derive(Debug, thiserror::Error)]
pub enum SftpError {
    #[error("{0}")]
    Connect(#[from] ConnectError),
    #[error("the server does not offer SFTP: {0}")]
    NoSubsystem(String),
    #[error("sftp: {0}")]
    Sftp(#[from] russh_sftp::client::error::Error),
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

/// A prompter for unattended connections: the host key must already be
/// trusted and the credentials must be stored. Anything else fails with a
/// message that says what to do.
pub struct QuietPrompter;

impl Prompter for QuietPrompter {
    fn progress(&self, _step: ConnectStep) {}
    fn confirm_host_key(
        &self,
        _info: HostKeyInfo,
        _status: HostKeyStatus,
    ) -> crate::connect::BoxFuture<'_, bool> {
        Box::pin(async { false })
    }
    fn ask_secret(&self, _prompt: String) -> crate::connect::BoxFuture<'_, Option<String>> {
        Box::pin(async { None })
    }
    fn ask_keyboard_interactive(
        &self,
        _name: String,
        _instructions: String,
        _prompts: Vec<crate::connect::KeyboardPrompt>,
    ) -> crate::connect::BoxFuture<'_, Option<Vec<String>>> {
        Box::pin(async { None })
    }
}

pub struct SftpBackend {
    /// Keeps the connection open for as long as the backend lives.
    _connection: Connection,
    sftp: SftpSession,
    root: String,
}

fn is_status(e: &russh_sftp::client::error::Error, code: StatusCode) -> bool {
    matches!(e, russh_sftp::client::error::Error::Status(s) if s.status_code == code)
}

fn other(e: impl std::fmt::Display) -> BackendError {
    BackendError::Other(format!("sftp: {e}"))
}

impl SftpBackend {
    /// Connect and make sure `root` exists. `root` is relative to the
    /// login's home unless it starts with `/`.
    pub async fn connect(
        params: &ConnectParams,
        prompter: Arc<dyn Prompter>,
        known_hosts: Arc<dyn KnownHosts>,
        root: &str,
    ) -> Result<Self, SftpError> {
        let connection = connect_handle(params, prompter, known_hosts).await?;
        let channel = connection
            .handle()
            .channel_open_session()
            .await
            .map_err(ConnectError::from)?;
        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(|e| SftpError::NoSubsystem(e.to_string()))?;
        let sftp = SftpSession::new(channel.into_stream()).await?;
        let root = root.trim().trim_end_matches('/').to_string();
        let backend = Self {
            _connection: connection,
            sftp,
            root,
        };
        backend.ensure_dir(&backend.root).await?;
        Ok(backend)
    }

    /// [`connect`](Self::connect) from a plain thread.
    pub fn connect_blocking(
        params: &ConnectParams,
        prompter: Arc<dyn Prompter>,
        known_hosts: Arc<dyn KnownHosts>,
        root: &str,
    ) -> Result<Self, SftpError> {
        crate::runtime().block_on(Self::connect(params, prompter, known_hosts, root))
    }

    fn full(&self, path: &str) -> String {
        let path = path.trim_matches('/');
        if path.is_empty() {
            self.root.clone()
        } else if self.root.is_empty() {
            path.to_string()
        } else {
            format!("{}/{path}", self.root)
        }
    }

    /// Create a folder and its parents; existing ones are fine.
    async fn ensure_dir(&self, path: &str) -> Result<(), SftpError> {
        if path.is_empty() {
            return Ok(());
        }
        let mut built = String::new();
        for part in path.split('/') {
            if part.is_empty() {
                if built.is_empty() {
                    built.push('/');
                }
                continue;
            }
            if !built.is_empty() && !built.ends_with('/') {
                built.push('/');
            }
            built.push_str(part);
            match self.sftp.create_dir(built.clone()).await {
                Ok(()) => {}
                Err(e) if self.sftp.try_exists(built.clone()).await.unwrap_or(false) => {
                    let _ = e;
                }
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }
}

impl Backend for SftpBackend {
    fn list(&self, dir: &str) -> Result<Vec<Entry>, BackendError> {
        let full = self.full(dir);
        crate::runtime().block_on(async {
            match self.sftp.read_dir(full).await {
                Ok(read) => {
                    let mut out: Vec<Entry> = read
                        .filter(|e| {
                            let n = e.file_name();
                            !n.starts_with('.')
                        })
                        .map(|e| {
                            let m = e.metadata();
                            Entry {
                                name: e.file_name(),
                                size: m.size.unwrap_or(0),
                                is_dir: m.is_dir(),
                            }
                        })
                        .collect();
                    out.sort_by(|a, b| a.name.cmp(&b.name));
                    Ok(out)
                }
                Err(e) if is_status(&e, StatusCode::NoSuchFile) => Ok(Vec::new()),
                Err(e) => Err(other(e)),
            }
        })
    }

    fn get(&self, path: &str) -> Result<Vec<u8>, BackendError> {
        let full = self.full(path);
        crate::runtime().block_on(async {
            self.sftp.read(full).await.map_err(|e| {
                if is_status(&e, StatusCode::NoSuchFile) {
                    BackendError::NotFound(path.to_string())
                } else {
                    other(e)
                }
            })
        })
    }

    fn put_new(&self, path: &str, bytes: &[u8]) -> Result<(), BackendError> {
        let full = self.full(path);
        crate::runtime().block_on(async {
            if let Some((parent, _)) = full.rsplit_once('/') {
                self.ensure_dir(parent)
                    .await
                    .map_err(|e| other(format!("mkdir {parent}: {e}")))?;
            }
            if self.sftp.try_exists(full.clone()).await.map_err(other)? {
                return Err(BackendError::AlreadyExists(path.to_string()));
            }
            let (dir, name) = full.rsplit_once('/').unwrap_or(("", full.as_str()));
            let tmp = if dir.is_empty() {
                format!(".{name}.tmp-{}", std::process::id())
            } else {
                format!("{dir}/.{name}.tmp-{}", std::process::id())
            };
            // The crate's `write` opens without CREATE; open the file ourselves.
            let mut file = self
                .sftp
                .open_with_flags(
                    tmp.clone(),
                    OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
                )
                .await
                .map_err(|e| other(format!("create {tmp}: {e}")))?;
            file.write_all(bytes)
                .await
                .map_err(|e| other(format!("write {tmp}: {e}")))?;
            file.close()
                .await
                .map_err(|e| other(format!("close {tmp}: {e}")))?;
            // SFTP's rename refuses to replace an existing file, which is
            // exactly the "create new" we need.
            match self.sftp.rename(tmp.clone(), full.clone()).await {
                Ok(()) => Ok(()),
                Err(e) => {
                    let _ = self.sftp.remove_file(tmp).await;
                    if self.sftp.try_exists(full).await.unwrap_or(false) {
                        Err(BackendError::AlreadyExists(path.to_string()))
                    } else {
                        Err(other(e))
                    }
                }
            }
        })
    }

    fn delete(&self, path: &str) -> Result<(), BackendError> {
        let full = self.full(path);
        crate::runtime().block_on(async {
            match self.sftp.remove_file(full.clone()).await {
                Ok(()) => Ok(()),
                Err(e) if is_status(&e, StatusCode::NoSuchFile) => Ok(()),
                Err(e) => match self.sftp.remove_dir(full).await {
                    Ok(()) => Ok(()),
                    Err(e2) if is_status(&e2, StatusCode::NoSuchFile) => Ok(()),
                    Err(_) => Err(other(e)),
                },
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connect::AuthMethod;
    use crate::endpoint::Endpoint;
    use promptly_term::TermSize;
    use promptly_vault::{KdfParams, Vault};
    use std::sync::Mutex;

    /// A known-hosts store that trusts whatever it is shown, for tests.
    struct Trusting(Mutex<Vec<String>>);
    impl KnownHosts for Trusting {
        fn check(&self, _host: &str, _port: u16, _key: &russh::keys::PublicKey) -> HostKeyStatus {
            HostKeyStatus::Known
        }
        fn remember(
            &self,
            host: &str,
            _port: u16,
            _key: &russh::keys::PublicKey,
        ) -> std::io::Result<()> {
            self.0.lock().unwrap().push(host.to_string());
            Ok(())
        }
        fn known_algorithms(&self, _: &str, _: u16) -> Vec<russh::keys::Algorithm> {
            Vec::new()
        }
    }

    fn test_params() -> Option<ConnectParams> {
        let spec = std::env::var("PROMPTLY_TEST_SSH").ok()?;
        let (creds, hostport) = spec.split_once('@')?;
        let (user, pass) = creds.split_once(':')?;
        let endpoint = Endpoint::parse(&format!("{user}@{hostport}")).ok()?;
        Some(ConnectParams::new(
            endpoint,
            AuthMethod::Password {
                password: Some(pass.to_string()),
            },
            TermSize::default(),
        ))
    }

    #[test]
    fn sftp_backend_behaves_and_carries_a_vault() {
        let Some(params) = test_params() else {
            eprintln!("PROMPTLY_TEST_SSH not set; skipping");
            return;
        };
        let root = format!("promptly-sftp-test-{}", std::process::id());
        let b = SftpBackend::connect_blocking(
            &params,
            Arc::new(QuietPrompter),
            Arc::new(Trusting(Mutex::new(Vec::new()))),
            &root,
        )
        .expect("connect over sftp");

        assert!(b.list("").unwrap().is_empty());
        assert!(b.list("devices/nothing").unwrap().is_empty());
        b.put_new("vault.json", b"{}").unwrap();
        b.put_new("devices/aa/000001.seg", b"one").unwrap();
        b.put_new("devices/aa/000002.seg", b"two").unwrap();
        assert!(matches!(
            b.put_new("devices/aa/000001.seg", b"again"),
            Err(BackendError::AlreadyExists(_))
        ));
        assert_eq!(b.get("devices/aa/000001.seg").unwrap(), b"one");
        assert!(matches!(
            b.get("devices/aa/000009.seg"),
            Err(BackendError::NotFound(_))
        ));
        let root_entries = b.list("").unwrap();
        assert_eq!(
            root_entries
                .iter()
                .map(|e| (e.name.as_str(), e.is_dir))
                .collect::<Vec<_>>(),
            [("devices", true), ("vault.json", false)]
        );
        let aa = b.list("devices/aa").unwrap();
        assert_eq!(aa.len(), 2, "{aa:?}");
        assert_eq!(aa[1].size, 3);
        b.delete("devices/aa/000001.seg").unwrap();
        b.delete("devices/aa/000001.seg").unwrap();
        assert_eq!(b.list("devices/aa").unwrap().len(), 1);
        b.delete("devices/aa/000002.seg").unwrap();
        b.delete("devices/aa").unwrap();
        b.delete("devices").unwrap();
        b.delete("vault.json").unwrap();
        assert!(b.list("").unwrap().is_empty(), "{:?}", b.list(""));

        // A vault over it: create, push, and read back through a second connection.
        let device = promptly_vault::DeviceId::generate();
        let (vault, _code) =
            Vault::create(&b, device.clone(), "pw", KdfParams::fast_for_tests()).unwrap();
        let mut sync = promptly_vault::SyncState::default();
        let op = promptly_vault::Op::Put {
            col: promptly_vault::model::Collection::Hosts,
            id: "h1".into(),
            ts: promptly_vault::Timestamp(1, device.clone()),
            at: String::new(),
            fields: [("label".to_string(), serde_json::json!("web-1"))]
                .into_iter()
                .collect(),
        };
        vault.push(&mut sync, &[op]).unwrap();

        let b2 = SftpBackend::connect_blocking(
            &params,
            Arc::new(QuietPrompter),
            Arc::new(Trusting(Mutex::new(Vec::new()))),
            &root,
        )
        .unwrap();
        let other = promptly_vault::DeviceId::generate();
        let v2 = Vault::open(&b2, other.clone(), "pw").unwrap();
        let mut state = promptly_vault::State::new();
        let mut clock = promptly_vault::Clock::new(other);
        let mut sync2 = promptly_vault::SyncState::default();
        let report = v2.pull(&mut sync2, &mut state, &mut clock).unwrap();
        assert_eq!(report.files_applied, 1);
        assert_eq!(
            state.list(promptly_vault::model::Collection::Hosts)[0].1["label"],
            "web-1"
        );

        // Tidy up on the server.
        for d in b.list("devices").unwrap() {
            for f in b.list(&format!("devices/{}", d.name)).unwrap() {
                b.delete(&format!("devices/{}/{}", d.name, f.name)).unwrap();
            }
            b.delete(&format!("devices/{}", d.name)).unwrap();
        }
        b.delete("devices").unwrap();
        b.delete("vault.json").unwrap();
        b.delete("").unwrap();
    }
}
