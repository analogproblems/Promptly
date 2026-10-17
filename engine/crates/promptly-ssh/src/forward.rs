//! An open connection and the port forwards running over it.
//!
//! A [`Connection`] owns the authenticated `russh` handle (and the handles
//! of any jump hosts it runs through, which must stay open for as long as
//! it does) plus the list of forwards the host is configured with. Each
//! forward can be started and stopped on its own while the session is up.
//!
//! - **Local**: Promptly listens on `bind_host:bind_port`; every connection
//!   becomes a `direct-tcpip` channel to `target_host:target_port` on the
//!   far side.
//! - **Remote**: the server listens on `bind_host:bind_port`; every
//!   connection there comes back as a `forwarded-tcpip` channel, which the
//!   handler joins to `target_host:target_port` from here.
//! - **Dynamic**: Promptly runs a small SOCKS5 proxy on `bind_host:bind_port`;
//!   each client picks its own destination.

use std::collections::HashMap;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::sync::{Arc, Mutex};

use russh::client::{self, Msg};
use russh::Channel;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

use crate::connect::Handler;
use crate::runtime;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForwardKind {
    Local,
    Remote,
    Dynamic,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForwardSpec {
    pub kind: ForwardKind,
    /// Where to listen. Empty means loopback. `0` for the port lets the
    /// system pick one; `bound_port` in the status says which.
    pub bind_host: String,
    pub bind_port: u16,
    /// Unused for dynamic forwards.
    pub target_host: String,
    pub target_port: u16,
    /// Start when the host connects.
    pub auto: bool,
}

impl ForwardSpec {
    /// "8080 → db:5432", "server 9000 → 127.0.0.1:3000", "SOCKS on 1080".
    pub fn describe(&self) -> String {
        match self.kind {
            ForwardKind::Local => format!(
                "{} → {}:{}",
                self.bind_port, self.target_host, self.target_port
            ),
            ForwardKind::Remote => format!(
                "server {} → {}:{}",
                self.bind_port, self.target_host, self.target_port
            ),
            ForwardKind::Dynamic => format!("SOCKS on {}", self.bind_port),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ForwardStatus {
    pub spec: ForwardSpec,
    pub active: bool,
    /// The port in use while active: the one asked for, or the one the
    /// system or server picked for `0`.
    pub bound_port: u16,
    /// Why the last start failed, until the next start.
    pub error: Option<String>,
}

struct ForwardState {
    spec: ForwardSpec,
    active: bool,
    bound_port: u16,
    error: Option<String>,
    task: Option<JoinHandle<()>>,
}

type Targets = Arc<Mutex<HashMap<u32, (String, u16)>>>;

pub struct Connection {
    handle: Arc<client::Handle<Handler>>,
    /// Jump hosts this connection runs through, nearest first.
    hops: Vec<Arc<client::Handle<Handler>>>,
    /// Remote forwards by the port the server listens on, so the handler
    /// knows where a `forwarded-tcpip` channel should go.
    remote_targets: Targets,
    forwards: Mutex<Vec<ForwardState>>,
    server: String,
}

impl Connection {
    pub(crate) fn new(
        handle: client::Handle<Handler>,
        hops: Vec<Arc<client::Handle<Handler>>>,
        remote_targets: Targets,
        server: String,
    ) -> Self {
        Self {
            handle: Arc::new(handle),
            hops,
            remote_targets,
            forwards: Mutex::new(Vec::new()),
            server,
        }
    }

    /// The server this reaches, as `host:port`, to tell one server's files
    /// from another's.
    pub fn server(&self) -> &str {
        &self.server
    }

    pub fn handle(&self) -> &Arc<client::Handle<Handler>> {
        &self.handle
    }

    /// Every handle this connection keeps open, nearest first, for use as
    /// the hops of a connection made through it.
    pub(crate) fn into_handles(self) -> Vec<Arc<client::Handle<Handler>>> {
        let mut hops = self.hops;
        hops.push(self.handle);
        hops
    }

    /// Add a forward to the list; starts it straight away when `auto` is
    /// set. A failure to start is recorded on the forward, never fatal.
    pub async fn add_forward(&self, spec: ForwardSpec) -> usize {
        let auto = spec.auto;
        let index = {
            let mut list = self.forwards.lock().unwrap();
            list.push(ForwardState {
                spec,
                active: false,
                bound_port: 0,
                error: None,
                task: None,
            });
            list.len() - 1
        };
        if auto {
            let _ = self.start_forward(index).await;
        }
        index
    }

    pub fn forwards(&self) -> Vec<ForwardStatus> {
        self.forwards
            .lock()
            .unwrap()
            .iter()
            .map(|f| ForwardStatus {
                spec: f.spec.clone(),
                active: f.active,
                bound_port: f.bound_port,
                error: f.error.clone(),
            })
            .collect()
    }

    /// Start forward `index`. Returns the port in use.
    pub async fn start_forward(&self, index: usize) -> Result<u16, String> {
        let spec = {
            let list = self.forwards.lock().unwrap();
            let state = list.get(index).ok_or("no such forward")?;
            if state.active {
                return Ok(state.bound_port);
            }
            state.spec.clone()
        };
        let result = match spec.kind {
            ForwardKind::Local => start_local(self.handle.clone(), &spec).await,
            ForwardKind::Dynamic => start_dynamic(self.handle.clone(), &spec).await,
            ForwardKind::Remote => start_remote(&self.handle, &self.remote_targets, &spec)
                .await
                .map(|port| (port, None)),
        };
        let mut list = self.forwards.lock().unwrap();
        let state = list.get_mut(index).ok_or("no such forward")?;
        match result {
            Ok((port, task)) => {
                state.active = true;
                state.bound_port = port;
                state.error = None;
                state.task = task;
                Ok(port)
            }
            Err(e) => {
                state.active = false;
                state.error = Some(e.clone());
                Err(e)
            }
        }
    }

    pub async fn stop_forward(&self, index: usize) {
        let stopping = {
            let mut list = self.forwards.lock().unwrap();
            let Some(state) = list.get_mut(index) else {
                return;
            };
            if !state.active {
                return;
            }
            state.active = false;
            (state.spec.clone(), state.bound_port, state.task.take())
        };
        let (spec, port, task) = stopping;
        if let Some(task) = task {
            // Abort schedules the stop; waiting on the task is what makes
            // sure the listener is gone before this returns.
            task.abort();
            let _ = task.await;
        }
        if spec.kind == ForwardKind::Remote {
            self.remote_targets.lock().unwrap().remove(&u32::from(port));
            let _ = self
                .handle
                .cancel_tcpip_forward(remote_bind(&spec), u32::from(port))
                .await;
        }
    }

    /// Close this connection and the jump hosts it came through.
    pub async fn disconnect(&self) {
        for f in self.forwards.lock().unwrap().iter_mut() {
            if let Some(task) = f.task.take() {
                task.abort();
            }
        }
        let _ = self
            .handle
            .disconnect(russh::Disconnect::ByApplication, "closed by user", "en")
            .await;
        for hop in self.hops.iter().rev() {
            let _ = hop
                .disconnect(russh::Disconnect::ByApplication, "closed by user", "en")
                .await;
        }
    }
}

fn local_bind(spec: &ForwardSpec) -> (String, u16) {
    let host = match spec.bind_host.trim() {
        "" | "localhost" => "127.0.0.1".to_string(),
        "*" => "0.0.0.0".to_string(),
        other => other.to_string(),
    };
    (host, spec.bind_port)
}

/// What to ask the server to bind. The protocol's "" means every
/// interface and "localhost" means loopback only.
fn remote_bind(spec: &ForwardSpec) -> String {
    match spec.bind_host.trim() {
        "" | "localhost" | "127.0.0.1" => "localhost".to_string(),
        "*" | "0.0.0.0" => String::new(),
        other => other.to_string(),
    }
}

fn friendly_bind_error(host: &str, port: u16, e: &io::Error) -> String {
    match e.kind() {
        io::ErrorKind::AddrInUse => format!("port {port} is already in use on this device"),
        io::ErrorKind::PermissionDenied => {
            format!("this device does not allow listening on port {port}")
        }
        io::ErrorKind::AddrNotAvailable => format!("{host} is not an address of this device"),
        _ => format!("could not listen on {host}:{port}: {e}"),
    }
}

async fn start_local(
    handle: Arc<client::Handle<Handler>>,
    spec: &ForwardSpec,
) -> Result<(u16, Option<JoinHandle<()>>), String> {
    let (host, port) = local_bind(spec);
    let listener = TcpListener::bind((host.as_str(), port))
        .await
        .map_err(|e| friendly_bind_error(&host, port, &e))?;
    let bound = listener.local_addr().map(|a| a.port()).unwrap_or(port);
    let target_host = spec.target_host.clone();
    let target_port = spec.target_port;
    let task = runtime().spawn(async move {
        loop {
            let Ok((mut tcp, peer)) = listener.accept().await else {
                break;
            };
            let handle = handle.clone();
            let target_host = target_host.clone();
            runtime().spawn(async move {
                let opened = handle
                    .channel_open_direct_tcpip(
                        target_host.clone(),
                        u32::from(target_port),
                        peer.ip().to_string(),
                        u32::from(peer.port()),
                    )
                    .await;
                match opened {
                    Ok(channel) => pipe(tcp, channel).await,
                    Err(e) => {
                        tracing::info!("forward to {target_host}:{target_port} refused: {e}");
                        let _ = tcp.shutdown().await;
                    }
                }
            });
        }
    });
    Ok((bound, Some(task)))
}

async fn start_dynamic(
    handle: Arc<client::Handle<Handler>>,
    spec: &ForwardSpec,
) -> Result<(u16, Option<JoinHandle<()>>), String> {
    let (host, port) = local_bind(spec);
    let listener = TcpListener::bind((host.as_str(), port))
        .await
        .map_err(|e| friendly_bind_error(&host, port, &e))?;
    let bound = listener.local_addr().map(|a| a.port()).unwrap_or(port);
    let task = runtime().spawn(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else {
                break;
            };
            let handle = handle.clone();
            runtime().spawn(async move {
                if let Err(e) = socks5(handle, tcp).await {
                    tracing::debug!("socks: {e}");
                }
            });
        }
    });
    Ok((bound, Some(task)))
}

async fn start_remote(
    handle: &client::Handle<Handler>,
    targets: &Targets,
    spec: &ForwardSpec,
) -> Result<u16, String> {
    let chosen = handle
        .tcpip_forward(remote_bind(spec), u32::from(spec.bind_port))
        .await
        .map_err(|e| match e {
            russh::Error::RequestDenied => format!(
                "the server refused to listen on port {}; it may be in use there, or forwarding may be off",
                spec.bind_port
            ),
            other => format!("the server refused the forward: {other}"),
        })?;
    let port = if spec.bind_port == 0 {
        u16::try_from(chosen).unwrap_or(0)
    } else {
        spec.bind_port
    };
    targets.lock().unwrap().insert(
        u32::from(port),
        (spec.target_host.clone(), spec.target_port),
    );
    Ok(port)
}

/// Copy both ways until either side closes.
pub(crate) async fn pipe(mut tcp: TcpStream, channel: Channel<Msg>) {
    let mut stream = channel.into_stream();
    let _ = tokio::io::copy_bidirectional(&mut tcp, &mut stream).await;
    let _ = tcp.shutdown().await;
}

/// The SOCKS5 handshake (RFC 1928), no authentication, CONNECT only.
async fn socks5(handle: Arc<client::Handle<Handler>>, mut tcp: TcpStream) -> io::Result<()> {
    let bad = |what: &str| io::Error::new(io::ErrorKind::InvalidData, what.to_string());
    let mut greeting = [0u8; 2];
    tcp.read_exact(&mut greeting).await?;
    if greeting[0] != 5 {
        return Err(bad("only SOCKS5 is supported"));
    }
    let mut methods = vec![0u8; usize::from(greeting[1])];
    tcp.read_exact(&mut methods).await?;
    tcp.write_all(&[5, 0]).await?;

    let mut head = [0u8; 4];
    tcp.read_exact(&mut head).await?;
    if head[1] != 1 {
        tcp.write_all(&[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
        return Err(bad("only CONNECT is supported"));
    }
    let host = match head[3] {
        1 => {
            let mut a = [0u8; 4];
            tcp.read_exact(&mut a).await?;
            Ipv4Addr::from(a).to_string()
        }
        3 => {
            let mut len = [0u8; 1];
            tcp.read_exact(&mut len).await?;
            let mut name = vec![0u8; usize::from(len[0])];
            tcp.read_exact(&mut name).await?;
            String::from_utf8_lossy(&name).into_owned()
        }
        4 => {
            let mut a = [0u8; 16];
            tcp.read_exact(&mut a).await?;
            Ipv6Addr::from(a).to_string()
        }
        _ => {
            tcp.write_all(&[5, 8, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            return Err(bad("unknown address type"));
        }
    };
    let mut p = [0u8; 2];
    tcp.read_exact(&mut p).await?;
    let port = u16::from_be_bytes(p);

    let peer = tcp.peer_addr()?;
    let opened = handle
        .channel_open_direct_tcpip(
            host.clone(),
            u32::from(port),
            peer.ip().to_string(),
            u32::from(peer.port()),
        )
        .await;
    match opened {
        Ok(channel) => {
            tcp.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            pipe(tcp, channel).await;
            Ok(())
        }
        Err(e) => {
            tcp.write_all(&[5, 5, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            Err(io::Error::other(format!("{host}:{port}: {e}")))
        }
    }
}
