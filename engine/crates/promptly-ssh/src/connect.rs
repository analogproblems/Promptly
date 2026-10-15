//! The connect flow: resolve, connect, verify the host key, authenticate,
//! open a shell.

use std::collections::HashMap;
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use promptly_term::TermSize;
use russh::client::{self, AuthResult, ChannelOpenHandle, KeyboardInteractiveAuthResponse, Msg};
use russh::keys::{self, PrivateKeyWithHashAlg, PublicKey};
use russh::{Channel, ChannelOpenFailure, MethodKind, MethodSet};
use tokio::net::TcpStream;

use crate::endpoint::Endpoint;
use crate::forward::{Connection, ForwardSpec};
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
    /// Whatever keys the running SSH agent holds (`SSH_AUTH_SOCK`), then
    /// the server's other methods with prompts.
    Agent,
}

#[derive(Debug, Clone)]
pub struct ConnectParams {
    pub endpoint: Endpoint,
    pub auth: AuthMethod,
    pub term: String,
    pub size: TermSize,
    pub keepalive: Duration,
    pub timeout: Duration,
    /// Connect through this host first (ProxyJump), which may itself have
    /// a jump host.
    pub jump: Option<Box<ConnectParams>>,
    /// Run this instead of the login shell; the session ends when it does.
    pub command: Option<String>,
    /// Typed into the shell once it is open, as if at the keyboard. Include
    /// the trailing newline to run it.
    pub startup_input: Option<String>,
    /// Environment variables to ask the server to set. Servers only accept
    /// the names in their `AcceptEnv`, so these may be ignored.
    pub env: Vec<(String, String)>,
    /// Let programs on the server use the SSH agent on this device.
    pub agent_forward: bool,
    /// Port forwards to set up; those marked `auto` start on connect.
    pub forwards: Vec<ForwardSpec>,
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
            jump: None,
            command: None,
            startup_input: None,
            env: Vec::new(),
            agent_forward: false,
            forwards: Vec::new(),
        }
    }

    /// The command that attaches to (or starts) the tmux session Promptly
    /// keeps on the server, falling back to a plain login shell where tmux
    /// is not installed.
    pub fn persistent_command() -> String {
        "tmux new-session -A -s promptly 2>/dev/null || exec \"${SHELL:-/bin/sh}\" -l".to_string()
    }
}

/// Progress shown inside the terminal area while connecting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectStep {
    /// Connecting to the jump host first; its own steps are folded into
    /// this one.
    JumpHost,
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
    #[error("jump host {host}: {source}")]
    Jump {
        host: String,
        #[source]
        source: Box<ConnectError>,
    },
    #[error("{via} could not open a tunnel to {host}:{port}: {reason}")]
    Tunnel {
        via: String,
        host: String,
        port: u16,
        reason: String,
    },
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

/// Handles the server's questions during the handshake, and the channels
/// it opens later for remote forwards and agent forwarding.
pub struct Handler {
    prompter: Arc<dyn Prompter>,
    known_hosts: Arc<dyn KnownHosts>,
    host: String,
    port: u16,
    remote_targets: Arc<Mutex<HashMap<u32, (String, u16)>>>,
    agent_forward: bool,
}

impl client::Handler for Handler {
    type Error = ConnectError;

    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: Channel<Msg>,
        _connected_address: &str,
        connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: ChannelOpenHandle,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        let target = self
            .remote_targets
            .lock()
            .unwrap()
            .get(&connected_port)
            .cloned();
        let Some((host, port)) = target else {
            reply
                .reject(ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return Ok(());
        };
        reply.accept().await;
        crate::runtime().spawn(async move {
            match TcpStream::connect((host.as_str(), port)).await {
                Ok(tcp) => crate::forward::pipe(tcp, channel).await,
                Err(e) => {
                    tracing::info!("remote forward to {host}:{port} failed: {e}");
                    let _ = channel.close().await;
                }
            }
        });
        Ok(())
    }

