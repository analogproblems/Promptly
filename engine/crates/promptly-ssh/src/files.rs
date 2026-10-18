//! A remote file system for the file browser: SFTP over a connection that
//! is already open, so browsing a host's files costs no second login.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use russh_sftp::client::SftpSession;
use russh_sftp::protocol::{FileAttributes, OpenFlags, StatusCode};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::forward::Connection;
use crate::sftp::SftpError;

/// One entry of a remote folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    /// Seconds since the Unix epoch, 0 when the server did not say.
    pub modified: u64,
    /// The permission bits (the low twelve bits of the mode).
    pub permissions: u32,
    pub owner: Option<String>,
    pub group: Option<String>,
}

pub struct RemoteFs {
    sftp: SftpSession,
}

const CHUNK: usize = 64 * 1024;

fn is_status(e: &russh_sftp::client::error::Error, code: StatusCode) -> bool {
    matches!(e, russh_sftp::client::error::Error::Status(s) if s.status_code == code)
}

impl RemoteFs {
    /// Open the SFTP subsystem on an authenticated connection.
    pub async fn open(connection: &Arc<Connection>) -> Result<Self, SftpError> {
        let channel = connection
            .handle()
            .channel_open_session()
            .await
            .map_err(crate::connect::ConnectError::from)?;
        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(|e| SftpError::NoSubsystem(e.to_string()))?;
        let sftp = SftpSession::new(channel.into_stream()).await?;
        Ok(Self { sftp })
    }

    /// The login's home folder, as an absolute path.
    pub async fn home(&self) -> Result<String, SftpError> {
        Ok(self.sftp.canonicalize(".").await?)
    }

    /// Resolve `..` and symlinks the way the server sees them.
    pub async fn canonical(&self, path: &str) -> Result<String, SftpError> {
        Ok(self.sftp.canonicalize(path).await?)
    }

