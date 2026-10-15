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
use promptly_ssh::{connect, AuthMethod, ConnectParams, Endpoint, FileKnownHosts, Prompter};
use promptly_term::TermSize;

use crate::api::terminal::{palette_for, reattach_session, register_session, session_exists};
use crate::frb_generated::StreamSink;
use crate::ssh_flow::{attempt, Attempt, Pending, UiPrompter, ATTEMPTS, NEXT_ATTEMPT};

// ---- Types the UI sees -------------------------------------------------

pub enum SshAuthKind {
    /// Use `password` if given, otherwise ask.
    Password,
    /// Use `private_key` (OpenSSH, PEM or PuTTY text) with `passphrase` if needed.
    Key,
    /// Keyboard-interactive only.
    Interactive,
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
}

pub enum SshStep {
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
        }),
    );
    id
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
    let auth = match request.auth {
        SshAuthKind::Password => AuthMethod::Password {
            password: request.password.clone(),
        },
        SshAuthKind::Key => AuthMethod::Key {
            private_key: request.private_key.clone().unwrap_or_default(),
            passphrase: request.passphrase.clone(),
        },
        SshAuthKind::Interactive => AuthMethod::Interactive,
    };
    let size = TermSize::new(request.cols, request.rows);
    let mut params = ConnectParams::new(endpoint.clone(), auth, size);
    if request.keepalive_seconds > 0 {
        params.keepalive = std::time::Duration::from_secs(u64::from(request.keepalive_seconds));
    }
    let label = request
        .label
        .clone()
        .unwrap_or_else(|| endpoint.to_string());
    let palette = palette_for(&request.theme);
    let reattach = request.reattach_session_id;

    let known_hosts = Arc::new(FileKnownHosts::default_paths(
        &crate::api::engine::data_dir(),
    ));
    let prompter: Arc<dyn Prompter> = Arc::new(UiPrompter(attempt.clone()));

    promptly_ssh::runtime().spawn(async move {
        let result = connect(params, prompter, known_hosts).await;
        match result {
            Ok((transport, reader)) => {
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
                        register_session(session, Box::new(reader))
                    }
                };
                let mut e = SshEvent::blank(SshEventKind::Connected);
                e.session_id = Some(session_id);
                attempt.emit(e);
            }
            Err(err) => {
                let mut e = SshEvent::blank(SshEventKind::Failed);
                e.error = Some(err.to_string());
                attempt.emit(e);
            }
        }
        ATTEMPTS.lock().unwrap().remove(&attempt_id);
    });
    Ok(())
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
    if let Some(a) = ATTEMPTS.lock().unwrap().remove(&attempt_id) {
        let mut p = a.pending.lock().unwrap();
        p.host_key.take();
        p.secret.take();
        p.keyboard.take();
        *a.sink.lock().unwrap() = None;
    }
}
