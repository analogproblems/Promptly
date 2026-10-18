//! The file browser: SFTP over a live session's connection. Browsers are
//! kept in a registry by id; transfers run in the background and report
//! progress on request.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use flutter_rust_bridge::frb;
use promptly_ssh::{Connection, RemoteFs, SftpError};

use crate::ssh_flow::connection;
use crate::transfers::{Partial, Transfers};

pub struct FileEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    /// Seconds since the Unix epoch, 0 when unknown.
    pub modified: u64,
    /// The permission bits, as in `chmod`.
    pub permissions: u32,
    pub owner: Option<String>,
    pub group: Option<String>,
}

/// One upload or download, as the transfers bar shows it.
pub struct FileTransfer {
    pub id: u32,
    pub name: String,
    pub upload: bool,
    pub done: u64,
    pub total: u64,
    pub finished: bool,
    /// Stopped by the person before it was done.
    pub cancelled: bool,
    pub error: Option<String>,
}

struct Browser {
    session_id: u32,
    /// The connection the files are reached over, and the SFTP channel on
    /// it. A session that reconnects gets a new connection, and the next
    /// call moves over to it, so an open editor can still save.
    open: Mutex<(Arc<Connection>, Arc<RemoteFs>)>,
    /// Which server the files are on, as `host:port`.
    server: String,
    transfers: Arc<Transfers>,
}

impl Browser {
    /// The SFTP channel on the session's current connection.
    fn fs(&self) -> Result<Arc<RemoteFs>, String> {
        let mut open = self.open.lock().unwrap();
        if let Ok(now) = connection(self.session_id) {
            if !Arc::ptr_eq(&now, &open.0) {
                let fs = promptly_ssh::runtime()
                    .block_on(RemoteFs::open(&now))
                    .map_err(open_error)?;
                *open = (now, Arc::new(fs));
            }
        }
        Ok(open.1.clone())
    }
}

static BROWSERS: LazyLock<Mutex<HashMap<u32, Arc<Browser>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_ID: AtomicU32 = AtomicU32::new(1);

fn browser(id: u32) -> Result<Arc<Browser>, String> {
    BROWSERS
        .lock()
        .unwrap()
        .get(&id)
        .cloned()
        .ok_or_else(|| format!("no file browser {id}"))
}

fn friendly(e: SftpError) -> String {
    match e {
        SftpError::Sftp(inner) => {
            let text = inner.to_string();
            if text.contains("Permission denied") || text.contains("PermissionDenied") {
                "The server would not allow that. Check the permissions.".into()
            } else if text.contains("No such file") || text.contains("NoSuchFile") {
                "That is not there any more.".into()
            } else {
                text
            }
        }
        other => other.to_string(),
    }
}

fn open_error(e: SftpError) -> String {
    match e {
        SftpError::NoSubsystem(_) => "This server does not offer SFTP.".to_string(),
        other => other.to_string(),
    }
}

/// Open the file browser for a live SSH session. Returns the browser id.
pub fn files_open(session_id: u32) -> Result<u32, String> {
    let conn = connection(session_id)?;
    let fs = promptly_ssh::runtime()
        .block_on(RemoteFs::open(&conn))
        .map_err(open_error)?;
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    BROWSERS.lock().unwrap().insert(
        id,
        Arc::new(Browser {
            session_id,
            server: conn.server().to_string(),
            open: Mutex::new((conn, Arc::new(fs))),
            transfers: Arc::default(),
        }),
    );
    Ok(id)
}

#[frb(sync)]
pub fn files_close(id: u32) {
    BROWSERS.lock().unwrap().remove(&id);
}

/// The login's home folder.
pub fn files_home(id: u32) -> Result<String, String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs()?.home())
        .map_err(friendly)
}

/// The entries of a folder, folders first.
pub fn files_list(id: u32, path: String) -> Result<Vec<FileEntry>, String> {
    let b = browser(id)?;
    let entries = promptly_ssh::runtime()
        .block_on(b.fs()?.list(&path))
        .map_err(friendly)?;
    Ok(entries
        .into_iter()
        .map(|e| FileEntry {
            name: e.name,
            is_dir: e.is_dir,
            is_symlink: e.is_symlink,
            size: e.size,
            modified: e.modified,
            permissions: e.permissions,
            owner: e.owner,
            group: e.group,
        })
        .collect())
}

/// Resolve a typed path (`..`, `~`-less) as the server sees it.
pub fn files_canonical(id: u32, path: String) -> Result<String, String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs()?.canonical(&path))
        .map_err(friendly)
}

pub fn files_mkdir(id: u32, path: String) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs()?.mkdir(&path))
        .map_err(friendly)
}

pub fn files_rename(id: u32, from: String, to: String) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs()?.rename(&from, &to))
        .map_err(friendly)
}

/// Remove a file, or a folder with everything in it.
pub fn files_delete(id: u32, path: String) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs()?.delete(&path))
        .map_err(friendly)
}

pub fn files_chmod(id: u32, path: String, mode: u32) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs()?.chmod(&path, mode))
        .map_err(friendly)
}