    async fn server_channel_open_agent_forward(
        &mut self,
        channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        let Some(address) = agent_address().filter(|_| self.agent_forward) else {
            reply
                .reject(ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return Ok(());
        };
        reply.accept().await;
        crate::runtime().spawn(async move {
            forward_agent(address, channel).await;
        });
        Ok(())
    }

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
    let connection = Arc::new(connect_handle(&params, prompter.clone(), known_hosts).await?);
    for spec in &params.forwards {
        connection.add_forward(spec.clone()).await;
    }

    prompter.progress(ConnectStep::OpeningShell);
    let channel = connection.handle().channel_open_session().await?;
    let (read_half, write_half) = channel.split();
    for (name, value) in &params.env {
        let _ = write_half.set_env(false, name.clone(), value.clone()).await;
    }
    if params.agent_forward {
        let _ = write_half.agent_forward(false).await;
    }
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
    match &params.command {
        Some(command) => write_half.exec(true, command.as_bytes().to_vec()).await?,
        None => write_half.request_shell(true).await?,
    }
    if let Some(input) = &params.startup_input {
        write_half.data(input.as_bytes()).await?;
    }
    prompter.progress(ConnectStep::Connected);

    Ok(SshTransport::start(connection, read_half, write_half))
}

/// Resolve, connect, verify the host key and authenticate: everything up to
/// an open session, for a shell or for SFTP. With a jump host, that host is
/// connected first and the session runs through a tunnel it opens.
pub async fn connect_handle(
    params: &ConnectParams,
    prompter: Arc<dyn Prompter>,
    known_hosts: Arc<dyn KnownHosts>,
) -> Result<Connection, ConnectError> {
    let host = params.endpoint.host.clone();
    let port = params.endpoint.port;

    let config = Arc::new(client::Config {
        keepalive_interval: Some(params.keepalive),
        keepalive_max: 3,
        nodelay: true,
        ..client::Config::default()
    });
    let remote_targets = Arc::new(Mutex::new(HashMap::new()));
    let handler = Handler {
        prompter: prompter.clone(),
        known_hosts: known_hosts.clone(),
        host: host.clone(),
        port,
        remote_targets: remote_targets.clone(),
        agent_forward: params.agent_forward,
    };

    // A jump chain gets more time: every hop has its own handshake.
    let timeout = if params.jump.is_some() {
        params.timeout * 2
    } else {
        params.timeout
    };
    let opening = open_session(params, config, handler, prompter.clone(), known_hosts);
    let (mut handle, hops) = match tokio::time::timeout(timeout, opening).await {
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
                seconds: timeout.as_secs(),
            })
        }
    };

    prompter.progress(ConnectStep::Authenticating);
    authenticate(&mut handle, params, &prompter).await?;
    Ok(Connection::new(handle, hops, remote_targets))
}

/// The transport-level part of connecting: a TCP connection, or a tunnel
/// through the jump host, with the SSH handshake run over it.
async fn open_session(
    params: &ConnectParams,
    config: Arc<client::Config>,
    handler: Handler,
    prompter: Arc<dyn Prompter>,
    known_hosts: Arc<dyn KnownHosts>,
) -> Result<(client::Handle<Handler>, Vec<Arc<client::Handle<Handler>>>), ConnectError> {
    let host = params.endpoint.host.clone();
    let port = params.endpoint.port;

    if let Some(jump) = &params.jump {
        prompter.progress(ConnectStep::JumpHost);
        let hop_prompter: Arc<dyn Prompter> = Arc::new(HopPrompter(prompter.clone()));
        let hop = Box::pin(connect_handle(jump, hop_prompter, known_hosts))
            .await
            .map_err(|e| ConnectError::Jump {
                host: jump.endpoint.host.clone(),
                source: Box::new(e),
            })?;
        prompter.progress(ConnectStep::Connecting);
        let channel = hop
            .handle()
            .channel_open_direct_tcpip(host.clone(), u32::from(port), "127.0.0.1", 0)
            .await
            .map_err(|e| ConnectError::Tunnel {
                via: jump.endpoint.host.clone(),
                host: host.clone(),
                port,
                reason: match e {
                    russh::Error::ChannelOpenFailure(_) => "the jump host refused".into(),
                    other => other.to_string(),
                },
            })?;
        let handle = client::connect_stream(config, channel.into_stream(), handler).await?;
        return Ok((handle, hop.into_handles()));
    }

    prompter.progress(ConnectStep::Resolving);
    let addrs: Vec<std::net::SocketAddr> = tokio::net::lookup_host((host.as_str(), port))
        .await
        .map_err(|_| ConnectError::Resolve { host: host.clone() })?
        .collect();
    if addrs.is_empty() {
        return Err(ConnectError::Resolve { host });
    }

    prompter.progress(ConnectStep::Connecting);
    let stream = TcpStream::connect(&addrs[..])
        .await
        .map_err(|e| ConnectError::Connect {
            host: host.clone(),
            port,
            reason: friendly_io(&e),
        })?;
    let _ = stream.set_nodelay(true);
    let handle = client::connect_stream(config, stream, handler).await?;
    Ok((handle, Vec::new()))
}

