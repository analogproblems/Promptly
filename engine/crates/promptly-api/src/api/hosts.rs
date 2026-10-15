//! Host-level helpers for the lists: the reachability check.

use std::time::Duration;

pub struct ReachTarget {
    pub id: String,
    pub host: String,
    pub port: u16,
}

pub struct Reachability {
    pub id: String,
    pub reachable: bool,
    /// How long the connection took when it answered.
    pub millis: u32,
}

/// Knock on every host's port at once; each result says whether it
/// answered within `timeout_ms`. Nothing is sent beyond the connection.
pub fn hosts_reachability(targets: Vec<ReachTarget>, timeout_ms: u32) -> Vec<Reachability> {
    let pairs: Vec<(String, u16)> = targets.iter().map(|t| (t.host.clone(), t.port)).collect();
    let timeout = Duration::from_millis(u64::from(timeout_ms.clamp(100, 30_000)));
    let results = promptly_ssh::runtime().block_on(promptly_ssh::reach_all(&pairs, timeout));
    targets
        .into_iter()
        .zip(results)
        .map(|(t, r)| Reachability {
            id: t.id,
            reachable: r.is_some(),
            millis: r.map(|d| d.as_millis() as u32).unwrap_or(0),
        })
        .collect()
}
