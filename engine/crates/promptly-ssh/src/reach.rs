//! The reachability dot: a TCP knock on a host's port, nothing more, so
//! the hosts list can show which boxes are up right now.

use std::time::{Duration, Instant};

use tokio::net::TcpStream;

/// How long the connection took, or `None` when the port did not answer
/// within `timeout` (refused, unroutable, or no such name).
pub async fn reach(host: &str, port: u16, timeout: Duration) -> Option<Duration> {
    let started = Instant::now();
    let connect = async {
        let addrs: Vec<std::net::SocketAddr> =
            tokio::net::lookup_host((host, port)).await.ok()?.collect();
        if addrs.is_empty() {
            return None;
        }
        TcpStream::connect(&addrs[..]).await.ok()
    };
    match tokio::time::timeout(timeout, connect).await {
        Ok(Some(_stream)) => Some(started.elapsed()),
        _ => None,
    }
}

/// Knock on every target at once. Results come back in the same order.
pub async fn reach_all(targets: &[(String, u16)], timeout: Duration) -> Vec<Option<Duration>> {
    let handles: Vec<_> = targets
        .iter()
        .map(|(host, port)| {
            let host = host.clone();
            let port = *port;
            crate::runtime().spawn(async move { reach(&host, port, timeout).await })
        })
        .collect();
    let mut out = Vec::with_capacity(handles.len());
    for h in handles {
        out.push(h.await.ok().flatten());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn closed_port_is_down_and_the_test_server_is_up() {
        let timeout = Duration::from_secs(2);
        let results = crate::runtime().block_on(reach_all(
            &[("127.0.0.1".into(), 1), ("no-such-host.invalid".into(), 22)],
            timeout,
        ));
        assert_eq!(results, [None, None]);
        if let Ok(spec) = std::env::var("PROMPTLY_TEST_SSH") {
            let hostport = spec.rsplit_once('@').unwrap().1;
            let (host, port) = hostport.rsplit_once(':').unwrap();
            let up = crate::runtime().block_on(reach(host, port.parse().unwrap(), timeout));
            assert!(up.is_some());
            assert!(up.unwrap() < timeout);
        }
    }
}