/// The prompter a jump host sees: its progress folds into the one
/// "jump host" step, while its questions (an unknown key, a password) reach
/// the person as usual.
struct HopPrompter(Arc<dyn Prompter>);

impl Prompter for HopPrompter {
    fn progress(&self, step: ConnectStep) {
        if !matches!(step, ConnectStep::OpeningShell | ConnectStep::Connected) {
            self.0.progress(ConnectStep::JumpHost);
        }
    }
    fn confirm_host_key(&self, info: HostKeyInfo, status: HostKeyStatus) -> BoxFuture<'_, bool> {
        self.0.confirm_host_key(info, status)
    }
    fn ask_secret(&self, prompt: String) -> BoxFuture<'_, Option<String>> {
        self.0.ask_secret(prompt)
    }
    fn ask_keyboard_interactive(
        &self,
        name: String,
        instructions: String,
        prompts: Vec<KeyboardPrompt>,
    ) -> BoxFuture<'_, Option<Vec<String>>> {
        self.0.ask_keyboard_interactive(name, instructions, prompts)
    }
}

/// A connection to the SSH agent on this device, whatever it runs over.
type AgentStream = Box<dyn russh::keys::agent::client::AgentStream + Send + Unpin>;

/// Where the agent listens. `SSH_AUTH_SOCK` names a Unix socket on Linux
/// and macOS. On Windows the OpenSSH agent listens on a named pipe, so the
/// variable only counts when it names one: Git Bash and MSYS set it to a
/// Cygwin-style socket path this process cannot open.
fn agent_address() -> Option<String> {
    let env = std::env::var("SSH_AUTH_SOCK")
        .ok()
        .filter(|s| !s.is_empty());
    if cfg!(windows) {
        Some(
            env.filter(|s| s.starts_with(r"\\.\pipe\"))
                .unwrap_or_else(|| r"\\.\pipe\openssh-ssh-agent".to_string()),
        )
    } else {
        env
    }
}

/// Open the agent socket `SSH_AUTH_SOCK` names.
#[cfg(unix)]
async fn open_agent(address: &str) -> io::Result<AgentStream> {
    Ok(Box::new(tokio::net::UnixStream::connect(address).await?))
}

/// Open Windows' own OpenSSH agent (the "OpenSSH Authentication Agent"
/// service) on its named pipe, else PuTTY's Pageant.
#[cfg(windows)]
async fn open_agent(address: &str) -> io::Result<AgentStream> {
    use russh::keys::agent::client::AgentClient;
    match AgentClient::connect_named_pipe(address).await {
        Ok(agent) => return Ok(agent.into_inner()),
        Err(e) => tracing::debug!("no OpenSSH agent at {address}: {e}"),
    }
    match AgentClient::connect_pageant().await {
        Ok(agent) => Ok(agent.into_inner()),
        Err(e) => Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("no OpenSSH agent at {address} and no Pageant: {e}"),
        )),
    }
}

#[cfg(not(any(unix, windows)))]
async fn open_agent(_address: &str) -> io::Result<AgentStream> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "SSH agents are not supported on this platform yet",
    ))
}