    /// The folder's entries, folders first, each group by name.
    pub async fn list(&self, dir: &str) -> Result<Vec<RemoteEntry>, SftpError> {
        let read = self.sftp.read_dir(dir).await?;
        let mut out: Vec<RemoteEntry> = read
            .filter(|e| {
                let n = e.file_name();
                n != "." && n != ".."
            })
            .map(|e| {
                let m = e.metadata();
                RemoteEntry {
                    name: e.file_name(),
                    is_dir: m.is_dir(),
                    is_symlink: m.is_symlink(),
                    size: m.size.unwrap_or(0),
                    modified: u64::from(m.mtime.unwrap_or(0)),
                    permissions: m.permissions.unwrap_or(0) & 0o7777,
                    owner: m.user.clone(),
                    group: m.group.clone(),
                }
            })
            .collect();
        // A symlink to a folder browses like a folder.
        for e in out.iter_mut().filter(|e| e.is_symlink) {
            let target = join(dir, &e.name);
            if let Ok(m) = self.sftp.metadata(target).await {
                e.is_dir = m.is_dir();
            }
        }
        out.sort_by(|a, b| {
            b.is_dir
                .cmp(&a.is_dir)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(out)
    }

    pub async fn mkdir(&self, path: &str) -> Result<(), SftpError> {
        Ok(self.sftp.create_dir(path).await?)
    }

    pub async fn rename(&self, from: &str, to: &str) -> Result<(), SftpError> {
        Ok(self.sftp.rename(from, to).await?)
    }

    /// Set the permission bits.
    pub async fn chmod(&self, path: &str, mode: u32) -> Result<(), SftpError> {
        let current = self.sftp.metadata(path).await?;
        let kind = current.permissions.unwrap_or(0) & !0o7777;
        let attrs = FileAttributes {
            permissions: Some(kind | (mode & 0o7777)),
            ..FileAttributes::default()
        };
        Ok(self.sftp.set_metadata(path, attrs).await?)
    }

    /// Remove a file, or a folder and everything in it.
    pub async fn delete(&self, path: &str) -> Result<(), SftpError> {
        let meta = match self.sftp.symlink_metadata(path).await {
            Ok(m) => m,
            Err(e) if is_status(&e, StatusCode::NoSuchFile) => return Ok(()),
            Err(e) => return Err(e.into()),
        };
        if meta.is_dir() && !meta.is_symlink() {
            Box::pin(self.delete_tree(path)).await?;
            Ok(())
        } else {
            Ok(self.sftp.remove_file(path).await?)
        }
    }

    async fn delete_tree(&self, dir: &str) -> Result<(), SftpError> {
        for e in self.list(dir).await? {
            let child = join(dir, &e.name);
            if e.is_dir && !e.is_symlink {
                Box::pin(self.delete_tree(&child)).await?;
            } else {
                self.sftp.remove_file(child).await?;
            }
        }
        Ok(self.sftp.remove_dir(dir).await?)
    }

    /// Remove one file, never a folder. One already gone is not an error.
    pub async fn remove_file(&self, path: &str) -> Result<(), SftpError> {
        match self.sftp.remove_file(path).await {
            Err(e) if is_status(&e, StatusCode::NoSuchFile) => Ok(()),
            r => Ok(r?),
        }
    }

    /// A text file's contents, for editing in place. Refuses files over
    /// `max` bytes, files with NUL bytes, and text that is not UTF-8.
    pub async fn read_text(&self, path: &str, max: u64) -> Result<String, SftpError> {
        let size = self.sftp.metadata(path).await?.size.unwrap_or(0);
        if size > max {
            return Err(SftpError::NoSubsystem(format!(
                "too large to edit here ({} bytes); download it instead",
                size
            )));
        }
        let mut src = self.sftp.open(path).await?;
        let mut bytes = Vec::with_capacity(size as usize);
        src.read_to_end(&mut bytes).await?;
        src.shutdown().await.ok();
        if bytes.contains(&0) {
            return Err(SftpError::NoSubsystem("not a text file".into()));
        }
        String::from_utf8(bytes)
            .map_err(|_| SftpError::NoSubsystem("not UTF-8 text; download it instead".into()))
    }

    /// Replace a file's contents with `text`. An existing file keeps its
    /// permissions; a new one gets the server's default. The text is
    /// written beside it first, so a failure leaves the file as it was.
    pub async fn write_text(&self, path: &str, text: &str) -> Result<(), SftpError> {
        let mut src = text.as_bytes();
        self.put_whole(
            &mut src,
            path,
            Put {
                replace: true,
                in_place: true,
                staging: &Staging::new(),
            },
            text.len() as u64,
            |_, _| {},
            "the text",
        )
        .await?;
        Ok(())
    }

    /// Copy a remote file to a local path, reporting bytes done and the
    /// total as it goes. It is written beside `local` first and takes its
    /// place only once whole, so a copy that fails or is stopped leaves
    /// whatever was at `local` as it was. The copy gets the remote file's
    /// permissions, less the usual mask, so a private file stays private.
    /// The file it is written to first is named by `staging`.
    pub async fn download(
        &self,
        remote: &str,
        local: &Path,
        staging: &Staging,
        progress: impl Fn(u64, u64),
    ) -> Result<u64, SftpError> {
        let meta = self.sftp.metadata(remote).await?;
        let total = meta.size.unwrap_or(0);
        let mut src = self.sftp.open(remote).await?;
        let part = staging.local_part(local);
        let cant_write = |e: io::Error| {
            SftpError::NoSubsystem(format!("could not write {}: {e}", local.display()))
        };
        // Made new, so nothing already there (or a link to somewhere else)
        // is written through.
        let mut opts = tokio::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        opts.mode(match meta.permissions.map(|p| p & 0o777) {
            Some(p) if p != 0 => p | 0o600,
            _ => 0o644,
        });
        let mut dst = opts.open(&part).await.map_err(|e| {
            SftpError::NoSubsystem(format!("could not create {}: {e}", local.display()))
        })?;
        let copied = async {
            let mut buf = vec![0u8; CHUNK];
            let mut done = 0u64;
            progress(0, total);
            loop {
                let n = src.read(&mut buf).await?;
                if n == 0 {
                    break;
                }
                dst.write_all(&buf[..n]).await.map_err(cant_write)?;
                done += n as u64;
                progress(done, total.max(done));
            }
            // Writes are only known to have worked once flushed.
            dst.flush().await.map_err(cant_write)?;
            dst.sync_all().await.map_err(cant_write)?;
            Ok::<_, SftpError>(done)
        }
        .await;
        src.shutdown().await.ok();
        drop(dst);
        let done = match copied {
            Ok(done) => done,
            Err(e) => {
                let _ = tokio::fs::remove_file(&part).await;
                return Err(e);
            }
        };
        if let Err(e) = tokio::fs::rename(&part, local).await {
            let _ = tokio::fs::remove_file(&part).await;
            return Err(cant_write(e));
        }
        Ok(done)
    }

    /// Copy a local file to a remote path. What is already there is
    /// replaced only when `replace` says so; otherwise the upload is
    /// refused and the server's file left alone. The copy is written
    /// beside the target first, under the names `staging` gives, so a
    /// failed or stopped upload never harms the file already there.
    pub async fn upload(
        &self,
        local: &Path,
        remote: &str,
        replace: bool,
        staging: &Staging,
        progress: impl Fn(u64, u64),
    ) -> Result<u64, SftpError> {
        let mut src = tokio::fs::File::open(local).await.map_err(|e| {
            SftpError::NoSubsystem(format!("could not read {}: {e}", local.display()))
        })?;
        let total = src.metadata().await.map(|m| m.len()).unwrap_or(0);
        let what = local.display().to_string();
        let how = Put {
            replace,
            in_place: false,
            staging,
        };
        self.put_whole(&mut src, remote, how, total, progress, &what)
            .await
    }

    /// Tidy up after a copy to `target` that was stopped: its part file
    /// goes, and if it was stopped between moving the old file aside and
    /// putting the new one in its place, the old one goes back. Only the
    /// files named by its own `staging` are touched.
    pub async fn abandon(&self, target: &str, staging: &Staging) -> Result<(), SftpError> {
        self.remove_file(&staging.part(target)).await?;
        let old = staging.old(target);
        if self.sftp.metadata(&old).await.is_ok() {
            if self.sftp.metadata(target).await.is_ok() {
                self.remove_file(&old).await?;
            } else {
                self.sftp.rename(&old, target).await?;
            }
        }
        Ok(())
    }

    /// Write everything `src` gives to `remote` by way of a part file
    /// beside it, which takes its place once whole and keeps the old
    /// file's permissions.
    async fn put_whole(
        &self,
        src: &mut (impl tokio::io::AsyncRead + Unpin),
        remote: &str,
        how: Put<'_>,
        total: u64,
        progress: impl Fn(u64, u64),
        what: &str,
    ) -> Result<u64, SftpError> {
        let existing = match self.sftp.metadata(remote).await {
            Ok(m) => Some(m),
            Err(e) if is_status(&e, StatusCode::NoSuchFile) => None,
            Err(e) => return Err(e.into()),
        };
        let Put {
            replace,
            in_place,
            staging,
        } = how;
        if existing.is_some() && !replace {
            return Err(already_there(remote));
        }
        let part = staging.part(remote);
        // Made new, so nothing already there (or a link to somewhere else)
        // is written through. A copy that replaces a file starts private,
        // so what it holds is never more open than the file it replaces.
        let mut attrs = FileAttributes::default();
        if existing.is_some() {
            attrs.permissions = Some(0o600);
        }
        let new_file = OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE;
        let mut dst = match self
            .sftp
            .open_with_flags_and_attributes(&part, new_file, attrs)
            .await
        {
            Ok(dst) => dst,
            Err(e) if existing.is_some() && is_status(&e, StatusCode::PermissionDenied) => {
                // A folder this login may not add files to, though it may
                // change the file itself. Text from the editor is written
                // in place, the only way left; a copy, which can stop part
                // way, is refused rather than risk the file.
                if !in_place {
                    return Err(SftpError::NoSubsystem(format!(
                        "{remote} was left as it was: copying over it safely needs a file \
                         added beside it first, and this folder does not let you add files."
                    )));
                }
                let write = OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE;
                let mut dst = self.sftp.open_with_flags(remote, write).await?;
                return copy_into(src, &mut dst, total, &progress, what).await;
            }
            Err(e) => return Err(e.into()),
        };
        let done = match copy_into(src, &mut dst, total, &progress, what).await {
            Ok(done) => done,
            Err(e) => {
                drop(dst);
                let _ = self.remove_file(&part).await;
                return Err(e);
            }
        };
        drop(dst);
        let placed = async {
            let Some(old) = existing else {
                // Refused if something appeared there meanwhile.
                return self.sftp.rename(&part, remote).await.map_err(|e| {
                    if !replace && is_status(&e, StatusCode::Failure) {
                        already_there(remote)
                    } else {
                        e.into()
                    }
                });
            };
            if let Some(mode) = old.permissions {
                let attrs = FileAttributes {
                    permissions: Some(mode),
                    ..FileAttributes::default()
                };
                // A server that will not set them leaves the copy as it was
                // made; that is fine only if it is no more open than the old.
                if let Err(e) = self.sftp.set_metadata(&part, attrs).await {
                    let made = self.sftp.metadata(&part).await?.permissions;
                    if made.is_none_or(|m| m & 0o777 & !(mode & 0o777) != 0) {
                        return Err(e.into());
                    }
                }
            }
            // SFTP's rename will not replace a file, so the old one steps
            // aside first and goes once the new one is in its place. The
            // name it steps aside to is this copy's own, and the rename is
            // refused rather than replace anything already there.
            let aside = staging.old(remote);
            self.sftp.rename(remote, &aside).await?;
            if let Err(e) = self.sftp.rename(&part, remote).await {
                let _ = self.sftp.rename(&aside, remote).await;
                return Err(e.into());
            }
            let _ = self.remove_file(&aside).await;
            Ok(())
        }
        .await;
        if let Err(e) = placed {
            let _ = self.remove_file(&part).await;
            return Err(e);
        }
        Ok(done)
    }
}

/// Copy all of `src` into an open remote file and close it.
async fn copy_into(
    src: &mut (impl tokio::io::AsyncRead + Unpin),
    dst: &mut russh_sftp::client::fs::File,
    total: u64,
    progress: &impl Fn(u64, u64),
    what: &str,
) -> Result<u64, SftpError> {
    let mut buf = vec![0u8; CHUNK];
    let mut done = 0u64;
    progress(0, total);
    loop {
        let n = src
            .read(&mut buf)
            .await
            .map_err(|e| SftpError::NoSubsystem(format!("could not read {what}: {e}")))?;
        if n == 0 {
            break;
        }
        dst.write_all(&buf[..n]).await?;
        done += n as u64;
        progress(done, total.max(done));
    }
    dst.shutdown().await?;
    Ok(done)
}

fn already_there(remote: &str) -> SftpError {
    let name = remote.rsplit('/').next().unwrap_or(remote);
    SftpError::Io(io::Error::new(
        io::ErrorKind::AlreadyExists,
        format!(
            "{name} is already on the server, so it was left alone. Upload it again to replace it."
        ),
    ))
}

/// `.name.tag` beside a remote path.
fn sibling(target: &str, tag: &str) -> String {
    match target.rsplit_once('/') {
        Some((dir, name)) => format!("{dir}/.{name}.{tag}"),
        None => format!(".{target}.{tag}"),
    }
}

/// How [`RemoteFs::put_whole`] may treat the file already there.
struct Put<'a> {
    /// Replace a file already there, rather than refuse.
    replace: bool,
    /// Write straight into the file when nothing can be added beside it.
    in_place: bool,
    staging: &'a Staging,
}

/// The names one copy gives the files it writes beside its destination.
/// Each copy has its own, so it never writes over or removes a file that
/// someone else, or another copy, has there.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Staging(String);

impl Staging {
    pub fn new() -> Self {
        Self(format!("{:08x}", rand::random::<u32>()))
    }

