//! The SSH connection attempt registry and the prompter that turns the
//! engine's questions into events for the UI. Kept outside `api/` so the
//! bridge generator does not try to export these internals.

use std::collections::HashMap;
use std::sync::atomic::AtomicU32;
use std::sync::{Arc, LazyLock, Mutex};

use promptly_ssh::{ConnectStep, Connection, HostKeyInfo, HostKeyStatus, KeyboardPrompt, Prompter};
use tokio::sync::oneshot;

use crate::api::ssh::{
    SshConnectRequest, SshEvent, SshEventKind, SshHostKey, SshHostKeyStatus, SshKbPrompt, SshStep,
};
use crate::frb_generated::StreamSink;

#[derive(Default)]
pub(crate) struct Pending {
    pub host_key: Option<oneshot::Sender<bool>>,
    pub secret: Option<oneshot::Sender<Option<String>>>,
    pub keyboard: Option<oneshot::Sender<Option<Vec<String>>>>,
}

pub(crate) struct Attempt {
    pub request: Mutex<Option<SshConnectRequest>>,
    pub sink: Mutex<Option<StreamSink<SshEvent>>>,
    pub pending: Mutex<Pending>,
}

impl Attempt {
    pub fn emit(&self, event: SshEvent) {
        if let Some(sink) = self.sink.lock().unwrap().as_ref() {
            let _ = sink.add(event);
        }
    }
}

pub(crate) static ATTEMPTS: LazyLock<Mutex<HashMap<u32, Arc<Attempt>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
pub(crate) static NEXT_ATTEMPT: AtomicU32 = AtomicU32::new(1);

/// The live SSH connection behind each terminal session, for forwards.
pub(crate) static CONNECTIONS: LazyLock<Mutex<HashMap<u32, Arc<Connection>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub(crate) fn connection(session_id: u32) -> Result<Arc<Connection>, String> {
    CONNECTIONS
        .lock()
        .unwrap()
        .get(&session_id)
        .cloned()
        .ok_or_else(|| format!("session {session_id} has no SSH connection"))
}

pub(crate) fn remember_connection(session_id: u32, connection: Arc<Connection>) {
    CONNECTIONS.lock().unwrap().insert(session_id, connection);
}

pub(crate) fn forget_connection(session_id: u32) {
    CONNECTIONS.lock().unwrap().remove(&session_id);
}

pub(crate) fn attempt(id: u32) -> Result<Arc<Attempt>, String> {
    ATTEMPTS
        .lock()
        .unwrap()
        .get(&id)
        .cloned()
        .ok_or_else(|| format!("no connection attempt {id}"))
}

/// The UI, as the connect flow sees it: every question becomes an event and
/// a oneshot the matching answer function completes.
pub(crate) struct UiPrompter(pub Arc<Attempt>);

impl Prompter for UiPrompter {
    fn progress(&self, step: ConnectStep) {
        let mut e = SshEvent::blank(SshEventKind::Progress);
        e.step = Some(match step {
            ConnectStep::JumpHost => SshStep::JumpHost,
            ConnectStep::Resolving => SshStep::Resolving,
            ConnectStep::Connecting => SshStep::Connecting,
            ConnectStep::VerifyingHostKey => SshStep::VerifyingHostKey,
            ConnectStep::Authenticating => SshStep::Authenticating,
            ConnectStep::OpeningShell => SshStep::OpeningShell,
            ConnectStep::Connected => SshStep::Connected,
        });
        self.0.emit(e);
    }

    fn confirm_host_key(
        &self,
        info: HostKeyInfo,
        status: HostKeyStatus,
    ) -> promptly_ssh::connect::BoxFuture<'_, bool> {
        let (tx, rx) = oneshot::channel();
        self.0.pending.lock().unwrap().host_key = Some(tx);
        let mut e = SshEvent::blank(SshEventKind::HostKey);
        e.host_key = Some(SshHostKey {
            host: info.host,
            port: info.port,
            algorithm: info.algorithm,
            bits: info.bits,
            fingerprint: info.fingerprint,
            public_key: info.public_key,
            randomart: info.randomart,
            status: match status {
                HostKeyStatus::Changed => SshHostKeyStatus::Changed,
                _ => SshHostKeyStatus::Unknown,
            },
        });
        self.0.emit(e);
        Box::pin(async move { rx.await.unwrap_or(false) })
    }

    fn ask_secret(&self, prompt: String) -> promptly_ssh::connect::BoxFuture<'_, Option<String>> {
        let (tx, rx) = oneshot::channel();
        self.0.pending.lock().unwrap().secret = Some(tx);
        let mut e = SshEvent::blank(SshEventKind::Secret);
        e.secret_prompt = Some(prompt);
        self.0.emit(e);
        Box::pin(async move { rx.await.unwrap_or(None) })
    }

    fn ask_keyboard_interactive(
        &self,
        name: String,
        instructions: String,
        prompts: Vec<KeyboardPrompt>,
    ) -> promptly_ssh::connect::BoxFuture<'_, Option<Vec<String>>> {
        let (tx, rx) = oneshot::channel();
        self.0.pending.lock().unwrap().keyboard = Some(tx);
        let mut e = SshEvent::blank(SshEventKind::KeyboardInteractive);
        e.kb_name = Some(name);
        e.kb_instructions = Some(instructions);
        e.kb_prompts = Some(
            prompts
                .into_iter()
                .map(|p| SshKbPrompt {
                    prompt: p.prompt,
                    echo: p.echo,
                })
                .collect(),
        );
        self.0.emit(e);
        Box::pin(async move { rx.await.unwrap_or(None) })
    }
}
