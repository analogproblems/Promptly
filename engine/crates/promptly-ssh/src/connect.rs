//! The connect flow: resolve, connect, verify the host key, authenticate,
//! open a shell.

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use promptly_term::TermSize;
use russh::client::{self, AuthResult, KeyboardInteractiveAuthResponse};
use russh::keys::{self, PrivateKeyWithHashAlg, PublicKey};
use russh::{MethodKind, MethodSet};

use crate::endpoint::Endpoint;
use crate::hostkey::{HostKeyInfo, HostKeyStatus, KnownHosts};
use crate::transport::{SshReader, SshTransport};

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

#[derive(Debug, Clone)]
pub enum AuthMethod {
    /// A stored password, or ask when `None`.
    Password { password: Option<String> },
    /// A private key in OpenSSH, PEM or PuTTY form, with its passphrase if
    /// stored; otherwise the person is asked when the key is encrypted.
    Key {
        private_key: String,
        passphrase: Option<String>,
    },
    /// Keyboard-interactive only (two-factor servers).
    Interactive,
}

#[derive(Debug, Clone)]
pub struct ConnectParams {
    pub endpoint: Endpoint,
    pub auth: AuthMethod,
    pub term: String,
    pub size: TermSize,
    pub keepalive: Duration,
    pub timeout: Duration,
}

impl ConnectParams {
    pub fn new(endpoint: Endpoint, auth: AuthMethod, size: TermSize) -> Self {
        Self {
            endpoint,
            auth,
            term: "xterm-256color".into(),
            size,
            keepalive: Duration::from_secs(30),
            timeout: Duration::from_secs(20),
        }
    }
}

/// Progress shown inside the terminal area while connecting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectStep {
    Resolving,
    Connecting,
    VerifyingHostKey,
    Authenticating,
    OpeningShell,
    Connected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyboardPrompt {
    pub prompt: String,
    pub echo: bool,
}

/// The person, as seen by the connect flow.
pub trait Prompter: Send + Sync + 'static {
    fn progress(&self, step: ConnectStep);
    /// Trust this key? Called for unknown and changed keys only.
    fn confirm_host_key(&self, info: HostKeyInfo, status: HostKeyStatus) -> BoxFuture<'_, bool>;
    /// A password or key passphrase. `None` cancels the connection.
    fn ask_secret(&self, prompt: String) -> BoxFuture<'_, Option<String>>;
    /// Keyboard-interactive prompts. `None` cancels.
    fn ask_keyboard_interactive(
        &self,
        name: String,
        instructions: String,
        prompts: Vec<KeyboardPrompt>,
    ) -> BoxFuture<'_, Option<Vec<String>>>;
}

#[derive(Debug, thiserror::Error)]
pub enum ConnectError {
    #[error("could not find a server called {host}")]
    Resolve { host: String },
    #[error("could not reach {host} on port {port}: {reason}")]
    Connect {
        host: String,
        port: u16,
        reason: String,
    },
    #[error("gave up connecting to {host} after {seconds} seconds")]
    Timeout { host: String, seconds: u64 },
    #[error("the host key was not trusted")]
    HostKeyRejected,
    #[error("{0}")]
    AuthFailed(String),
    #[error("cancelled")]
    Cancelled,
    #[error("the private key could not be read: {0}")]
    BadKey(String),
    #[error("ssh error: {0}")]
    Ssh(#[from] russh::Error),
}

/// Handles the server's questions during the handshake.
pub struct Handler {
    prompter: Arc<dyn Prompter>,
    known_hosts: Arc<dyn KnownHosts>,
    host: String,
    port: u16,
}

impl client::Handler for Handler {
    type Error = ConnectError;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let key: PublicKey = match server_public_key {
            keys::PublicKeyOrCertificate::PublicKey { key, .. } => key.clone(),
            keys::PublicKeyOrCertificate::Certificate(cert) => {
                PublicKey::from(cert.public_key().clone())
            }
        };
        self.prompter.progress(ConnectStep::VerifyingHostKey);
        let status = self.known_hosts.check(&self.host, self.port, &key);
        if status == HostKeyStatus::Known {
            return Ok(true);
        }
        let info = HostKeyInfo::from_key(&self.host, self.port, &key);
        let trusted = self.prompter.confirm_host_key(info, status).await;
        if trusted {
            if let Err(e) = self.known_hosts.remember(&self.host, self.port, &key) {
                tracing::warn!("could not remember host key: {e}");
            }
        }
        Ok(trusted)
    }
}

