//! Connecting to a host over SSH, driven by the UI.
//!
//! The flow runs on the engine's runtime and reports through a stream. When
//! it needs an answer (trust this host key? what is the password?) it emits
//! an event and waits until the UI calls the matching `ssh_answer_*`
//! function. On success the connection becomes an ordinary terminal session
//! and the UI subscribes to its frames by the id in the `Connected` event.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use flutter_rust_bridge::frb;
use promptly_session::{Session, SessionKind};
use promptly_ssh::{
    connect, AuthMethod, ConnectError, ConnectParams, Endpoint, ForwardKind, ForwardSpec, Prompter,
    QuietPrompter,
};
use promptly_term::TermSize;

use crate::api::terminal::{palette_for, reattach_session, register_session, session_exists};
use crate::frb_generated::StreamSink;
use crate::ssh_flow::{
    attempt, connection, remember_connection, Attempt, Pending, UiPrompter, ATTEMPTS, NEXT_ATTEMPT,
    UNCLAIMED,
};

// ---- Types the UI sees -------------------------------------------------

pub enum SshAuthKind {
    /// Use `password` if given, otherwise ask.
    Password,
    /// Use `private_key` (OpenSSH, PEM or PuTTY text) with `passphrase` if needed.
    Key,
    /// Keyboard-interactive only.
    Interactive,
    /// The keys in the running SSH agent, then whatever the server offers.
    Agent,
}

/// One jump host on the way to the target.
pub struct SshHop {
    pub user: String,
    pub host: String,
    pub port: u16,
    pub auth: SshAuthKind,
    pub password: Option<String>,
    pub private_key: Option<String>,
    pub passphrase: Option<String>,
}

pub enum SshForwardKind {
    Local,
    Remote,
    Dynamic,
}

pub struct SshForward {
    pub kind: SshForwardKind,
    pub bind_host: String,
    pub bind_port: u16,
    pub target_host: String,
    pub target_port: u16,
    /// Start when the session connects.
    pub auto: bool,
}

pub struct SshEnvVar {
    pub name: String,
    pub value: String,
}

/// One forward of a live session, in the order the request listed them.
pub struct SshForwardStatus {
    pub index: u32,
    pub forward: SshForward,
    pub active: bool,
    /// The port in use while active (the one asked for, or the one picked
    /// for 0).
    pub bound_port: u16,
    pub error: Option<String>,
}

pub struct SshConnectRequest {
    pub user: String,
    pub host: String,
    pub port: u16,
    pub auth: SshAuthKind,
    pub password: Option<String>,
    pub private_key: Option<String>,
    pub passphrase: Option<String>,
    pub cols: u16,
    pub rows: u16,
    /// Theme id for the terminal; see `themes_list`.
    pub theme: String,
    /// What to call the session; defaults to `user@host`.
    pub label: Option<String>,
    pub keepalive_seconds: u32,
    /// When reconnecting: the session whose connection dropped. On success
    /// it gets the new connection and keeps its screen, and `Connected`
    /// carries its id. If it no longer exists a new session is made.
    pub reattach_session_id: Option<u32>,
    /// Jump hosts in the order they are reached: the first is connected
    /// to from this device, the last opens the tunnel to the target.
    pub jumps: Vec<SshHop>,
    /// Attach to the tmux session Promptly keeps on the server instead of
    /// a plain shell, so the work survives the connection.
    pub persistent: bool,
    /// Typed into the shell once it opens.
    pub startup_command: Option<String>,
    pub env: Vec<SshEnvVar>,
    pub agent_forward: bool,
    pub forwards: Vec<SshForward>,
}

pub enum SshStep {
    JumpHost,
    Resolving,
    Connecting,
    VerifyingHostKey,
    Authenticating,
    OpeningShell,
    Connected,
}

pub enum SshHostKeyStatus {
    Unknown,
    Changed,
}

