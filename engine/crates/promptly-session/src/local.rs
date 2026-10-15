//! A local shell behind a pseudo-terminal: a pty on Unix, ConPTY on Windows.

use std::io::{self, Read, Write};
use std::path::PathBuf;

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use promptly_term::TermSize;

use crate::Transport;

pub struct LocalShell {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
    program: String,
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
            None => CommandBuilder::new_default_prog(),
        };
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env("TERM_PROGRAM", "Promptly");
        if let Some(cwd) = cwd.or_else(dirs_home) {
            cmd.cwd(cwd);
        }
        let program_name = program
            .clone()
            .or_else(|| std::env::var("SHELL").ok())
            .unwrap_or_else(|| "shell".into());

        let child = pair.slave.spawn_command(cmd).map_err(other)?;
        drop(pair.slave);
        let reader = pair.master.try_clone_reader().map_err(other)?;
        let writer = pair.master.take_writer().map_err(other)?;

        Ok((
            Self {
                master: pair.master,
                writer,
                child,
                program: program_name,
            },
            reader,
        ))
    }

    pub fn program(&self) -> &str {
        &self.program
    }
}

impl Transport for LocalShell {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        self.writer.write_all(data)?;
        self.writer.flush()
    }

    fn resize(&mut self, size: TermSize) -> io::Result<()> {
        self.master.resize(pty_size(size)).map_err(other)
    }

    fn exit_code(&mut self) -> Option<i32> {
        // After EOF the child has gone or is going; wait briefly for its status.
        match self.child.wait() {
            Ok(status) => Some(status.exit_code() as i32),
            Err(_) => None,
        }
    }

    fn close(&mut self) {
        let _ = self.child.kill();
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