    /// Where a copy to `target` is written until it is whole.
    pub fn part(&self, target: &str) -> String {
        sibling(target, &format!("{}.promptly-part", self.0))
    }

    /// Where the file an upload replaces waits while the new one moves in.
    pub fn old(&self, target: &str) -> String {
        sibling(target, &format!("{}.promptly-old", self.0))
    }

    /// Where a download to `target` is written until it is whole.
    pub fn local_part(&self, target: &Path) -> PathBuf {
        let name = target
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        target.with_file_name(format!(".{name}.{}.promptly-part", self.0))
    }
}

impl Default for Staging {
    fn default() -> Self {
        Self::new()
    }
}

/// `dir/name` without doubling the slash.
pub fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connect::{connect_handle, AuthMethod, ConnectParams};
    use crate::hostkey::{HostKeyStatus, KnownHosts};
    use crate::sftp::QuietPrompter;
    use crate::Endpoint;
    use promptly_term::TermSize;
    use std::sync::Mutex;

    /// Trusts whatever key it is shown, for tests.
    struct Trusting;
    impl KnownHosts for Trusting {
        fn check(&self, _host: &str, _port: u16, _key: &russh::keys::PublicKey) -> HostKeyStatus {
            HostKeyStatus::Known
        }
        fn remember(&self, _: &str, _: u16, _: &russh::keys::PublicKey) -> std::io::Result<()> {
            Ok(())
        }
        fn known_algorithms(&self, _: &str, _: u16) -> Vec<russh::keys::Algorithm> {
            Vec::new()
        }
    }

