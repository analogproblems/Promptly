//! The file browser: SFTP over a live session's connection. Browsers are
//! kept in a registry by id; transfers run in the background and report
//! progress on request.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use flutter_rust_bridge::frb;
use promptly_ssh::{RemoteFs, SftpError};

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
    fs: Arc<RemoteFs>,
    transfers: Arc<Transfers>,
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

/// Open the file browser for a live SSH session. Returns the browser id.
pub fn files_open(session_id: u32) -> Result<u32, String> {
    let conn = connection(session_id)?;
    let fs = promptly_ssh::runtime()
        .block_on(RemoteFs::open(&conn))
        .map_err(|e| match e {
            SftpError::NoSubsystem(_) => "This server does not offer SFTP.".to_string(),
            other => other.to_string(),
        })?;
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    BROWSERS.lock().unwrap().insert(
        id,
        Arc::new(Browser {
            fs: Arc::new(fs),
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
        .block_on(b.fs.home())
        .map_err(friendly)
}

/// The entries of a folder, folders first.
pub fn files_list(id: u32, path: String) -> Result<Vec<FileEntry>, String> {
    let b = browser(id)?;
    let entries = promptly_ssh::runtime()
        .block_on(b.fs.list(&path))
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
        .block_on(b.fs.canonical(&path))
        .map_err(friendly)
}

pub fn files_mkdir(id: u32, path: String) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs.mkdir(&path))
        .map_err(friendly)
}

pub fn files_rename(id: u32, from: String, to: String) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs.rename(&from, &to))
        .map_err(friendly)
}

/// Remove a file, or a folder with everything in it.
pub fn files_delete(id: u32, path: String) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs.delete(&path))
        .map_err(friendly)
}

pub fn files_chmod(id: u32, path: String, mode: u32) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs.chmod(&path, mode))
        .map_err(friendly)
}

/// The most a file may be to open in the editor.
const MAX_EDIT_BYTES: u64 = 2 * 1024 * 1024;

/// A text file's contents, for the in-place editor.
pub fn files_read_text(id: u32, path: String) -> Result<String, String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs.read_text(&path, MAX_EDIT_BYTES))
        .map_err(friendly)
}

/// Replace a file's contents from the editor.
pub fn files_write_text(id: u32, path: String, text: String) -> Result<(), String> {
    let b = browser(id)?;
    promptly_ssh::runtime()
        .block_on(b.fs.write_text(&path, &text))
        .map_err(friendly)
}

/// Start copying a remote file to a local path. Returns the transfer id;
/// `files_transfers` reports its progress.
#[frb(sync)]
pub fn files_download(id: u32, remote: String, local: String) -> Result<u32, String> {
    let b = browser(id)?;
    let name = remote.rsplit('/').next().unwrap_or(&remote).to_string();
    let fs = b.fs.clone();
    let local = PathBuf::from(local);
    let partial = Partial::Local(local.clone());
    Ok(b.transfers
        .spawn(name, false, partial, move |progress| async move {
            fs.download(&remote, &local, progress)
                .await
                .map_err(friendly)
        }))
}

/// Start copying a local file to a remote path, replacing what is there.
#[frb(sync)]
pub fn files_upload(id: u32, local: String, remote: String) -> Result<u32, String> {
    let b = browser(id)?;
    let name = remote.rsplit('/').next().unwrap_or(&remote).to_string();
    let fs = b.fs.clone();
    let partial = Partial::Remote(remote.clone());
    Ok(b.transfers
        .spawn(name, true, partial, move |progress| async move {
            fs.upload(&PathBuf::from(local), &remote, progress)
                .await
                .map_err(friendly)
        }))
}

/// Stop a running upload or download, and remove the half-written copy it
/// leaves. Nothing happens if it has already finished.
#[frb(sync)]
pub fn files_cancel_transfer(id: u32, transfer: u32) -> Result<(), String> {
    let b = browser(id)?;
    match b.transfers.cancel(transfer) {
        Some(Partial::Local(path)) => {
            let _ = std::fs::remove_file(path);
        }
        Some(Partial::Remote(path)) => {
            let fs = b.fs.clone();
            promptly_ssh::runtime().spawn(async move {
                let _ = fs.delete(&path).await;
            });
        }
        None => {}
    }
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
