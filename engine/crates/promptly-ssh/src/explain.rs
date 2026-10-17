//! Connection failures in plain words: a short title and one line on what
//! to try. The error's own text stays available as the technical detail.

use crate::connect::{AgentProblem, ConnectError, NetCause};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Explanation {
    pub title: String,
    pub hint: String,
}

fn says(title: impl Into<String>, hint: impl Into<String>) -> Explanation {
    Explanation {
        title: title.into(),
        hint: hint.into(),
    }
}

impl ConnectError {
    /// What the person should read: what happened, and what to try.
    pub fn explain(&self) -> Explanation {
        match self {
            ConnectError::Resolve { host } => says(
                format!("Couldn't find {host}"),
                "Check the hostname for typos, and that this device is online (or on the VPN the server needs).",
            ),
            ConnectError::Connect { host, port, cause, .. } => match cause {
                NetCause::Refused => says(
                    format!("Nothing is answering on port {port}"),
                    format!("Check the port number, and that the SSH server is running on {host}."),
                ),
                NetCause::TimedOut => timed_out(*port),
                NetCause::Unreachable => says(
                    format!("This device can't reach {host}"),
                    "Check that you're online. A private address may need a VPN or a jump host.",
                ),
                NetCause::Other => says(
                    format!("Couldn't reach {host}"),
                    "Check the address and port, and that this device is online.",
                ),
            },
            ConnectError::Timeout { .. } => says(
                "The server didn't answer in time",
                "Check the address and port, and that a firewall or VPN isn't blocking the connection.",
            ),
            ConnectError::Jump { host, source } => {
                let inner = source.explain();
                says(format!("Couldn't connect to the jump host {host}"), inner.hint)
            }
            ConnectError::Tunnel { via, host, .. } => says(
                format!("{via} couldn't reach {host}"),
                format!("Check the address and port as {via} sees them, and that {via} allows forwarding (AllowTcpForwarding in its SSH settings)."),
            ),
            ConnectError::HostKeyRejected { changed: false } => says(
                "The server's key wasn't trusted",
                "Connect again and choose Trust if the fingerprint is the one you expect.",
            ),
            ConnectError::HostKeyRejected { changed: true } => says(
                "The server's identity has changed",
                "Don't connect until whoever runs the server confirms the new fingerprint.",
            ),
            ConnectError::HostKeyRevoked => says(
                "The server's key has been revoked",
                "A known_hosts file marks this key as not to be trusted. Ask whoever runs the server.",
            ),
            ConnectError::AuthFailed { offered, .. } => {
                says("The server didn't accept the login", login_hint(offered))
            }
            ConnectError::Agent(problem) => says(
                "Couldn't use the SSH agent",
                match problem {
                    AgentProblem::NotRunning | AgentProblem::Unreachable(_) => {
                        "Start your SSH agent and add a key with ssh-add, or set the host to use a key from the Keys tab."
                    }
                    AgentProblem::PermissionDenied(_) => {
                        "Promptly isn't allowed to open the agent. Check the agent socket's permissions, or set the host to use a key."
                    }
                    AgentProblem::NoKeys => "The agent holds no keys. Add one with ssh-add, then try again.",
                    AgentProblem::Failed(_) => "Check the agent is unlocked and working, then try again.",
                },
            ),
            ConnectError::Cancelled => says("Cancelled", "Choose Try again when you're ready."),
            ConnectError::BadKey(_) => says(
                "The key couldn't be read",
                "It may be damaged or in a format Promptly can't read. Import it again on the Keys tab.",
            ),
            ConnectError::KeyNeedsPassphrase => says(
                "The key needs its passphrase",
                "Try again and type the passphrase you set when the key was made.",
            ),
            ConnectError::WrongPassphrase => says(
                "Wrong passphrase for the key",
                "Try again with the passphrase you set when the key was made.",
            ),
            ConnectError::Ssh(e) => ssh(e),
        }
    }
}

fn timed_out(port: u16) -> Explanation {
    says(
        "The server didn't answer",
        format!("Check the address, and that a firewall or VPN isn't blocking port {port}."),
    )
}

/// What to check, from the methods the server said it accepts.
fn login_hint(offered: &[&str]) -> String {
    let key = offered.contains(&"publickey");
    let typed = offered.contains(&"password") || offered.contains(&"keyboard-interactive");
    match (key, typed) {
        (true, false) => {
            "This server only accepts keys. Set the host to use a key that is on the server.".into()
        }
        (false, true) => {
            "This server only accepts a password. Check the user name and the password.".into()
        }
        _ => "Check the user name, and the password or key for this host.".into(),
    }
}

