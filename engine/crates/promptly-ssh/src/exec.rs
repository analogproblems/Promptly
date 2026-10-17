//! Run one command on a host and collect what it printed, for snippets
//! run on many hosts at once. No pty: the output is what a script would
//! see, and the command cannot ask questions.

use std::sync::Arc;
use std::time::Duration;

use russh::ChannelMsg;

use crate::connect::{connect_handle, ConnectError, ConnectParams, Prompter};
use crate::hostkey::KnownHosts;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecOutput {
    /// Standard output and standard error, in the order they arrived.
    pub output: String,
    /// The command's exit code, when the server reported one.
    pub exit_code: Option<i32>,
    /// The command was still running when `timeout` passed; `output` holds
    /// what it had printed by then.
    pub timed_out: bool,
}

/// Connect, run `command`, and return its output once it ends or
/// `timeout` passes. The connection is closed either way.
pub async fn exec(
    params: &ConnectParams,
    prompter: Arc<dyn Prompter>,
    known_hosts: Arc<dyn KnownHosts>,
    command: &str,
    timeout: Duration,
) -> Result<ExecOutput, ConnectError> {
    let connection = connect_handle(params, prompter, known_hosts).await?;
    let mut channel = connection.handle().channel_open_session().await?;
    for (name, value) in &params.env {
        let _ = channel.set_env(false, name.clone(), value.clone()).await;
    }
    channel.exec(true, command.as_bytes().to_vec()).await?;

    let mut output = Vec::new();
    let mut exit_code = None;
    let collect = async {
        while let Some(msg) = channel.wait().await {
            match msg {
                ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => {
                    output.extend_from_slice(&data);
                }
                ChannelMsg::ExitStatus { exit_status } => exit_code = Some(exit_status as i32),
                ChannelMsg::Close => break,
                _ => {}
            }
        }
    };
    let timed_out = tokio::time::timeout(timeout, collect).await.is_err();
    let _ = channel.close().await;
    connection.disconnect().await;
    Ok(ExecOutput {
        output: String::from_utf8_lossy(&output).into_owned(),
        exit_code,
        timed_out,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connect::AuthMethod;
    use crate::hostkey::FileKnownHosts;
    use crate::sftp::QuietPrompter;
    use crate::Endpoint;
    use promptly_term::TermSize;

    fn test_server() -> Option<(Endpoint, String)> {
        let spec = std::env::var("PROMPTLY_TEST_SSH").ok()?;
        let (cred, hostport) = spec.rsplit_once('@')?;
        let (user, password) = cred.split_once(':')?;
        let endpoint = Endpoint::parse(&format!("{user}@{hostport}")).ok()?;
        Some((endpoint, password.to_string()))
    }

    /// A known-hosts store that already trusts the test server, as a saved
    /// host would after one terminal session.
    fn trusting_store(label: &str) -> Arc<FileKnownHosts> {
        let dir =
            std::env::temp_dir().join(format!("promptly-exec-test-{}-{label}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Arc::new(FileKnownHosts::new(vec![], dir.join("known_hosts")))
    }

    #[test]
    fn exec_collects_output_and_exit_code() {
        let Some((endpoint, password)) = test_server() else {
            return;
        };
        let params = ConnectParams::new(
            endpoint,
            AuthMethod::Password {
                password: Some(password),
            },
            TermSize::default(),
        );
        // First with an empty store: a quiet prompter cannot trust a new key.
        let err = crate::runtime()
            .block_on(exec(
                &params,
                Arc::new(QuietPrompter),
                trusting_store("fresh"),
                "true",
                Duration::from_secs(10),
            ))
            .expect_err("an unknown host key is refused unattended");
        assert!(
            matches!(err, ConnectError::HostKeyRejected { changed: false }),
            "{err}"
        );

        // Then with the key learnt, the way a terminal session leaves it.
        struct Trusting;
        impl Prompter for Trusting {
            fn progress(&self, _: crate::ConnectStep) {}
            fn confirm_host_key(
                &self,
                _: crate::HostKeyInfo,
                _: crate::HostKeyStatus,
            ) -> crate::connect::BoxFuture<'_, bool> {
                Box::pin(async { true })
            }
            fn ask_secret(&self, _: String) -> crate::connect::BoxFuture<'_, Option<String>> {
                Box::pin(async { None })
            }
            fn ask_keyboard_interactive(
                &self,
                _: String,
                _: String,
                _: Vec<crate::KeyboardPrompt>,
            ) -> crate::connect::BoxFuture<'_, Option<Vec<String>>> {
                Box::pin(async { None })
            }
        }
        let out = crate::runtime()
            .block_on(exec(
                &params,
                Arc::new(Trusting),
                trusting_store("learnt"),
                "echo out-$((6*7)); echo err-part 1>&2; exit 3",
                Duration::from_secs(10),
            ))
            .expect("exec");
        assert!(out.output.contains("out-42"), "{out:?}");
        assert!(out.output.contains("err-part"), "{out:?}");
        assert_eq!(out.exit_code, Some(3));
        assert!(!out.timed_out);

        let slow = crate::runtime()
            .block_on(exec(
                &params,
                Arc::new(Trusting),
                trusting_store("slow"),
                "echo started; sleep 5; echo never",
                Duration::from_secs(1),
            ))
            .expect("exec");
        assert!(slow.timed_out);
        assert!(slow.output.contains("started"), "{slow:?}");
        assert!(!slow.output.contains("never"));
    }
}