/// Run the whole flow and return a transport plus its output reader.
pub async fn connect(
    params: ConnectParams,
    prompter: Arc<dyn Prompter>,
    known_hosts: Arc<dyn KnownHosts>,
) -> Result<(SshTransport, SshReader), ConnectError> {
    let host = params.endpoint.host.clone();
    let port = params.endpoint.port;

    prompter.progress(ConnectStep::Resolving);
    let addrs: Vec<std::net::SocketAddr> = tokio::net::lookup_host((host.as_str(), port))
        .await
        .map_err(|_| ConnectError::Resolve { host: host.clone() })?
        .collect();
    if addrs.is_empty() {
        return Err(ConnectError::Resolve { host });
    }

    prompter.progress(ConnectStep::Connecting);
    let config = Arc::new(client::Config {
        keepalive_interval: Some(params.keepalive),
        keepalive_max: 3,
        nodelay: true,
        ..client::Config::default()
    });
    let handler = Handler {
        prompter: prompter.clone(),
        known_hosts,
        host: host.clone(),
        port,
    };
    let connecting = client::connect(config, &addrs[..], handler);
    let mut handle = match tokio::time::timeout(params.timeout, connecting).await {
        Ok(Ok(h)) => h,
        Ok(Err(ConnectError::Ssh(russh::Error::UnknownKey))) => {
            return Err(ConnectError::HostKeyRejected)
        }
        Ok(Err(ConnectError::Ssh(russh::Error::IO(e)))) => {
            return Err(ConnectError::Connect {
                host,
                port,
                reason: friendly_io(&e),
            })
        }
        Ok(Err(e)) => return Err(e),
        Err(_) => {
            return Err(ConnectError::Timeout {
                host,
                seconds: params.timeout.as_secs(),
            })
        }
    };

    prompter.progress(ConnectStep::Authenticating);
    authenticate(&mut handle, &params, &prompter).await?;

    prompter.progress(ConnectStep::OpeningShell);
    let channel = handle.channel_open_session().await?;
    let (read_half, write_half) = channel.split();
    write_half
        .request_pty(
            true,
            &params.term,
            u32::from(params.size.cols),
            u32::from(params.size.rows),
            0,
            0,
            &[],
        )
        .await?;
    write_half.request_shell(true).await?;
    prompter.progress(ConnectStep::Connected);

    Ok(SshTransport::start(handle, read_half, write_half))
}

fn friendly_io(e: &io::Error) -> String {
    match e.kind() {
        io::ErrorKind::ConnectionRefused => "nothing is listening there".into(),
        io::ErrorKind::TimedOut => "the connection timed out".into(),
        io::ErrorKind::NetworkUnreachable | io::ErrorKind::HostUnreachable => {
            "the network cannot reach it".into()
        }
        _ => e.to_string(),
    }
}

async fn authenticate(
    handle: &mut client::Handle<Handler>,
    params: &ConnectParams,
    prompter: &Arc<dyn Prompter>,
) -> Result<(), ConnectError> {
    let user = params.endpoint.user.clone();
    let where_ = format!("{}@{}", user, params.endpoint.host);

    match &params.auth {
        AuthMethod::Key {
            private_key,
            passphrase,
        } => {
            let key = load_key(private_key, passphrase.as_deref(), prompter).await?;
            let hash = handle.best_supported_rsa_hash().await?.flatten();
            let result = handle
                .authenticate_publickey(
                    user.clone(),
                    PrivateKeyWithHashAlg::new(Arc::new(key), hash),
                )
                .await?;
            match result {
                AuthResult::Success => Ok(()),
                AuthResult::Failure {
                    remaining_methods, ..
                } => {
                    if offers(&remaining_methods, MethodKind::KeyboardInteractive) {
                        keyboard_interactive(handle, &user, prompter).await
                    } else if offers(&remaining_methods, MethodKind::Password) {
                        password(handle, &user, &where_, None, prompter).await
                    } else {
                        Err(ConnectError::AuthFailed(
                            "the server did not accept the key".into(),
                        ))
                    }
                }
            }
        }
        AuthMethod::Password { password: stored } => {
            password(handle, &user, &where_, stored.clone(), prompter).await
        }
        AuthMethod::Interactive => keyboard_interactive(handle, &user, prompter).await,
    }
}

fn offers(methods: &MethodSet, kind: MethodKind) -> bool {
    methods.contains(&kind)
}

