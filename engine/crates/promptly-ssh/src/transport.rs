//! Bridges an async russh channel to the blocking `Transport` + `Read` pair
//! that `promptly_session::pump` expects.

use std::io::{self, Read};
use std::sync::{Arc, Mutex};

use promptly_session::Transport;
use promptly_term::TermSize;
use russh::client::Msg;
use russh::ChannelMsg;
use tokio::sync::mpsc as tmpsc;

use crate::forward::Connection;
use crate::runtime;

enum Cmd {
    Data(Vec<u8>),
    Resize(u16, u16),
    Close,
}

pub struct SshTransport {
    cmd: tmpsc::UnboundedSender<Cmd>,
    exit: Arc<Mutex<Option<i32>>>,
    connection: Arc<Connection>,
}

/// How many packets from the server may wait for the terminal. When it
/// falls behind (`cat` of a big file), the connection stops reading and
/// the server is held back, rather than the output piling up in memory.
const QUEUED_PACKETS: usize = 64;

/// Output from the server, readable with blocking reads. Returns 0 (EOF)
/// once the channel closes. Not to be read from inside the async runtime.
pub struct SshReader {
    rx: tmpsc::Receiver<Vec<u8>>,
    pending: Vec<u8>,
    pos: usize,
}

impl SshTransport {
    pub(crate) fn start(
        connection: Arc<Connection>,
        mut read_half: russh::ChannelReadHalf,
        write_half: russh::ChannelWriteHalf<Msg>,
    ) -> (Self, SshReader) {
        let (data_tx, data_rx) = tmpsc::channel::<Vec<u8>>(QUEUED_PACKETS);
        let (cmd_tx, mut cmd_rx) = tmpsc::unbounded_channel::<Cmd>();
        let exit = Arc::new(Mutex::new(None));

        let exit_for_reader = exit.clone();
        runtime().spawn(async move {
            while let Some(msg) = read_half.wait().await {
                match msg {
                    ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. } => {
                        if data_tx.send(data.to_vec()).await.is_err() {
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

        let conn = connection.clone();
        runtime().spawn(async move {
            while let Some(cmd) = cmd_rx.recv().await {
                match cmd {
                    Cmd::Data(bytes) => {
                        if write_half.data(&bytes[..]).await.is_err() {
                            // The connection has gone; its forwards go too,
                            // since no Close will reach this task now.
                            conn.disconnect().await;
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
                        conn.disconnect().await;
                        break;
                    }
                }
            }
        });

        (
            Self {
                cmd: cmd_tx,
                exit,
                connection,
            },
            SshReader {
                rx: data_rx,
                pending: Vec::new(),
                pos: 0,
            },
        )
    }
}

impl SshTransport {
    /// The connection underneath, for forwards and the like.
    pub fn connection(&self) -> Arc<Connection> {
        self.connection.clone()
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
    /// Waits for output, then fills `buf` with as much as is already
    /// waiting, as a read from a local terminal does: one packet per read
    /// would let the terminal fall far behind a fast server.
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let mut n = 0;
        while n < buf.len() {
            if self.pos >= self.pending.len() {
                let next = if n == 0 {
                    self.rx.blocking_recv()
                } else {
                    self.rx.try_recv().ok()
                };
                match next {
                    Some(chunk) => {
                        self.pending = chunk;
                        self.pos = 0;
                    }
                    None => break,
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

#[cfg(test)]
mod tests {
    use super::*;

    fn reader(capacity: usize) -> (tmpsc::Sender<Vec<u8>>, SshReader) {
        let (tx, rx) = tmpsc::channel(capacity);
        (
            tx,
            SshReader {
                rx,
                pending: Vec::new(),
                pos: 0,
            },
        )
    }

    #[test]
    fn a_read_takes_everything_already_waiting() {
        let (tx, mut r) = reader(8);
        for chunk in [&b"one "[..], b"two ", b"three"] {
            tx.try_send(chunk.to_vec()).unwrap();
        }
        let mut buf = [0u8; 64];
        let n = r.read(&mut buf).unwrap();
        assert_eq!(&buf[..n], b"one two three");

        // A small buffer takes what fits, and the rest comes next.
        tx.try_send(b"abcdef".to_vec()).unwrap();
        let mut small = [0u8; 4];
        assert_eq!(r.read(&mut small).unwrap(), 4);
        assert_eq!(&small, b"abcd");
        assert_eq!(r.read(&mut small).unwrap(), 2);
        assert_eq!(&small[..2], b"ef");

        drop(tx);
        assert_eq!(r.read(&mut buf).unwrap(), 0, "closed reads as the end");
    }

    #[test]
    fn a_terminal_that_falls_behind_holds_the_server_back() {
        let (tx, mut r) = reader(QUEUED_PACKETS);
        for _ in 0..QUEUED_PACKETS {
            tx.try_send(vec![b'x'; 16 * 1024]).unwrap();
        }
        assert!(
            tx.try_send(vec![b'x']).is_err(),
            "full: the connection waits instead of keeping more"
        );
        let mut buf = vec![0u8; 64 * 1024];
        assert_eq!(r.read(&mut buf).unwrap(), 64 * 1024);
        assert!(tx.try_send(vec![b'x']).is_ok(), "room again once read");
    }
}