/// Join an agent-forwarding channel from the server to the agent on this
/// device.
async fn forward_agent(address: String, channel: Channel<Msg>) {
    match open_agent(&address).await {
        Ok(mut agent) => {
            let mut stream = channel.into_stream();
            let _ = tokio::io::copy_bidirectional(&mut agent, &mut stream).await;
        }
        Err(e) => {
            tracing::info!("agent forwarding: could not open {address}: {e}");
            let _ = channel.close().await;
        }
    }
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
        AuthMethod::Agent => {
            let remaining = match agent_auth(handle, &user).await {
                Ok(None) => return Ok(()),
                Ok(Some(remaining)) => remaining,
                Err(e) => {
                    tracing::info!("agent authentication unavailable: {e}");
                    MethodSet::empty()
                }
            };
            if offers(&remaining, MethodKind::KeyboardInteractive) {
                keyboard_interactive(handle, &user, prompter).await
            } else if offers(&remaining, MethodKind::Password) || remaining.is_empty() {
                password(handle, &user, &where_, None, prompter).await
            } else {
                Err(ConnectError::AuthFailed(
                    "no key in the agent was accepted".into(),
                ))
            }
        }
    }
}

/// Try every identity the agent holds. `Ok(None)` means one was accepted;
/// `Ok(Some(methods))` means none was, and these are what the server still
/// offers.
async fn agent_auth(
    handle: &mut client::Handle<Handler>,
    user: &str,
) -> Result<Option<MethodSet>, ConnectError> {
    use russh::keys::agent::client::AgentClient;
    let address = agent_address()
        .ok_or_else(|| ConnectError::AuthFailed("no SSH agent: SSH_AUTH_SOCK is not set".into()))?;
    let stream = open_agent(&address)
        .await
        .map_err(|e| ConnectError::AuthFailed(format!("no SSH agent: {e}")))?;
    let mut agent = AgentClient::connect(stream);
    let identities = agent
        .request_identities()
        .await
        .map_err(|e| ConnectError::AuthFailed(format!("the SSH agent did not answer: {e}")))?;
    if identities.is_empty() {
        return Err(ConnectError::AuthFailed(
            "the SSH agent holds no keys".into(),
        ));
    }
    let hash = handle.best_supported_rsa_hash().await?.flatten();
    let mut remaining = MethodSet::empty();
    for identity in identities {
        match handle
            .authenticate_publickey_with(
                user.to_string(),
                identity.public_key().into_owned(),
                hash,
                &mut agent,
            )
            .await
            .map_err(|e| ConnectError::AuthFailed(format!("the SSH agent could not sign: {e}")))?
        {
            AuthResult::Success => return Ok(None),
            AuthResult::Failure {
                remaining_methods, ..
            } => remaining = remaining_methods,
        }
    }
    Ok(Some(remaining))
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
    use promptly_session::{pump, Session, SessionEvent, SessionKind, Transport};
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
        let params = ConnectParams::new(endpoint, auth, TermSize::new(60, 8));
        let (text, asked, _) = run_shell_with(label, params, password, None);
        (text, asked)
    }

    /// Connect with `params`, run `input` (or a size check) in the shell
    /// until it exits, and return the screen, whether the host key was
    /// asked about, and the steps reported.
    fn run_shell_with(
        label: &str,
        params: ConnectParams,
        password: &str,
        input: Option<&str>,
    ) -> (String, Option<HostKeyStatus>, Vec<ConnectStep>) {
        let (transport, reader, prompter) = connect_only(label, params, password);
        let size = TermSize::new(60, 8);
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
        if let Some(input) = input {
            std::thread::sleep(Duration::from_secs(1));
            session.write(input.as_bytes()).unwrap();
        } else {
            session
                .write(b"sleep 0.3; stty size; echo ssh-$((6*7))-ok; exit 3\n")
                .unwrap();
        }
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
        if input.is_none() {
            assert_eq!(code, Some(Some(3)), "shell should exit with 3");
        } else {
            assert!(code.is_some(), "the program should exit");
        }
        let steps = prompter.steps.lock().unwrap().clone();
        assert_eq!(
            steps.last(),
            Some(&ConnectStep::Connected),
            "steps: {steps:?}"
        );
        let asked = *prompter.host_key_asked.lock().unwrap();
        (session.screen_text(), asked, steps)
    }

    /// Connect and hand back the transport, for tests that use the
    /// connection rather than the shell.
    fn connect_only(
        label: &str,
        params: ConnectParams,
        password: &str,
    ) -> (SshTransport, SshReader, Arc<TestPrompter>) {
        let dir =
            std::env::temp_dir().join(format!("promptly-ssh-test-{}-{label}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let known = Arc::new(FileKnownHosts::new(vec![], dir.join("known_hosts")));
        let prompter = Arc::new(TestPrompter {
            password: password.to_string(),
            steps: Mutex::new(vec![]),
            host_key_asked: Mutex::new(None),
        });
        let (transport, reader) = crate::runtime()
            .block_on(connect(params, prompter.clone(), known))
            .expect("connect");
        let _ = std::fs::remove_dir_all(&dir);
        (transport, reader, prompter)
    }

    /// Read the first bytes a server sends on a fresh connection.
    fn banner_from(port: u16) -> String {
        use std::io::Read;
        let mut tcp = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut buf = [0u8; 64];
        let n = tcp.read(&mut buf).unwrap_or(0);
        String::from_utf8_lossy(&buf[..n]).into_owned()
    }

    fn forward(kind: crate::forward::ForwardKind, target_port: u16) -> ForwardSpec {
        ForwardSpec {
            kind,
            bind_host: String::new(),
            bind_port: 0,
            target_host: "127.0.0.1".into(),
            target_port,
            auto: true,
        }
    }

    #[test]
    fn jump_host_runs_a_shell() {
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        // The test server jumps through itself: a real tunnel, one box.
        let mut params = ConnectParams::new(
            endpoint.clone(),
            AuthMethod::Password {
                password: Some(password.clone()),
            },
            TermSize::new(60, 8),
        );
        params.jump = Some(Box::new(ConnectParams::new(
            endpoint,
            AuthMethod::Password {
                password: Some(password.clone()),
            },
            TermSize::new(60, 8),
        )));
        let (text, _, steps) = run_shell_with("jump", params, &password, None);
        assert!(text.contains("ssh-42-ok"), "screen:\n{text}");
        assert_eq!(steps.first(), Some(&ConnectStep::JumpHost), "{steps:?}");
        assert!(
            !steps.contains(&ConnectStep::Resolving),
            "the target is reached through the tunnel, not resolved here: {steps:?}"
        );
    }

    #[test]
    fn persistent_command_attaches_tmux() {
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        let mut params = ConnectParams::new(
            endpoint,
            AuthMethod::Password {
                password: Some(password.clone()),
            },
            TermSize::new(60, 8),
        );
        params.command = Some(ConnectParams::persistent_command());
        // tmux restores the screen when it ends, so the proof goes to a
        // file; the test server is this machine.
        let marker = std::env::temp_dir().join(format!("promptly-tmux-{}", std::process::id()));
        let _ = std::fs::remove_file(&marker);
        let input = format!(
            "echo inside-${{TMUX:+tmux}}-ok > {}; exit\n",
            marker.display()
        );
        let (text, _, _) = run_shell_with("tmux", params, &password, Some(&input));
        assert!(
            text.contains("[exited]"),
            "tmux should have run; screen:\n{text}"
        );
        let proof = std::fs::read_to_string(&marker).unwrap_or_default();
        let _ = std::fs::remove_file(&marker);
        assert!(proof.contains("inside-tmux-ok"), "marker: {proof:?}");
    }

    #[test]
    fn startup_input_runs_in_the_shell() {
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        let mut params = ConnectParams::new(
            endpoint,
            AuthMethod::Password {
                password: Some(password.clone()),
            },
            TermSize::new(60, 8),
        );
        params.startup_input = Some("echo started-$((40+2))\n".into());
        let (text, _, _) = run_shell_with("startup", params, &password, Some("exit\n"));
        assert!(text.contains("started-42"), "screen:\n{text}");
    }

    #[test]
    fn local_forward_reaches_the_server() {
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        let server_port = endpoint.port;
        let mut params = ConnectParams::new(
            endpoint,
            AuthMethod::Password {
                password: Some(password.clone()),
            },
            TermSize::new(60, 8),
        );
        params.forwards = vec![forward(crate::forward::ForwardKind::Local, server_port)];
        let (mut transport, _reader, _) = connect_only("local-forward", params, &password);
        let status = transport.connection().forwards();
        assert!(status[0].active, "{:?}", status[0].error);
        assert_ne!(status[0].bound_port, 0);
        assert!(banner_from(status[0].bound_port).starts_with("SSH-2.0"));

        // Stopped forwards stop listening.
        crate::runtime().block_on(transport.connection().stop_forward(0));
        assert!(std::net::TcpStream::connect(("127.0.0.1", status[0].bound_port)).is_err());
        transport.close();
    }

    #[test]
    fn remote_forward_reaches_this_device() {
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        let server_port = endpoint.port;
        let mut params = ConnectParams::new(
            endpoint,
            AuthMethod::Password {
                password: Some(password.clone()),
            },
            TermSize::new(60, 8),
        );
        params.forwards = vec![forward(crate::forward::ForwardKind::Remote, server_port)];
        let (mut transport, _reader, _) = connect_only("remote-forward", params, &password);
        let status = transport.connection().forwards();
        assert!(status[0].active, "{:?}", status[0].error);
        // The server is this machine, so its listener is reachable here.
        assert!(banner_from(status[0].bound_port).starts_with("SSH-2.0"));
        transport.close();
    }

    #[test]
    fn dynamic_forward_speaks_socks5() {
        use std::io::{Read, Write};
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        let server_port = endpoint.port;
        let mut params = ConnectParams::new(
            endpoint,
            AuthMethod::Password {
                password: Some(password.clone()),
            },
            TermSize::new(60, 8),
        );
        params.forwards = vec![forward(crate::forward::ForwardKind::Dynamic, 0)];
        let (mut transport, _reader, _) = connect_only("socks", params, &password);
        let status = transport.connection().forwards();
        assert!(status[0].active, "{:?}", status[0].error);

        let mut tcp = std::net::TcpStream::connect(("127.0.0.1", status[0].bound_port)).unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        tcp.write_all(&[5, 1, 0]).unwrap();
        let mut reply = [0u8; 2];
        tcp.read_exact(&mut reply).unwrap();
        assert_eq!(reply, [5, 0]);
        let [hi, lo] = server_port.to_be_bytes();
        tcp.write_all(&[5, 1, 0, 1, 127, 0, 0, 1, hi, lo]).unwrap();
        let mut reply = [0u8; 10];
        tcp.read_exact(&mut reply).unwrap();
        assert_eq!(reply[1], 0, "connect should succeed");
        let mut buf = [0u8; 64];
        let n = tcp.read(&mut buf).unwrap();
        assert!(String::from_utf8_lossy(&buf[..n]).starts_with("SSH-2.0"));
        transport.close();
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
    fn agent_login_runs_a_shell() {
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        let Ok(path) = std::env::var("PROMPTLY_TEST_SSH_KEY") else {
            return;
        };
        // A private agent for this test, with the test key added.
        let Ok(out) = std::process::Command::new("ssh-agent").arg("-s").output() else {
            eprintln!("ssh-agent not available; skipping");
            return;
        };
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        let find = |name: &str| {
            text.lines()
                .find_map(|l| l.strip_prefix(&format!("{name}=")))
                .and_then(|rest| rest.split(';').next())
                .map(str::to_string)
        };
        let (Some(sock), Some(pid)) = (find("SSH_AUTH_SOCK"), find("SSH_AGENT_PID")) else {
            panic!("could not start ssh-agent: {text}");
        };
        let added = std::process::Command::new("ssh-add")
            .arg(&path)
            .env("SSH_AUTH_SOCK", &sock)
            .output()
            .expect("run ssh-add");
        assert!(
            added.status.success(),
            "{}",
            String::from_utf8_lossy(&added.stderr)
        );
        std::env::set_var("SSH_AUTH_SOCK", &sock);

        let (text, _) = run_shell("agent", AuthMethod::Agent, endpoint, &password);
        let _ = std::process::Command::new("kill").arg(&pid).status();
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