async fn password(
    handle: &mut client::Handle<Handler>,
    user: &str,
    where_: &str,
    stored: Option<String>,
    prompter: &Arc<dyn Prompter>,
) -> Result<(), ConnectError> {
    let mut attempt = 0;
    let mut password = stored;
    loop {
        let pw = match password.take() {
            Some(p) => p,
            None => prompter
                .ask_secret(format!("Password for {where_}"))
                .await
                .ok_or(ConnectError::Cancelled)?,
        };
        match handle.authenticate_password(user.to_string(), pw).await? {
            AuthResult::Success => return Ok(()),
            AuthResult::Failure {
                remaining_methods,
                partial_success,
            } => {
                if partial_success && offers(&remaining_methods, MethodKind::KeyboardInteractive) {
                    return keyboard_interactive(handle, user, prompter).await;
                }
                attempt += 1;
                if attempt >= 3 {
                    return Err(ConnectError::AuthFailed(
                        "the server rejected the password three times".into(),
                    ));
                }
                if !offers(&remaining_methods, MethodKind::Password) {
                    return Err(ConnectError::AuthFailed(
                        "the server does not accept passwords for this user".into(),
                    ));
                }
                // Ask again; a stored password that failed is not reused.
            }
        }
    }
}

async fn keyboard_interactive(
    handle: &mut client::Handle<Handler>,
    user: &str,
    prompter: &Arc<dyn Prompter>,
) -> Result<(), ConnectError> {
    let mut response = handle
        .authenticate_keyboard_interactive_start(user.to_string(), None)
        .await?;
    loop {
        match response {
            KeyboardInteractiveAuthResponse::Success => return Ok(()),
            KeyboardInteractiveAuthResponse::Failure { .. } => {
                return Err(ConnectError::AuthFailed(
                    "the server rejected the answers".into(),
                ))
            }
            KeyboardInteractiveAuthResponse::InfoRequest {
                name,
                instructions,
                prompts,
            } => {
                let answers = if prompts.is_empty() {
                    Vec::new()
                } else {
                    prompter
                        .ask_keyboard_interactive(
                            name,
                            instructions,
                            prompts
                                .into_iter()
                                .map(|p| KeyboardPrompt {
                                    prompt: p.prompt,
                                    echo: p.echo,
                                })
                                .collect(),
                        )
                        .await
                        .ok_or(ConnectError::Cancelled)?
                };
                response = handle
                    .authenticate_keyboard_interactive_respond(answers)
                    .await?;
            }
        }
    }
}

async fn load_key(
    private_key: &str,
    passphrase: Option<&str>,
    prompter: &Arc<dyn Prompter>,
) -> Result<keys::PrivateKey, ConnectError> {
    let mut passphrase = passphrase.map(str::to_string);
    for _ in 0..3 {
        match keys::decode_secret_key(private_key, passphrase.as_deref()) {
            Ok(key) => return Ok(key),
            Err(keys::Error::KeyIsEncrypted) => {
                passphrase = Some(
                    prompter
                        .ask_secret("Passphrase for the private key".into())
                        .await
                        .ok_or(ConnectError::Cancelled)?,
                );
            }
            Err(e) if passphrase.is_some() && is_wrong_passphrase(&e) => {
                passphrase = Some(
                    prompter
                        .ask_secret("Wrong passphrase. Passphrase for the private key".into())
                        .await
                        .ok_or(ConnectError::Cancelled)?,
                );
            }
            Err(e) => return Err(ConnectError::BadKey(e.to_string())),
        }
    }
    Err(ConnectError::BadKey(
        "the passphrase was wrong three times".into(),
    ))
}

