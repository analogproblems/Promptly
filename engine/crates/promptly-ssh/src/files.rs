//! A remote file system for the file browser: SFTP over a connection that
//! is already open, so browsing a host's files costs no second login.

use std::path::Path;
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

    /// Copy a remote file to a local path, reporting bytes done and the
    /// total as it goes.
    pub async fn download(
        &self,
        remote: &str,
        local: &Path,
        progress: impl Fn(u64, u64),
    ) -> Result<u64, SftpError> {
        let total = self.sftp.metadata(remote).await?.size.unwrap_or(0);
        let mut src = self.sftp.open(remote).await?;
        let mut dst = tokio::fs::File::create(local).await.map_err(|e| {
            SftpError::NoSubsystem(format!("could not create {}: {e}", local.display()))
        })?;
        let mut buf = vec![0u8; CHUNK];
        let mut done = 0u64;
        progress(0, total);
        loop {
            let n = src.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).await.map_err(|e| {
                SftpError::NoSubsystem(format!("could not write {}: {e}", local.display()))
            })?;
            done += n as u64;
            progress(done, total.max(done));
        }
        dst.flush().await.ok();
        src.shutdown().await.ok();
        Ok(done)
    }

    /// Copy a local file to a remote path, replacing what was there.
    pub async fn upload(
        &self,
        local: &Path,
        remote: &str,
        progress: impl Fn(u64, u64),
    ) -> Result<u64, SftpError> {
        let mut src = tokio::fs::File::open(local).await.map_err(|e| {
            SftpError::NoSubsystem(format!("could not read {}: {e}", local.display()))
        })?;
        let total = src.metadata().await.map(|m| m.len()).unwrap_or(0);
        let mut dst = self
            .sftp
            .open_with_flags(
                remote,
                OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
            )
            .await?;
        let mut buf = vec![0u8; CHUNK];
        let mut done = 0u64;
        progress(0, total);
        loop {
            let n = src.read(&mut buf).await.map_err(|e| {
                SftpError::NoSubsystem(format!("could not read {}: {e}", local.display()))
            })?;
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
                .upload(&local, &join(&base, "hello.txt"), |done, total| {
                    seen.lock().unwrap().push((done, total))
                })
                .await
                .unwrap();
            assert_eq!(n, body.len() as u64);
            let calls = seen.lock().unwrap().clone();
            assert!(calls.len() >= 2, "{calls:?}");
            assert_eq!(calls.last().unwrap(), &(200_000, 200_000));

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
            fs.rename(&join(&base, "hello.txt"), &join(&base, "sub/moved.txt"))
                .await
                .unwrap();
            let back = dir.join("back.txt");
            let n = fs
                .download(&join(&base, "sub/moved.txt"), &back, |_, _| {})
                .await
                .unwrap();
            assert_eq!(n, 200_000);
            assert_eq!(std::fs::read(&back).unwrap(), body);

            // Delete takes the whole tree.
            fs.delete(&base).await.unwrap();
            assert!(fs.list(&base).await.is_err());
            connection.disconnect().await;
        });
        let _ = std::fs::remove_dir_all(&dir);
    }
}