pub struct SshHostKey {
    pub host: String,
    pub port: u16,
    pub algorithm: String,
    pub bits: u32,
    pub fingerprint: String,
    pub public_key: String,
    pub randomart: String,
    pub status: SshHostKeyStatus,
}

pub struct SshKbPrompt {
    pub prompt: String,
    pub echo: bool,
}

pub enum SshEventKind {
    Progress,
    HostKey,
    Secret,
    KeyboardInteractive,
    Connected,
    Failed,
}

/// One event from a connection attempt. The fields for other kinds are None.
pub struct SshEvent {
    pub kind: SshEventKind,
    pub step: Option<SshStep>,
    pub host_key: Option<SshHostKey>,
    pub secret_prompt: Option<String>,
    pub kb_name: Option<String>,
    pub kb_instructions: Option<String>,
    pub kb_prompts: Option<Vec<SshKbPrompt>>,
    pub session_id: Option<u32>,
    pub error: Option<String>,
}

impl SshEvent {
    pub(crate) fn blank(kind: SshEventKind) -> Self {
        Self {
            kind,
            step: None,
            host_key: None,
            secret_prompt: None,
            kb_name: None,
            kb_instructions: None,
            kb_prompts: None,
            session_id: None,
            error: None,
        }
    }
}

// ---- Functions ---------------------------------------------------------

/// Register a connection attempt. Nothing happens until `ssh_connect_events`
/// is subscribed.
#[frb(sync)]
pub fn ssh_connect_begin(request: SshConnectRequest) -> u32 {
    let id = NEXT_ATTEMPT.fetch_add(1, Ordering::Relaxed);
    ATTEMPTS.lock().unwrap().insert(
        id,
        Arc::new(Attempt {
            request: Mutex::new(Some(request)),
            sink: Mutex::new(None),
            pending: Mutex::new(Pending::default()),
            task: Mutex::new(None),
        }),
    );
    id
}

/// Who holds which tmux session name on which server: a connection attempt
/// while it runs, then the terminal session it made. One name per open
/// session, so two sessions to one host are two tmux sessions, not two
/// views of the same one, and a reconnect goes back to its own.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum TmuxHolder {
    Attempt(u32),
    Session(u32),
}

static TMUX_NAMES: Mutex<std::collections::BTreeMap<TmuxHolder, (String, String)>> =
    Mutex::new(std::collections::BTreeMap::new());

fn tmux_name_for(attempt_id: u32, server: &str, reattach: Option<u32>) -> String {
    // Both held throughout, in the order the connect task takes them, so
    // an attempt that starts meanwhile is either seen live here or waits
    // until this one has its name.
    let live = ATTEMPTS.lock().unwrap();
    let mut names = TMUX_NAMES.lock().unwrap();
    names.retain(|holder, _| match holder {
        TmuxHolder::Attempt(a) => live.contains_key(a),
        TmuxHolder::Session(s) => session_exists(*s),
    });
    let name = reattach
        .and_then(|id| names.get(&TmuxHolder::Session(id)))
        .filter(|(s, _)| s == server)
        .map(|(_, n)| n.clone())
        .unwrap_or_else(|| {
            let used: std::collections::BTreeSet<&str> = names
                .values()
                .filter(|(s, _)| s == server)
                .map(|(_, n)| n.as_str())
                .collect();
            (1..)
                .map(|i| match i {
                    1 => "promptly".to_string(),
                    i => format!("promptly-{i}"),
                })
                .find(|n| !used.contains(n.as_str()))
                .expect("an unused name")
        });
    names.insert(
        TmuxHolder::Attempt(attempt_id),
        (server.to_string(), name.clone()),
    );
    name
}

fn claim_tmux_name(attempt_id: u32, session_id: u32) {
    let mut names = TMUX_NAMES.lock().unwrap();
    if let Some(v) = names.remove(&TmuxHolder::Attempt(attempt_id)) {
        names.insert(TmuxHolder::Session(session_id), v);
    }
}

