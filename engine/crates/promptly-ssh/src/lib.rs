//! SSH connections for Promptly.
//!
//! Milestone 1 builds this on `russh`: one connection per host, multiplexed
//! channels for the shell, SFTP and port forwards, an auth state machine the
//! UI can drive, and host key verification as a callback. Milestone 0 fixes
//! the address type everything else refers to.

use serde::{Deserialize, Serialize};
use std::fmt;

/// Where to connect: `user@host:port`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Endpoint {
    pub user: String,
    pub host: String,
    pub port: u16,
}

impl Endpoint {
    pub const DEFAULT_PORT: u16 = 22;

    /// Parse `user@host`, `user@host:port`, `host` or `host:port`.
    /// A missing user is an error here; the caller fills in a default first.
    pub fn parse(input: &str) -> Result<Self, ParseError> {
        let input = input.trim();
        if input.is_empty() {
            return Err(ParseError::Empty);
        }
        let (user, rest) = match input.rsplit_once('@') {
            Some((u, r)) if !u.is_empty() => (u.to_string(), r),
            Some(_) => return Err(ParseError::EmptyUser),
            None => return Err(ParseError::MissingUser),
        };
        let (host, port) = match rest.rsplit_once(':') {
            // IPv6 literals contain colons; only treat the suffix as a port if it is numeric.
            Some((h, p)) if p.chars().all(|c| c.is_ascii_digit()) && !p.is_empty() => {
                (h, p.parse::<u16>().map_err(|_| ParseError::BadPort)?)
            }
            _ => (rest, Self::DEFAULT_PORT),
        };
        let host = host.trim_matches(|c| c == '[' || c == ']');
        if host.is_empty() {
            return Err(ParseError::EmptyHost);
        }
        if port == 0 {
            return Err(ParseError::BadPort);
        }
        Ok(Self {
            user,
            host: host.to_string(),
            port,
        })
    }
}

impl fmt::Display for Endpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.port == Self::DEFAULT_PORT {
            write!(f, "{}@{}", self.user, self.host)
        } else {
            write!(f, "{}@{}:{}", self.user, self.host, self.port)
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ParseError {
    #[error("nothing to connect to")]
    Empty,
    #[error("a user name is required, like user@host")]
    MissingUser,
    #[error("the user name before @ is empty")]
    EmptyUser,
    #[error("the host name is empty")]
    EmptyHost,
    #[error("the port must be a number between 1 and 65535")]
    BadPort,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_common_forms() {
        let e = Endpoint::parse("deploy@10.0.0.11").unwrap();
        assert_eq!(
            (e.user.as_str(), e.host.as_str(), e.port),
            ("deploy", "10.0.0.11", 22)
        );
        let e = Endpoint::parse("pi@pi-hole.local:2222").unwrap();
        assert_eq!(e.port, 2222);
        assert_eq!(e.to_string(), "pi@pi-hole.local:2222");
        let e = Endpoint::parse("admin@[fe80::1]:22").unwrap();
        assert_eq!(e.host, "fe80::1");
    }

    #[test]
    fn rejects_bad_input() {
        assert_eq!(Endpoint::parse("").unwrap_err(), ParseError::Empty);
        assert_eq!(
            Endpoint::parse("host").unwrap_err(),
            ParseError::MissingUser
        );
        assert_eq!(Endpoint::parse("@host").unwrap_err(), ParseError::EmptyUser);
        assert_eq!(Endpoint::parse("u@").unwrap_err(), ParseError::EmptyHost);
        assert_eq!(Endpoint::parse("u@h:0").unwrap_err(), ParseError::BadPort);
        assert_eq!(
            Endpoint::parse("u@h:99999").unwrap_err(),
            ParseError::BadPort
        );
    }
}
