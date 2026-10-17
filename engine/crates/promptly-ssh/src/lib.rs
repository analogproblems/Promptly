//! SSH connections for Promptly.
//!
//! Built on `russh`. [`connect`] runs the whole flow (resolve, connect,
//! host key check, authentication, pty, shell) and hands back a
//! [`SshTransport`] plus a reader, which plug straight into
//! `promptly_session::Session` and `pump`, exactly like a local shell.
//!
//! Anything that needs a decision from the person (an unknown host key, a
//! password, a two-factor prompt) goes through the [`Prompter`] the caller
//! supplies, so the UI drives the flow without the engine knowing about
//! dialogs.

pub mod connect;
pub mod endpoint;
pub mod exec;
pub mod files;
pub mod forward;
pub mod hostkey;
pub mod keys;
pub mod reach;
pub mod sftp;
pub mod ssh_config;
pub mod transport;

use std::sync::LazyLock;

pub use connect::{
    connect, connect_handle, AuthMethod, ConnectError, ConnectParams, ConnectStep, Handler,
    KeyboardPrompt, Prompter,
};
pub use endpoint::{Endpoint, ParseError};
pub use exec::{exec, ExecOutput};
pub use files::{join as join_remote_path, RemoteEntry, RemoteFs};
pub use forward::{Connection, ForwardKind, ForwardSpec, ForwardStatus};
pub use hostkey::{FileKnownHosts, HostKeyInfo, HostKeyStatus, KnownHosts};
pub use keys::{
    generate as generate_key, inspect as inspect_key, public_fingerprint, Generated, Inspected,
    KeyKind,
};
pub use reach::{reach, reach_all};
pub use russh::keys::{Algorithm, PublicKey};
pub use sftp::{QuietPrompter, SftpBackend, SftpError};
pub use ssh_config::{
    load_default as load_ssh_config, parse as parse_ssh_config, ConfigForward, ConfigForwardKind,
    ConfigHost,
};
pub use transport::{SshReader, SshTransport};

/// The runtime every SSH connection runs on. Two worker threads are plenty:
/// the work is waiting on sockets.
pub fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("promptly-ssh")
            .enable_all()
            .build()
            .expect("tokio runtime")
    });
    &RT
}