fn ssh(e: &russh::Error) -> Explanation {
    use russh::Error as E;
    match e {
        E::NoCommonAlgo { .. } | E::KexInit | E::Kex | E::UnknownAlgo => says(
            "Promptly and the server have no encryption in common",
            "The server may be very old or locked down. Whoever runs it can turn on a modern key exchange.",
        ),
        E::Version => says(
            "That port doesn't speak SSH",
            "Something other than an SSH server answered. Check the port number.",
        ),
        E::Disconnect | E::HUP | E::RecvError | E::SendError => says(
            "The server closed the connection",
            "It may limit who can connect, or be busy. Try again in a moment.",
        ),
        E::ConnectionTimeout | E::KeepaliveTimeout | E::InactivityTimeout | E::Elapsed(_) => says(
            "The server stopped answering",
            "Check your network, then try again.",
        ),
        E::IO(io) => match io.kind() {
            std::io::ErrorKind::ConnectionRefused => says(
                "The connection was refused",
                "Check the port number, and that the SSH server is running.",
            ),
            std::io::ErrorKind::TimedOut => says(
                "The server didn't answer",
                "Check the address, and that a firewall or VPN isn't blocking it.",
            ),
            _ => says(
                "The connection broke",
                "Check your network, then try again.",
            ),
        },
        _ => says(
            "The connection failed",
            "Try again. If it keeps failing, Details has the technical reason.",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn connect(cause: NetCause) -> ConnectError {
        ConnectError::Connect {
            host: "web-1".into(),
            port: 2222,
            reason: "x".into(),
            cause,
        }
    }

    #[test]
    fn network_failures_say_what_to_check() {
        let e = ConnectError::Resolve {
            host: "web-1".into(),
        }
        .explain();
        assert_eq!(e.title, "Couldn't find web-1");
        assert!(e.hint.contains("typos"), "{e:?}");

        let e = connect(NetCause::Refused).explain();
        assert_eq!(e.title, "Nothing is answering on port 2222");
        assert!(e.hint.contains("SSH server is running"), "{e:?}");

        assert!(connect(NetCause::TimedOut)
            .explain()
            .hint
            .contains("port 2222"));
        assert!(connect(NetCause::Unreachable)
            .explain()
            .hint
            .contains("VPN or a jump host"));
    }

    #[test]
    fn login_failures_use_the_methods_the_server_offered() {
        let only_keys = ConnectError::AuthFailed {
            reason: "the server does not accept passwords for this user".into(),
            offered: vec!["publickey"],
        };
        assert!(only_keys.explain().hint.contains("only accepts keys"));
        assert_eq!(
            only_keys.to_string(),
            "the server does not accept passwords for this user (the server accepts: publickey)"
        );

        let only_typed = ConnectError::AuthFailed {
            reason: "the server did not accept the key".into(),
            offered: vec!["password", "keyboard-interactive"],
        };
        assert!(only_typed
            .explain()
            .hint
            .contains("only accepts a password"));

        let unknown = ConnectError::AuthFailed {
            reason: "the server rejected the answers".into(),
            offered: vec![],
        };
        assert_eq!(unknown.to_string(), "the server rejected the answers");
        assert!(unknown.explain().hint.contains("password or key"));
    }

    #[test]
    fn keys_agents_and_jump_hosts_get_their_own_advice() {
        assert_eq!(
            ConnectError::KeyNeedsPassphrase.explain().title,
            "The key needs its passphrase"
        );
        assert_eq!(
            ConnectError::WrongPassphrase.explain().title,
            "Wrong passphrase for the key"
        );
        let denied = ConnectError::Agent(AgentProblem::PermissionDenied("denied".into()));
        assert!(denied.explain().hint.contains("isn't allowed"));
        assert!(ConnectError::Agent(AgentProblem::NoKeys)
            .explain()
            .hint
            .contains("ssh-add"));

        let jump = ConnectError::Jump {
            host: "bastion".into(),
            source: Box::new(connect(NetCause::Refused)),
        };
        let e = jump.explain();
        assert_eq!(e.title, "Couldn't connect to the jump host bastion");
        assert!(
            e.hint.contains("SSH server is running"),
            "the inner advice: {e:?}"
        );
    }

    #[test]
    fn protocol_failures_are_not_raw_errors() {
        let e = ConnectError::Ssh(russh::Error::Disconnect).explain();
        assert_eq!(e.title, "The server closed the connection");
        let e = ConnectError::Ssh(russh::Error::Version).explain();
        assert!(e.hint.contains("port number"));
        let e = ConnectError::Ssh(russh::Error::Inconsistent).explain();
        assert!(e.hint.contains("Details"));
    }
}
