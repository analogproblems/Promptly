//! A local shell behind a pseudo-terminal: a pty on Unix, ConPTY on Windows.

use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::time::Duration;

use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use promptly_term::TermSize;

use crate::Transport;

pub struct LocalShell {
    master: Box<dyn MasterPty + Send>,
    /// Input goes to the pty from its own thread, in order. A program that
    /// stops reading fills the pty, and then only that thread waits: typing
    /// and pasting never block the caller (the app's UI thread).
    writer: mpsc::Sender<Vec<u8>>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    exit: Arc<Exit>,
    program: String,
}

/// The shell's exit, set by the thread that waits on it.
#[derive(Default)]
struct Exit {
    /// `Some` once the shell has gone, with its code if it had one.
    code: Mutex<Option<Option<i32>>>,
    gone: Condvar,
}

/// How long output may still come after the shell exits before the
/// session ends anyway. A background job (`sleep 600 &`, `code . &`) keeps
/// the terminal open after the shell has gone, so its end can't be told
/// from the output alone; on Windows the output never ends by itself.
const AFTER_EXIT: Duration = Duration::from_millis(200);

/// Output from the shell: `None` is the end.
type Chunk = Option<Vec<u8>>;

/// The shell's output, read on a thread of its own so the end can come
/// either from the output closing or from the shell exiting.
struct LocalReader {
    rx: mpsc::Receiver<Chunk>,
    pending: Vec<u8>,
    pos: usize,
    ended: bool,
}

impl Read for LocalReader {
    /// Waits for output, then fills `buf` with as much as is waiting.
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let mut n = 0;
        while n < buf.len() && !self.ended {
            if self.pos >= self.pending.len() {
                let next = if n == 0 {
                    self.rx.recv().ok()
                } else {
                    match self.rx.try_recv() {
                        Ok(chunk) => Some(chunk),
                        Err(mpsc::TryRecvError::Empty) => break,
                        Err(mpsc::TryRecvError::Disconnected) => None,
                    }
                };
                match next.flatten() {
                    Some(chunk) => {
                        self.pending = chunk;
                        self.pos = 0;
                    }
                    None => {
                        self.ended = true;
                        break;
                    }
                }
            }
            let take = (buf.len() - n).min(self.pending.len() - self.pos);
            buf[n..n + take].copy_from_slice(&self.pending[self.pos..self.pos + take]);
            self.pos += take;
            n += take;
        }
        Ok(n)
    }
}

impl LocalShell {
    /// Start `program` (the user's shell when `None`) in a fresh pty of
    /// `size`. Returns the transport and the stream to read output from.
    pub fn spawn(
        size: TermSize,
        program: Option<String>,
        cwd: Option<PathBuf>,
    ) -> io::Result<(Self, Box<dyn Read + Send>)> {
        let pty = native_pty_system();
        let pair = pty.openpty(pty_size(size)).map_err(other)?;

        let mut cmd = match &program {
            Some(p) => CommandBuilder::new(p),
            None => default_shell(),
        };
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env("TERM_PROGRAM", "Promptly");
        if let Some(cwd) = cwd.or_else(dirs_home) {
            cmd.cwd(cwd);
        }
        let program_name = program
            .clone()
            .or_else(default_shell_name)
            .unwrap_or_else(|| "shell".into());

        let mut child = pair.slave.spawn_command(cmd).map_err(other)?;
        drop(pair.slave);
        let killer = child.clone_killer();
        let mut pty_reader = pair.master.try_clone_reader().map_err(other)?;
        let (output, rx) = mpsc::sync_channel::<Chunk>(16);
        let end = output.clone();
        std::thread::Builder::new()
            .name("promptly-pty-output".into())
            .spawn(move || {
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    // A pty reports EIO once the shell and everything it
                    // started have gone; that is the end, not a failure.
                    let n = match pty_reader.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    if output.send(Some(buf[..n].to_vec())).is_err() {
                        return;
                    }
                }
                let _ = output.send(None);
            })?;
        let exit = Arc::new(Exit::default());
        let exit_for_waiter = exit.clone();
        std::thread::Builder::new()
            .name("promptly-pty-wait".into())
            .spawn(move || {
                let code = child.wait().ok().map(|s| s.exit_code() as i32);
                *exit_for_waiter.code.lock().unwrap() = Some(code);
                exit_for_waiter.gone.notify_all();
                std::thread::sleep(AFTER_EXIT);
                let _ = end.send(None);
            })?;
        let reader = LocalReader {
            rx,
            pending: Vec::new(),
            pos: 0,
            ended: false,
        };
        let mut pty_writer = pair.master.take_writer().map_err(other)?;
        let (writer, input) = mpsc::channel::<Vec<u8>>();
        std::thread::Builder::new()
            .name("promptly-pty-input".into())
            .spawn(move || {
                for data in input {
                    if pty_writer
                        .write_all(&data)
                        .and_then(|()| pty_writer.flush())
                        .is_err()
                    {
                        break;
                    }
                }
            })?;

        Ok((
            Self {
                master: pair.master,
                writer,
                killer,
                exit,
                program: program_name,
            },
            Box::new(reader),
        ))
    }

    pub fn program(&self) -> &str {
        &self.program
    }
}

/// The shell to start when none is named: `$SHELL` on Unix (the pty crate
/// reads it), PowerShell on Windows when it is installed, else cmd.
fn default_shell() -> CommandBuilder {
    if cfg!(windows) {
        if let Some(name) = default_shell_name() {
            let mut cmd = CommandBuilder::new(&name);
            if name.to_ascii_lowercase().contains("pwsh")
                || name.to_ascii_lowercase().contains("powershell")
            {
                cmd.arg("-NoLogo");
            }
            return cmd;
        }
    }
    CommandBuilder::new_default_prog()
}

fn default_shell_name() -> Option<String> {
    if cfg!(windows) {
        ["pwsh.exe", "powershell.exe"]
            .into_iter()
            .find(|name| find_on_path(name).is_some())
            .map(str::to_string)
            .or_else(|| std::env::var("COMSPEC").ok())
    } else {
        std::env::var("SHELL").ok()
    }
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|p| p.is_file())
}

impl Transport for LocalShell {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        self.writer
            .send(data.to_vec())
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "the shell has gone"))
    }

    fn resize(&mut self, size: TermSize) -> io::Result<()> {
        self.master.resize(pty_size(size)).map_err(other)
    }

    fn exit_code(&mut self) -> Option<i32> {
        // After the end of the output the shell has gone or is going: wait
        // a little for its status, never long, since the caller holds the
        // session's locks.
        let code = self.exit.code.lock().unwrap();
        let (code, _) = self
            .exit
            .gone
            .wait_timeout_while(code, Duration::from_secs(2), |c| c.is_none())
            .unwrap();
        code.flatten()
    }

    fn close(&mut self) {
        let _ = self.killer.kill();
    }
}

fn pty_size(size: TermSize) -> PtySize {
    PtySize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

fn other(e: impl std::fmt::Display) -> io::Error {
    io::Error::other(e.to_string())
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}