/// Subscribe to an attempt's events; this starts the connection.
pub fn ssh_connect_events(attempt_id: u32, sink: StreamSink<SshEvent>) -> anyhow::Result<()> {
    let attempt = attempt(attempt_id).map_err(anyhow::Error::msg)?;
    *attempt.sink.lock().unwrap() = Some(sink);
    let Some(request) = attempt.request.lock().unwrap().take() else {
        anyhow::bail!("attempt {attempt_id} already started");
    };

    let endpoint = Endpoint {
        user: request.user.clone(),
        host: request.host.clone(),
        port: request.port,
    };
    let size = TermSize::new(request.cols, request.rows);
    let tmux = request.persistent.then(|| {
        tmux_name_for(
            attempt_id,
            &endpoint.to_string(),
            request.reattach_session_id,
        )
    });
    let params = params_for(&request, endpoint.clone(), size, tmux.as_deref());
    let label = request
        .label
        .clone()
        .unwrap_or_else(|| endpoint.to_string());
    let palette = palette_for(&request.theme);
    let reattach = request.reattach_session_id;

    let known_hosts = Arc::new(crate::sync_engine::VaultKnownHosts::new());
    let prompter: Arc<dyn Prompter> = Arc::new(UiPrompter(attempt.clone()));

    let task_attempt = attempt.clone();
    let task = promptly_ssh::runtime().spawn(async move {
        let result = connect(params, prompter, known_hosts).await;
        match result {
            Ok((transport, reader)) => {
                let connection = transport.connection();
                // Held from the check to the hand-over, so a cancel lands either
                // before (and this hangs up) or after (and finds the session).
                let mut attempts = ATTEMPTS.lock().unwrap();
                if !attempts.contains_key(&attempt_id) {
                    // Cancelled as it connected: dropping it hangs up.
                    return;
                }
                let session_id = match reattach {
                    Some(id) if session_exists(id) => {
                        // The session is still open: give it the new connection.
                        let _ = reattach_session(id, Box::new(transport), Box::new(reader));
                        id
                    }
                    _ => {
                        let session = Arc::new(Session::new(
                            SessionKind::Ssh { host: label },
                            size,
                            palette,
                            Box::new(transport),
                        ));
                        let id = register_session(session, Box::new(reader));
                        UNCLAIMED.lock().unwrap().insert(attempt_id, id);
                        id
                    }
                };
                remember_connection(session_id, connection);
                claim_tmux_name(attempt_id, session_id);
                let mut e = SshEvent::blank(SshEventKind::Connected);
                e.session_id = Some(session_id);
                attempt.emit(e);
                attempts.remove(&attempt_id);
                return;
            }
            Err(err) => {
                let mut e = SshEvent::blank(SshEventKind::Failed);
                e.error = Some(err.to_string());
                attempt.emit(e);
            }
        }
        ATTEMPTS.lock().unwrap().remove(&attempt_id);
    });
    *task_attempt.task.lock().unwrap() = Some(task.abort_handle());
    // A cancel that came before the handle was stored could not stop it.
    if !ATTEMPTS.lock().unwrap().contains_key(&attempt_id) {
        task.abort();
    }
    Ok(())
}

fn auth_for(
    kind: &SshAuthKind,
    password: &Option<String>,
    private_key: &Option<String>,
    passphrase: &Option<String>,
) -> AuthMethod {
    match kind {
        SshAuthKind::Password => AuthMethod::Password {
            password: password.clone(),
        },
        SshAuthKind::Key => AuthMethod::Key {
            private_key: private_key.clone().unwrap_or_default(),
            passphrase: passphrase.clone(),
        },
        SshAuthKind::Interactive => AuthMethod::Interactive,
        SshAuthKind::Agent => AuthMethod::Agent,
    }
}

fn forward_spec(f: &SshForward) -> ForwardSpec {
    ForwardSpec {
        kind: match f.kind {
            SshForwardKind::Local => ForwardKind::Local,
            SshForwardKind::Remote => ForwardKind::Remote,
            SshForwardKind::Dynamic => ForwardKind::Dynamic,
        },
        bind_host: f.bind_host.clone(),
        bind_port: f.bind_port,
        target_host: f.target_host.clone(),
        target_port: f.target_port,
        auto: f.auto,
    }
}