fn is_wrong_passphrase(e: &keys::Error) -> bool {
    matches!(
        e,
        keys::Error::KeyIsCorrupt | keys::Error::SshKey(_) | keys::Error::Decode(_)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hostkey::FileKnownHosts;
    use promptly_session::{pump, Session, SessionEvent, SessionKind};
    use promptly_term::Palette;
    use std::sync::Mutex;
    use std::time::Instant;

    /// Answers like a person who trusts the test server and knows the password.
    struct TestPrompter {
        password: String,
        steps: Mutex<Vec<ConnectStep>>,
        host_key_asked: Mutex<Option<HostKeyStatus>>,
    }

    impl Prompter for TestPrompter {
        fn progress(&self, step: ConnectStep) {
            self.steps.lock().unwrap().push(step);
        }
        fn confirm_host_key(
            &self,
            info: HostKeyInfo,
            status: HostKeyStatus,
        ) -> BoxFuture<'_, bool> {
            assert!(info.fingerprint.starts_with("SHA256:"));
            *self.host_key_asked.lock().unwrap() = Some(status);
            Box::pin(async { true })
        }
        fn ask_secret(&self, _prompt: String) -> BoxFuture<'_, Option<String>> {
            let p = self.password.clone();
            Box::pin(async move { Some(p) })
        }
        fn ask_keyboard_interactive(
            &self,
            _name: String,
            _instructions: String,
            prompts: Vec<KeyboardPrompt>,
        ) -> BoxFuture<'_, Option<Vec<String>>> {
            let p = self.password.clone();
            Box::pin(async move { Some(prompts.iter().map(|_| p.clone()).collect()) })
        }
    }

    /// Set PROMPTLY_TEST_SSH=user:password@host:port to run against a real server.
    fn test_server() -> Option<(Endpoint, String)> {
        let spec = std::env::var("PROMPTLY_TEST_SSH").ok()?;
        let (cred, hostport) = spec.rsplit_once('@')?;
        let (user, password) = cred.split_once(':')?;
        let endpoint = Endpoint::parse(&format!("{user}@{hostport}")).ok()?;
        Some((endpoint, password.to_string()))
    }

    fn run_shell(
        label: &str,
        auth: AuthMethod,
        endpoint: Endpoint,
        password: &str,
    ) -> (String, Option<HostKeyStatus>) {
        let dir =
            std::env::temp_dir().join(format!("promptly-ssh-test-{}-{label}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let known = Arc::new(FileKnownHosts::new(vec![], dir.join("known_hosts")));
        let prompter = Arc::new(TestPrompter {
            password: password.to_string(),
            steps: Mutex::new(vec![]),
            host_key_asked: Mutex::new(None),
        });
        let size = TermSize::new(60, 8);
        let params = ConnectParams::new(endpoint, auth, size);
        let (transport, reader) = crate::runtime()
            .block_on(connect(params, prompter.clone(), known))
            .expect("connect");
        let session = Arc::new(Session::new(
            SessionKind::Ssh {
                host: "test".into(),
            },
            size,
            Palette::promptly_dark(),
            Box::new(transport),
        ));
        let (tx, rx) = std::sync::mpsc::channel();
        let _h = pump(session.clone(), Box::new(reader), move |e| {
            let _ = tx.send(e);
        });
        // Resize before asking the remote shell what size it sees.
        session
            .resize(TermSize::new(100, 30), |f| {
                assert_eq!((f.cols, f.rows), (100, 30))
            })
            .unwrap();
        session
            .write(b"sleep 0.3; stty size; echo ssh-$((6*7))-ok; exit 3\n")
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut code = None;
        while Instant::now() < deadline {
            if let Ok(SessionEvent::Exited { code: c }) =
                rx.recv_timeout(Duration::from_millis(300))
            {
                code = Some(c);
                break;
            }
        }
        assert_eq!(code, Some(Some(3)), "shell should exit with 3");
        let steps = prompter.steps.lock().unwrap().clone();
        assert_eq!(
            steps.last(),
            Some(&ConnectStep::Connected),
            "steps: {steps:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
        let asked = *prompter.host_key_asked.lock().unwrap();
        (session.screen_text(), asked)
    }

    #[test]
    fn password_login_runs_a_shell() {
        let Some((endpoint, password)) = test_server() else {
            eprintln!("PROMPTLY_TEST_SSH not set; skipping");
            return;
        };
        let (text, asked) = run_shell(
            "password",
            AuthMethod::Password { password: None },
            endpoint,
            &password,
        );
        assert!(text.contains("ssh-42-ok"), "screen:\n{text}");
        assert!(
            text.contains("30 100"),
            "the remote pty should see the new size; screen:\n{text}"
        );
        assert_eq!(
            asked,
            Some(HostKeyStatus::Unknown),
            "a fresh store asks about the host key"
        );
    }

    #[test]
    fn keyboard_interactive_login_runs_a_shell() {
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        let (text, _) = run_shell("interactive", AuthMethod::Interactive, endpoint, &password);
        assert!(text.contains("ssh-42-ok"), "screen:\n{text}");
    }

    #[test]
    fn key_login_runs_a_shell() {
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        let Ok(path) = std::env::var("PROMPTLY_TEST_SSH_KEY") else {
            return;
        };
        let pem = std::fs::read_to_string(path).unwrap();
        let (text, _) = run_shell(
            "key",
            AuthMethod::Key {
                private_key: pem,
                passphrase: None,
            },
            endpoint,
            &password,
        );
        assert!(text.contains("ssh-42-ok"), "screen:\n{text}");
    }

    #[test]
    fn unreachable_port_is_a_plain_error() {
        let endpoint = Endpoint::parse("nobody@127.0.0.1:1").unwrap();
        let known = Arc::new(FileKnownHosts::new(
            vec![],
            std::env::temp_dir().join("promptly-none"),
        ));
        let prompter = Arc::new(TestPrompter {
            password: String::new(),
            steps: Mutex::new(vec![]),
            host_key_asked: Mutex::new(None),
        });
        let params = ConnectParams::new(endpoint, AuthMethod::Interactive, TermSize::default());
        let err = crate::runtime()
            .block_on(connect(params, prompter, known))
            .err()
            .unwrap();
        let msg = err.to_string();
        assert!(msg.contains("could not reach 127.0.0.1 on port 1"), "{msg}");
    }
}
