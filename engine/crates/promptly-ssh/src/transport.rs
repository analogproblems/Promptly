//! Bridges an async russh channel to the blocking `Transport` + `Read` pair
//! that `promptly_session::pump` expects.

use std::io::{self, Read};
use std::sync::{mpsc, Arc, Mutex};

use promptly_session::Transport;
use promptly_term::TermSize;
use russh::client::{Handle, Msg};
use russh::{ChannelMsg, Disconnect};
use tokio::sync::mpsc as tmpsc;

use crate::connect::Handler;
use crate::runtime;

enum Cmd {
    Data(Vec<u8>),
    Resize(u16, u16),
    Close,
}

pub struct SshTransport {
    cmd: tmpsc::UnboundedSender<Cmd>,
    exit: Arc<Mutex<Option<i32>>>,
}

/// Output from the server, readable with blocking reads. Returns 0 (EOF)
/// once the channel closes.
pub struct SshReader {
    rx: mpsc::Receiver<Vec<u8>>,
    pending: Vec<u8>,
    pos: usize,
}

impl SshTransport {
    pub(crate) fn start(
        handle: Handle<Handler>,
        mut read_half: russh::ChannelReadHalf,
        write_half: russh::ChannelWriteHalf<Msg>,
    ) -> (Self, SshReader) {
        let (data_tx, data_rx) = mpsc::channel::<Vec<u8>>();
        let (cmd_tx, mut cmd_rx) = tmpsc::unbounded_channel::<Cmd>();
        let exit = Arc::new(Mutex::new(None));

        let exit_for_reader = exit.clone();
        runtime().spawn(async move {
            while let Some(msg) = read_half.wait().await {
                match msg {
                    ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => {
                        if data_tx.send(data.to_vec()).is_err() {
                            break;
                        }
                    }
                    ChannelMsg::ExitStatus { exit_status } => {
                        *exit_for_reader.lock().unwrap() = Some(exit_status as i32);
                    }
                    // EOF can arrive before the exit status; only Close ends the channel.
                    ChannelMsg::Close => break,
                    _ => {}
                }
            }
            // Dropping data_tx is what makes the reader return EOF.
        });

        runtime().spawn(async move {
            let handle = handle;
            while let Some(cmd) = cmd_rx.recv().await {
                match cmd {
                    Cmd::Data(bytes) => {
                        if write_half.data(&bytes[..]).await.is_err() {
                            break;
                        }
                    }
                    Cmd::Resize(cols, rows) => {
                        let _ = write_half
                            .window_change(u32::from(cols), u32::from(rows), 0, 0)
                            .await;
                    }
                    Cmd::Close => {
                        let _ = write_half.eof().await;
                        let _ = write_half.close().await;
                        let _ = handle
                            .disconnect(Disconnect::ByApplication, "closed by user", "en")
                            .await;
                        break;
                    }
                }
            }
        });

        (
            Self { cmd: cmd_tx, exit },
            SshReader {
                rx: data_rx,
                pending: Vec::new(),
                pos: 0,
            },
        )
    }
}

impl Transport for SshTransport {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        self.cmd
            .send(Cmd::Data(data.to_vec()))
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "the connection is closed"))
    }

    fn resize(&mut self, size: TermSize) -> io::Result<()> {
        self.cmd
            .send(Cmd::Resize(size.cols, size.rows))
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "the connection is closed"))
    }

    fn exit_code(&mut self) -> Option<i32> {
        *self.exit.lock().unwrap()
    }

    fn close(&mut self) {
        let _ = self.cmd.send(Cmd::Close);
    }
}

impl Read for SshReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.pending.len() {
            match self.rx.recv() {
                Ok(chunk) => {
                    self.pending = chunk;
                    self.pos = 0;
                }
                Err(_) => return Ok(0),
            }
        }
        let n = buf.len().min(self.pending.len() - self.pos);
        buf[..n].copy_from_slice(&self.pending[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}
