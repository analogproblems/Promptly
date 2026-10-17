//! The SSH connection attempt registry and the prompter that turns the
//! engine's questions into events for the UI. Kept outside `api/` so the
//! bridge generator does not try to export these internals.

use std::collections::HashMap;
use std::sync::atomic::AtomicU32;
use std::sync::{Arc, LazyLock, Mutex};

use promptly_ssh::{ConnectStep, Connection, HostKeyInfo, HostKeyStatus, KeyboardPrompt, Prompter};
use tokio::sync::oneshot;
use zeroize::Zeroize;

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
    /// The connecting task, stopped when the attempt is cancelled.
    pub task: Mutex<Option<tokio::task::AbortHandle>>,
}

// An attempt cancelled before it started still holds its request; wipe the
// secrets in it rather than leave them in freed memory.
impl Drop for Attempt {
    fn drop(&mut self) {
        if let Some(request) = self.request.get_mut().ok().and_then(Option::as_mut) {
            wipe_request(request);
        }
    }
}

fn wipe_request(request: &mut SshConnectRequest) {
    let hops = request.jumps.iter_mut();
    let hop_secrets = hops.flat_map(|h| [&mut h.password, &mut h.private_key, &mut h.passphrase]);
    let own = [
        &mut request.password,
        &mut request.private_key,
        &mut request.passphrase,
    ];
    for secret in own.into_iter().chain(hop_secrets).flatten() {
        secret.zeroize();
    }
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

/// New sessions an attempt registered that the UI has not subscribed to yet,
/// by attempt. A cancel that arrives in between closes the session instead
/// of leaving it running unseen.
pub(crate) static UNCLAIMED: LazyLock<Mutex<HashMap<u32, u32>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// The UI has the session: a late cancel of its attempt no longer closes it.
pub(crate) fn claim_session(session_id: u32) {
    UNCLAIMED.lock().unwrap().retain(|_, s| *s != session_id);
}

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

/// Whether a secret the connect flow asks for is a private key's
/// passphrase (the first time, or after a wrong one) rather than a
/// password. The flow words every such question this way.
pub(crate) fn is_key_passphrase(prompt: &str) -> bool {
    prompt.ends_with("Passphrase for the private key")
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
        e.secret_for_key = is_key_passphrase(&prompt);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ssh::tests::request_with_secrets;

    #[test]
    fn a_request_never_started_has_its_secrets_wiped() {
        let mut request = request_with_secrets();
        wipe_request(&mut request);
        assert_eq!(request.password.as_deref(), Some(""));
        let hop = &request.jumps[0];
        assert_eq!(hop.private_key.as_deref(), Some(""));
        assert_eq!(hop.passphrase.as_deref(), Some(""));
    }

    #[test]
    fn key_passphrase_questions_are_told_from_passwords() {
        assert!(is_key_passphrase("Passphrase for the private key"));
        assert!(is_key_passphrase(
            "Wrong passphrase. Passphrase for the private key"
        ));
        assert!(!is_key_passphrase("Password for ops@web-1"));
    }
}