    #[test]
    fn browse_transfer_and_tidy_up() {
        let Some(spec) = std::env::var("PROMPTLY_TEST_SSH").ok() else {
            return;
        };
        let (cred, hostport) = spec.rsplit_once('@').unwrap();
        let (user, password) = cred.split_once(':').unwrap();
        let endpoint = Endpoint::parse(&format!("{user}@{hostport}")).unwrap();
        let params = ConnectParams::new(
            endpoint,
            AuthMethod::Password {
                password: Some(password.to_string()),
            },
            TermSize::default(),
        );
        let dir = std::env::temp_dir().join(format!("promptly-files-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        crate::runtime().block_on(async {
            let connection = Arc::new(
                connect_handle(&params, Arc::new(QuietPrompter), Arc::new(Trusting))
                    .await
                    .expect("connect"),
            );
            let fs = RemoteFs::open(&connection).await.expect("sftp");
            let home = fs.home().await.unwrap();
            assert!(home.starts_with('/'), "{home}");

            let base = join(&home, &format!("promptly-browse-{}", std::process::id()));
            fs.mkdir(&base).await.unwrap();
            fs.mkdir(&join(&base, "sub")).await.unwrap();

            // Upload with progress, then it shows in the listing.
            let local = dir.join("hello.txt");
            let body = vec![b'x'; 200_000];
            std::fs::write(&local, &body).unwrap();
            let seen = Mutex::new(Vec::new());
            let n = fs
                .upload(
                    &local,
                    &join(&base, "hello.txt"),
                    false,
                    &Staging::new(),
                    |done, total| seen.lock().unwrap().push((done, total)),
                )
                .await
                .unwrap();
            assert_eq!(n, body.len() as u64);
            let calls = seen.lock().unwrap().clone();
            assert!(calls.len() >= 2, "{calls:?}");
            assert_eq!(calls.last().unwrap(), &(200_000, 200_000));

            // A file already there is only replaced when asked to be.
            let other = dir.join("other.txt");
            std::fs::write(&other, b"other").unwrap();
            let err = fs
                .upload(
                    &other,
                    &join(&base, "hello.txt"),
                    false,
                    &Staging::new(),
                    |_, _| {},
                )
                .await
                .unwrap_err();
            assert!(err.to_string().contains("already on the server"), "{err}");
            fs.upload(
                &local,
                &join(&base, "hello.txt"),
                true,
                &Staging::new(),
                |_, _| {},
            )
            .await
            .unwrap();
            let gone = join(&base, "never-there.txt");
            fs.remove_file(&gone).await.unwrap();

            let entries = fs.list(&base).await.unwrap();
            let names: Vec<(&str, bool, u64)> = entries
                .iter()
                .map(|e| (e.name.as_str(), e.is_dir, e.size))
                .collect();
            assert_eq!(
                names,
                [("sub", true, names[0].2), ("hello.txt", false, 200_000)]
            );

            // Permissions, rename, download.
            fs.chmod(&join(&base, "hello.txt"), 0o600).await.unwrap();
            let entries = fs.list(&base).await.unwrap();
            assert_eq!(entries[1].permissions, 0o600);
            // Replacing keeps the old file's permissions and leaves nothing
            // beside it.
            fs.upload(
                &other,
                &join(&base, "hello.txt"),
                true,
                &Staging::new(),
                |_, _| {},
            )
            .await
            .unwrap();
            let entries = fs.list(&base).await.unwrap();
            assert_eq!(entries.len(), 2, "{entries:?}");
            assert_eq!((entries[1].size, entries[1].permissions), (5, 0o600));
            fs.upload(
                &local,
                &join(&base, "hello.txt"),
                true,
                &Staging::new(),
                |_, _| {},
            )
            .await
            .unwrap();

            // A copy stopped after moving the old file aside gets it back.
            let target = join(&base, "kept.txt");
            let staging = Staging::new();
            fs.write_text(&target, "keep me").await.unwrap();
            fs.rename(&target, &staging.old(&target)).await.unwrap();
            fs.write_text(&staging.part(&target), "half").await.unwrap();
            fs.abandon(&target, &staging).await.unwrap();
            assert_eq!(fs.read_text(&target, 100).await.unwrap(), "keep me");
            assert_eq!(fs.list(&base).await.unwrap().len(), 3, "nothing left over");

            // A file already where a copy would write beside its target is
            // someone else's: the copy is refused rather than write over it,
            // and another copy's tidying leaves it be.
            let theirs = Staging::new();
            fs.write_text(&theirs.part(&target), "not yours")
                .await
                .unwrap();
            assert!(fs
                .upload(&other, &target, true, &theirs, |_, _| {})
                .await
                .is_err());
            fs.abandon(&target, &Staging::new()).await.unwrap();
            assert_eq!(
                fs.read_text(&theirs.part(&target), 100).await.unwrap(),
                "not yours"
            );
            assert_eq!(fs.read_text(&target, 100).await.unwrap(), "keep me");
            fs.remove_file(&theirs.part(&target)).await.unwrap();

            // In a folder nothing can be added to, a copy leaves the file as
            // it was; the editor, with no other way, writes in place.
            let locked = join(&base, "locked");
            fs.mkdir(&locked).await.unwrap();
            let inside = join(&locked, "f.txt");
            fs.write_text(&inside, "original").await.unwrap();
            fs.chmod(&locked, 0o555).await.unwrap();
            let err = fs
                .upload(&other, &inside, true, &Staging::new(), |_, _| {})
                .await
                .unwrap_err();
            assert!(err.to_string().contains("left as it was"), "{err}");
            assert_eq!(fs.read_text(&inside, 100).await.unwrap(), "original");
            fs.write_text(&inside, "edited").await.unwrap();
            assert_eq!(fs.read_text(&inside, 100).await.unwrap(), "edited");
            fs.chmod(&locked, 0o755).await.unwrap();
            fs.delete(&locked).await.unwrap();
            fs.remove_file(&target).await.unwrap();

            fs.rename(&join(&base, "hello.txt"), &join(&base, "sub/moved.txt"))
                .await
                .unwrap();
            let back = dir.join("back.txt");
            let n = fs
                .download(
                    &join(&base, "sub/moved.txt"),
                    &back,
                    &Staging::new(),
                    |_, _| {},
                )
                .await
                .unwrap();
            assert_eq!(n, 200_000);
            assert_eq!(std::fs::read(&back).unwrap(), body);
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mode = std::fs::metadata(&back).unwrap().permissions().mode();
                assert_eq!(mode & 0o777, 0o600, "a private file stays private");
            }
            // A download never writes through what is already where its
            // part file goes, such as a link to another file.
            #[cfg(unix)]
            {
                let staging = Staging::new();
                let elsewhere = dir.join("elsewhere.txt");
                std::fs::write(&elsewhere, b"untouched").unwrap();
                std::os::unix::fs::symlink(&elsewhere, staging.local_part(&back)).unwrap();
                assert!(fs
                    .download(&join(&base, "sub/moved.txt"), &back, &staging, |_, _| {})
                    .await
                    .is_err());
                assert_eq!(std::fs::read(&elsewhere).unwrap(), b"untouched");
                std::fs::remove_file(staging.local_part(&back)).unwrap();
            }
            let leftovers = std::fs::read_dir(&dir)
                .unwrap()
                .filter(|e| {
                    e.as_ref()
                        .unwrap()
                        .file_name()
                        .to_string_lossy()
                        .ends_with("promptly-part")
                })
                .count();
            assert_eq!(leftovers, 0);
            // A download over a file replaces it; one that fails leaves it.
            std::fs::write(&back, b"mine").unwrap();
            assert!(fs
                .download(
                    &join(&base, "missing.txt"),
                    &back,
                    &Staging::new(),
                    |_, _| {}
                )
                .await
                .is_err());
            assert_eq!(std::fs::read(&back).unwrap(), b"mine");
            fs.download(
                &join(&base, "sub/moved.txt"),
                &back,
                &Staging::new(),
                |_, _| {},
            )
            .await
            .unwrap();
            assert_eq!(std::fs::read(&back).unwrap(), body);

            // Edit in place: read, change, write back, re-read.
            let note = join(&base, "note.txt");
            fs.write_text(&note, "first line\nsecond\n").await.unwrap();
            assert_eq!(
                fs.read_text(&note, 1 << 20).await.unwrap(),
                "first line\nsecond\n"
            );
            fs.write_text(&note, "changed\n").await.unwrap();
            assert_eq!(fs.read_text(&note, 1 << 20).await.unwrap(), "changed\n");
            assert!(fs
                .read_text(&note, 3)
                .await
                .unwrap_err()
                .to_string()
                .contains("too large"));

            // Delete takes the whole tree.
            fs.delete(&base).await.unwrap();
            assert!(fs.list(&base).await.is_err());
            connection.disconnect().await;
        });
        let _ = std::fs::remove_dir_all(&dir);
    }
}