/// The most a file may be to open in the editor.
const MAX_EDIT_BYTES: u64 = 2 * 1024 * 1024;

/// A text file's contents, for the in-place editor.
pub fn files_read_text(id: u32, path: String) -> Result<String, String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs()?.read_text(&path, MAX_EDIT_BYTES))
        .map_err(friendly)
}

/// Replace a file's contents from the editor.
pub fn files_write_text(id: u32, path: String, text: String) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs()?.write_text(&path, &text))
        .map_err(friendly)
}

/// Start copying a remote file to a local path. Returns the transfer id;
/// `files_transfers` reports its progress. A file already there, even one
/// that appears meanwhile, is replaced only with `replace`.
#[frb(sync)]
pub fn files_download(
    id: u32,
    remote: String,
    local: String,
    replace: bool,
) -> Result<u32, String> {
    let b = browser(id)?;
    let name = remote.rsplit('/').next().unwrap_or(&remote).to_string();
    let fs = b.fs()?;
    let local = PathBuf::from(local);
    let partial = Partial::Local(local.clone());
    b.transfers
        .spawn(name, false, partial, move |progress, staging| async move {
            fs.download(&remote, &local, replace, &staging, progress)
                .await
                .map_err(friendly)
        })
}

/// Start copying a local file to a remote path. A file already there is
/// replaced only with `replace`; otherwise the upload fails and leaves it.
#[frb(sync)]
pub fn files_upload(id: u32, local: String, remote: String, replace: bool) -> Result<u32, String> {
    let b = browser(id)?;
    let name = remote.rsplit('/').next().unwrap_or(&remote).to_string();
    let fs = b.fs()?;
    let partial = Partial::Remote(b.server.clone(), remote.clone());
    b.transfers
        .spawn(name, true, partial, move |progress, staging| async move {
            fs.upload(&PathBuf::from(local), &remote, replace, &staging, progress)
                .await
                .map_err(friendly)
        })
}

/// Stop a running upload or download, and remove the half-written copy it
/// leaves beside its destination; what was already there stays. Nothing
/// happens if it has already finished.
#[frb(sync)]
pub fn files_cancel_transfer(id: u32, transfer: u32) -> Result<(), String> {
    let b = browser(id)?;
    let fs = b.fs()?;
    b.transfers
        .cancel(transfer, move |partial, staging| async move {
            match partial {
                Partial::Local(path) => {
                    match tokio::fs::remove_file(staging.local_part(&path)).await {
                        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
                        _ => Ok(()),
                    }
                }
                Partial::Remote(_, path) => fs.abandon(&path, &staging).await.map_err(friendly),
            }
        });
    Ok(())
}

/// Every transfer of a browser, oldest first.
#[frb(sync)]
pub fn files_transfers(id: u32) -> Result<Vec<FileTransfer>, String> {
    Ok(browser(id)?.transfers.snapshot())
}

/// Forget finished transfers.
#[frb(sync)]
pub fn files_clear_transfers(id: u32) -> Result<(), String> {
    browser(id)?.transfers.clear_finished();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ssh_flow::remember_connection;
    use promptly_ssh::{
        Algorithm, AuthMethod, ConnectParams, Endpoint, HostKeyStatus, KnownHosts, PublicKey,
        QuietPrompter,
    };

    struct Trusting;
    impl KnownHosts for Trusting {
        fn check(&self, _: &str, _: u16, _: &PublicKey) -> HostKeyStatus {
            HostKeyStatus::Known
        }
        fn remember(&self, _: &str, _: u16, _: &PublicKey) -> std::io::Result<()> {
            Ok(())
        }
        fn known_algorithms(&self, _: &str, _: u16) -> Vec<Algorithm> {
            Vec::new()
        }
    }

    #[test]
    fn a_browser_moves_to_the_sessions_new_connection() {
        let Ok(spec) = std::env::var("PROMPTLY_TEST_SSH") else {
            return;
        };
        let (cred, hostport) = spec.rsplit_once('@').unwrap();
        let (user, password) = cred.split_once(':').unwrap();
        let params = ConnectParams::new(
            Endpoint::parse(&format!("{user}@{hostport}")).unwrap(),
            AuthMethod::Password {
                password: Some(password.to_string()),
            },
            Default::default(),
        );
        let connect = || {
            Arc::new(
                promptly_ssh::runtime()
                    .block_on(promptly_ssh::connect_handle(
                        &params,
                        Arc::new(QuietPrompter),
                        Arc::new(Trusting),
                    ))
                    .expect("connect"),
            )
        };
        let session = 900_000 + std::process::id() % 1000;
        let first = connect();
        remember_connection(session, first.clone());
        let id = files_open(session).unwrap();
        let home = files_home(id).unwrap();

        // The session reconnects: the old connection is gone.
        remember_connection(session, connect());
        promptly_ssh::runtime().block_on(first.disconnect());
        assert!(files_list(id, home.clone()).is_ok(), "still browsing");
        assert_eq!(files_home(id).unwrap(), home);
        files_close(id);
        crate::ssh_flow::forget_connection(session);
    }
}
