//! Engine-wide calls: version, the data directory, and the quick-connect parser.

use std::path::PathBuf;
use std::sync::Mutex;

use promptly_ssh::Endpoint;

static DATA_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Where the engine keeps its files (known hosts, later the local database).
/// The app sets this from the platform's application-support directory at
/// startup; until then a sensible per-platform default is used.
pub(crate) fn data_dir() -> PathBuf {
    // Unit tests get a folder of their own, never the real one in the home folder.
    #[cfg(test)]
    {
        static TEST_DIR: std::sync::LazyLock<PathBuf> = std::sync::LazyLock::new(|| {
            std::env::temp_dir().join(format!("promptly-api-test-{}", uuid::Uuid::new_v4()))
        });
        TEST_DIR.clone()
    }
    #[cfg(not(test))]
    platform_data_dir()
}

#[cfg_attr(test, allow(dead_code))]
fn platform_data_dir() -> PathBuf {
    // An override for running several copies side by side, as when testing sync.
    if let Some(d) = std::env::var_os("PROMPTLY_DATA_DIR") {
        return PathBuf::from(d);
    }
    if let Some(d) = DATA_DIR.lock().unwrap().clone() {
        return d;
    }
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"));
    let base = if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        home.as_ref()
            .map(|h| PathBuf::from(h).join("Library").join("Application Support"))
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                home.as_ref()
                    .map(|h| PathBuf::from(h).join(".local").join("share"))
            })
    };
    base.unwrap_or_else(std::env::temp_dir).join("promptly")
}

/// Tell the engine where to keep its files. Call once at startup.
#[flutter_rust_bridge::frb(sync)]
pub fn set_data_dir(path: String) {
    *DATA_DIR.lock().unwrap() = Some(PathBuf::from(path));
}

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
