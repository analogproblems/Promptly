//! Milestone 0: prove the round trip and expose the engine version.

use promptly_ssh::Endpoint;

/// Runs once when the Dart side loads the library.
#[flutter_rust_bridge::frb(init)]
pub fn init_engine() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// The engine's version string.
#[flutter_rust_bridge::frb(sync)]
pub fn engine_version() -> String {
    crate::VERSION.to_string()
}

/// A string in, a string out. The milestone 0 "done when" check.
#[flutter_rust_bridge::frb(sync)]
pub fn ping(name: String) -> String {
    let name = name.trim();
    let who = if name.is_empty() { "there" } else { name };
    format!(
        "Hello, {who}. Promptly engine {} is listening.",
        crate::VERSION
    )
}

/// Parse `user@host:port` the way the quick-connect field will.
/// Returns an error message for the UI when the input is not usable.
#[flutter_rust_bridge::frb(sync)]
pub fn parse_endpoint(input: String) -> Result<ParsedEndpoint, String> {
    Endpoint::parse(&input)
        .map(|e| ParsedEndpoint {
            user: e.user,
            host: e.host,
            port: e.port,
        })
        .map_err(|e| e.to_string())
}

pub struct ParsedEndpoint {
    pub user: String,
    pub host: String,
    pub port: u16,
}