/// The engine's connection parameters for a request, jump chain included.
fn params_for(
    request: &SshConnectRequest,
    endpoint: Endpoint,
    size: TermSize,
    tmux_session: Option<&str>,
) -> ConnectParams {
    let keepalive = std::time::Duration::from_secs(u64::from(request.keepalive_seconds));
    let mut jump: Option<Box<ConnectParams>> = None;
    for hop in &request.jumps {
        let mut p = ConnectParams::new(
            Endpoint {
                user: hop.user.clone(),
                host: hop.host.clone(),
                port: hop.port,
            },
            auth_for(&hop.auth, &hop.password, &hop.private_key, &hop.passphrase),
            size,
        );
        if request.keepalive_seconds > 0 {
            p.keepalive = keepalive;
        }
        p.jump = jump;
        jump = Some(Box::new(p));
    }
    let auth = auth_for(
        &request.auth,
        &request.password,
        &request.private_key,
        &request.passphrase,
    );
    let mut params = ConnectParams::new(endpoint, auth, size);
    if request.keepalive_seconds > 0 {
        params.keepalive = keepalive;
    }
    params.jump = jump;
    let startup = request
        .startup_command
        .as_ref()
        .map(|c| c.trim())
        .filter(|c| !c.is_empty());
    match tmux_session {
        Some(name) => {
            // tmux types the startup command itself, and only into a session
            // it has just made.
            params.command = Some(ConnectParams::persistent_command(name, startup));
        }
        None => params.startup_input = startup.map(|c| format!("{c}\n")),
    }
    params.env = request
        .env
        .iter()
        .map(|v| (v.name.clone(), v.value.clone()))
        .collect();
    params.agent_forward = request.agent_forward;
    params.forwards = request.forwards.iter().map(forward_spec).collect();
    params
}

/// What one command printed on one host, for snippets run on many hosts.
pub struct SshExecResult {
    pub output: String,
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    /// Why it could not run at all; `output` is empty then.
    pub error: Option<String>,
}

/// Connect with the request's stored login, run `command` without a
/// terminal, and return what it printed. Unattended: a host key not yet
/// trusted, or a login that needs typing, is an error that says what to do.
pub fn ssh_exec(
    request: SshConnectRequest,
    command: String,
    timeout_seconds: u32,
) -> SshExecResult {
    let endpoint = Endpoint {
        user: request.user.clone(),
        host: request.host.clone(),
        port: request.port,
    };
    let label = request
        .label
        .clone()
        .unwrap_or_else(|| endpoint.to_string());
    let params = params_for(&request, endpoint, TermSize::default(), None);
    let known_hosts = Arc::new(crate::sync_engine::VaultKnownHosts::new());
    let prompter: Arc<dyn Prompter> = Arc::new(QuietPrompter);
    let timeout = std::time::Duration::from_secs(u64::from(timeout_seconds.max(1)));
    let result = promptly_ssh::runtime().block_on(promptly_ssh::exec(
        &params,
        prompter,
        known_hosts,
        &command,
        timeout,
    ));
    match result {
        Ok(out) => SshExecResult {
            output: out.output,
            exit_code: out.exit_code,
            timed_out: out.timed_out,
            error: None,
        },
        Err(e) => SshExecResult {
            output: String::new(),
            exit_code: None,
            timed_out: false,
            error: Some(match e {
                ConnectError::HostKeyRejected { changed: false } => format!(
                    "Connect to {label} in the terminal once first, so its host key is trusted."
                ),
                ConnectError::HostKeyRejected { changed: true } => format!(
                    "{label} showed a different host key from the one trusted before, so nothing was run. This can mean someone is intercepting the connection. Check with whoever runs the server before connecting to it in the terminal."
                ),
                ConnectError::HostKeyRevoked => format!(
                    "{label}'s host key is marked as revoked in a known_hosts file, so nothing was run."
                ),
                ConnectError::Cancelled => format!(
                    "{label} asks for a login each time. Save a password or pick a key to run snippets on it."
                ),
                ConnectError::AuthFailed(_) => format!(
                    "The saved login for {label} did not work. Check the password or key on the host."
                ),
                other => other.to_string(),
            }),
        },
    }
}

/// The forwards of a live SSH session and whether each is running.
#[frb(sync)]
pub fn ssh_forwards(session_id: u32) -> Result<Vec<SshForwardStatus>, String> {
    let connection = connection(session_id)?;
    Ok(connection
        .forwards()
        .into_iter()
        .enumerate()
        .map(|(i, f)| SshForwardStatus {
            index: i as u32,
            forward: SshForward {
                kind: match f.spec.kind {
                    ForwardKind::Local => SshForwardKind::Local,
                    ForwardKind::Remote => SshForwardKind::Remote,
                    ForwardKind::Dynamic => SshForwardKind::Dynamic,
                },
                bind_host: f.spec.bind_host,
                bind_port: f.spec.bind_port,
                target_host: f.spec.target_host,
                target_port: f.spec.target_port,
                auto: f.spec.auto,
            },
            active: f.active,
            bound_port: f.bound_port,
            error: f.error,
        })
        .collect())
}

/// Start or stop one forward of a live session. Returns the port in use
/// when starting.
pub fn ssh_forward_set(session_id: u32, index: u32, enabled: bool) -> Result<u16, String> {
    let connection = connection(session_id)?;
    promptly_ssh::runtime().block_on(async move {
        if enabled {
            connection.start_forward(index as usize).await
        } else {
            connection.stop_forward(index as usize).await;
            Ok(0)
        }
    })
}

#[frb(sync)]
pub fn ssh_answer_host_key(attempt_id: u32, trust: bool) -> Result<(), String> {
    let a = attempt(attempt_id)?;
    let tx = a.pending.lock().unwrap().host_key.take();
    tx.ok_or("no host key question is waiting")?
        .send(trust)
        .map_err(|_| "the connection already moved on".to_string())
}

#[frb(sync)]
pub fn ssh_answer_secret(attempt_id: u32, secret: Option<String>) -> Result<(), String> {
    let a = attempt(attempt_id)?;
    let tx = a.pending.lock().unwrap().secret.take();
    tx.ok_or("no password question is waiting")?
        .send(secret)
        .map_err(|_| "the connection already moved on".to_string())
}

#[frb(sync)]
pub fn ssh_answer_keyboard_interactive(
    attempt_id: u32,
    answers: Option<Vec<String>>,
) -> Result<(), String> {
    let a = attempt(attempt_id)?;
    let tx = a.pending.lock().unwrap().keyboard.take();
    tx.ok_or("no interactive question is waiting")?
        .send(answers)
        .map_err(|_| "the connection already moved on".to_string())
}

/// Abandon an attempt. Any waiting question is answered "no".
#[frb(sync)]
pub fn ssh_cancel(attempt_id: u32) {
    let removed = ATTEMPTS.lock().unwrap().remove(&attempt_id);
    // Checked after the attempt is gone: a connect that finished first has
    // already listed its session here.
    let unclaimed = UNCLAIMED.lock().unwrap().remove(&attempt_id);
    if let Some(session_id) = unclaimed {
        // Connected but not yet picked up by the UI: close it, as nobody will.
        let _ = crate::api::terminal::terminal_close(session_id);
    }
    if let Some(a) = removed {
        let mut p = a.pending.lock().unwrap();
        p.host_key.take();
        p.secret.take();
        p.keyboard.take();
        *a.sink.lock().unwrap() = None;
        // Stop it mid-handshake too, so it never logs in or runs anything.
        if let Some(task) = a.task.lock().unwrap().take() {
            task.abort();
        }
    }
}
