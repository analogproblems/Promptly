//! Reading OpenSSH's `~/.ssh/config`, so the hosts someone already has can
//! come into Promptly in one go.
//!
//! OpenSSH takes the first value it finds for each keyword across every
//! `Host` block that matches, in file order, with `Include` files spliced
//! in. Only aliases without wildcards become hosts; wildcard blocks still
//! contribute their settings to the aliases they match.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// One host as the config describes it, with settings already resolved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigHost {
    pub alias: String,
    pub hostname: String,
    pub user: Option<String>,
    pub port: Option<u16>,
    /// Expanded (`~` resolved), in the order listed.
    pub identity_files: Vec<PathBuf>,
    pub proxy_jump: Option<String>,
    pub keepalive_seconds: Option<u32>,
    /// `LocalForward`, `RemoteForward` and `DynamicForward` lines, in order.
    pub forwards: Vec<ConfigForward>,
    /// `ForwardAgent yes`.
    pub forward_agent: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigForwardKind {
    Local,
    Remote,
    Dynamic,
}

/// One forward line, parsed. `bind_host` is empty when the line gave none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigForward {
    pub kind: ConfigForwardKind,
    pub bind_host: String,
    pub bind_port: u16,
    pub target_host: String,
    pub target_port: u16,
}

/// `[bind:]port host:hostport` for local and remote forwards, `[bind:]port`
/// for dynamic ones. None when the line does not parse.
fn parse_forward(kind: ConfigForwardKind, value: &str) -> Option<ConfigForward> {
    let mut parts = value.split_whitespace();
    let listen = parts.next()?;
    let (bind_host, bind_port) = split_host_port(listen, true)?;
    let (target_host, target_port) = if kind == ConfigForwardKind::Dynamic {
        (String::new(), 0)
    } else {
        split_host_port(parts.next()?, false)?
    };
    Some(ConfigForward {
        kind,
        bind_host,
        bind_port,
        target_host,
        target_port,
    })
}

/// "host:port", "[v6]:port", or just "port" when `port_only_ok`. OpenSSH
/// also accepts "/" as the separator.
fn split_host_port(spec: &str, port_only_ok: bool) -> Option<(String, u16)> {
    let spec = spec.trim();
    if port_only_ok && !spec.contains([':', '/']) {
        return Some((String::new(), spec.parse().ok()?));
    }
    let (host, port) = spec.rsplit_once([':', '/'])?;
    let host = host.trim_matches(['[', ']']);
    Some((host.to_string(), port.parse().ok()?))
}

#[derive(Debug, Default)]
struct Block {
    patterns: Vec<String>,
    settings: Vec<(String, String)>,
}

/// Does an OpenSSH pattern (with `*`, `?` and a leading `!`) match?
fn pattern_matches(pattern: &str, name: &str) -> bool {
    fn glob(p: &[u8], s: &[u8]) -> bool {
        match (p.first(), s.first()) {
            (None, None) => true,
            (Some(b'*'), _) => glob(&p[1..], s) || (!s.is_empty() && glob(p, &s[1..])),
            (Some(b'?'), Some(_)) => glob(&p[1..], &s[1..]),
            (Some(a), Some(b)) if a.eq_ignore_ascii_case(b) => glob(&p[1..], &s[1..]),
            _ => false,
        }
    }
    glob(pattern.as_bytes(), name.as_bytes())
}

/// True when any pattern matches and no negated pattern does.
fn block_matches(patterns: &[String], alias: &str) -> bool {
    let mut matched = false;
    for p in patterns {
        if let Some(neg) = p.strip_prefix('!') {
            if pattern_matches(neg, alias) {
                return false;
            }
        } else if pattern_matches(p, alias) {
            matched = true;
        }
    }
    matched
}

fn is_literal(pattern: &str) -> bool {
    !pattern.is_empty() && !pattern.contains(['*', '?', '!'])
}

fn expand_home(path: &str, home: &Path) -> PathBuf {
    if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest)
    } else if path == "~" {
        home.to_path_buf()
    } else {
        PathBuf::from(path)
    }
}

fn read_blocks(text: &str, ssh_dir: &Path, home: &Path, depth: u8, out: &mut Vec<Block>) {
    let mut current = Block::default();
    let mut in_match = false;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = match line.split_once([' ', '\t', '=']) {
            Some((k, v)) => (
                k.trim().to_ascii_lowercase(),
                v.trim().trim_start_matches('=').trim(),
            ),
            None => (line.to_ascii_lowercase(), ""),
        };
        let value = value.trim_matches('"');
        match key.as_str() {
            "host" => {
                if !current.patterns.is_empty() || !current.settings.is_empty() {
                    out.push(std::mem::take(&mut current));
                }
                in_match = false;
                current.patterns = value.split_whitespace().map(str::to_string).collect();
            }
            "match" => {
                // Match blocks depend on runtime conditions; they are skipped.
                if !current.patterns.is_empty() || !current.settings.is_empty() {
                    out.push(std::mem::take(&mut current));
                }
                in_match = true;
            }
            "include" if depth < 4 => {
                for pattern in value.split_whitespace() {
                    let path = if pattern.starts_with('/') || pattern.starts_with('~') {
                        expand_home(pattern, home)
                    } else {
                        ssh_dir.join(pattern)
                    };
                    for file in glob_paths(&path) {
                        if let Ok(included) = std::fs::read_to_string(&file) {
                            // An Include inside a Host block belongs to it; at the
                            // top it is global. Both land in file order.
                            if current.patterns.is_empty() && current.settings.is_empty() {
                                read_blocks(&included, ssh_dir, home, depth + 1, out);
                            } else {
                                let mut nested = Vec::new();
                                read_blocks(&included, ssh_dir, home, depth + 1, &mut nested);
                                for b in nested {
                                    if b.patterns.is_empty() {
                                        current.settings.extend(b.settings);
                                    } else {
                                        out.push(std::mem::take(&mut current));
                                        out.push(b);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ if in_match => {}
            _ => current.settings.push((key, value.to_string())),
        }
    }
    if !current.patterns.is_empty() || !current.settings.is_empty() {
        out.push(current);
    }
}

/// Expand a path that may end in a wildcard file name, like `conf.d/*`.
fn glob_paths(path: &Path) -> Vec<PathBuf> {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    if !name.contains(['*', '?']) {
        return vec![path.to_path_buf()];
    }
    let Some(dir) = path.parent() else {
        return Vec::new();
    };
    let Ok(read) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = read
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file())
        .filter(|p| {
            pattern_matches(
                &name,
                &p.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default(),
            )
        })
        .collect();
    files.sort();
    files
}

/// Parse a config. `ssh_dir` is where relative `Include`s resolve (usually
/// `~/.ssh`) and `home` expands `~`.
pub fn parse(text: &str, ssh_dir: &Path, home: &Path) -> Vec<ConfigHost> {
    let mut blocks = Vec::new();
    read_blocks(text, ssh_dir, home, 0, &mut blocks);
    // Blocks before the first Host line apply to everyone.
    let mut aliases: Vec<String> = Vec::new();
    for b in &blocks {
        for p in &b.patterns {
            if is_literal(p) && !aliases.iter().any(|a| a == p) {
                aliases.push(p.clone());
            }
        }
    }
    aliases
        .into_iter()
        .map(|alias| {
            let mut first: BTreeMap<&str, &str> = BTreeMap::new();
            let mut identity_files: Vec<PathBuf> = Vec::new();
            let mut forwards: Vec<ConfigForward> = Vec::new();
            for b in &blocks {
                if !(b.patterns.is_empty() || block_matches(&b.patterns, &alias)) {
                    continue;
                }
                for (k, v) in &b.settings {
                    let forward_kind = match k.as_str() {
                        "localforward" => Some(ConfigForwardKind::Local),
                        "remoteforward" => Some(ConfigForwardKind::Remote),
                        "dynamicforward" => Some(ConfigForwardKind::Dynamic),
                        _ => None,
                    };
                    if k == "identityfile" {
                        let p = expand_home(v, home);
                        if !identity_files.contains(&p) {
                            identity_files.push(p);
                        }
                    } else if let Some(kind) = forward_kind {
                        if let Some(f) = parse_forward(kind, v) {
                            if !forwards.contains(&f) {
                                forwards.push(f);
                            }
                        }
                    } else {
                        first.entry(k.as_str()).or_insert(v.as_str());
                    }
                }
            }
            ConfigHost {
                hostname: first
                    .get("hostname")
                    .map(|h| h.replace("%h", &alias))
                    .unwrap_or_else(|| alias.clone()),
                user: first.get("user").map(|s| s.to_string()),
                port: first.get("port").and_then(|p| p.parse().ok()),
                identity_files,
                proxy_jump: first
                    .get("proxyjump")
                    .filter(|v| !v.eq_ignore_ascii_case("none"))
                    .map(|s| s.split(',').next().unwrap_or(s).trim().to_string()),
                keepalive_seconds: first
                    .get("serveraliveinterval")
                    .and_then(|p| p.parse().ok()),
                forwards,
                forward_agent: first
                    .get("forwardagent")
                    .is_some_and(|v| v.eq_ignore_ascii_case("yes")),
                alias,
            }
        })
        .collect()
}

/// The user's own config, if there is one.
pub fn load_default() -> Option<Vec<ConfigHost>> {
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)?;
    let ssh_dir = home.join(".ssh");
    let text = std::fs::read_to_string(ssh_dir.join("config")).ok()?;
    Some(parse(&text, &ssh_dir, &home))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_value_wins_and_wildcards_contribute() {
        let text = r#"
# comment
Host *
    ServerAliveInterval 60
    IdentityFile ~/.ssh/id_default

Host web-1 web-2
    HostName %h.example.com
    User deploy
    Port 2222

Host db
    HostName 10.0.0.20
    User postgres
    IdentityFile ~/.ssh/db_key
    ProxyJump web-1
    Port 22
    LocalForward 5432 localhost:5432
    LocalForward 127.0.0.1:8080 [::1]:80
    RemoteForward 9000 127.0.0.1:3000
    DynamicForward 1080
    ForwardAgent yes

Host web-1
    User override-never-wins

Match host db
    User ignored

Host *.internal
    User svc
"#;
        let hosts = parse(text, Path::new("/home/me/.ssh"), Path::new("/home/me"));
        let names: Vec<&str> = hosts.iter().map(|h| h.alias.as_str()).collect();
        assert_eq!(
            names,
            ["web-1", "web-2", "db"],
            "wildcard-only aliases are not hosts"
        );
        let db = &hosts[2];
        assert!(db.forward_agent);
        let described: Vec<String> = db
            .forwards
            .iter()
            .map(|f| {
                format!(
                    "{:?} {}:{} {}:{}",
                    f.kind, f.bind_host, f.bind_port, f.target_host, f.target_port
                )
            })
            .collect();
        assert_eq!(
            described,
            [
                "Local :5432 localhost:5432",
                "Local 127.0.0.1:8080 ::1:80",
                "Remote :9000 127.0.0.1:3000",
                "Dynamic :1080 :0",
            ]
        );
        assert!(!hosts[0].forward_agent);
        let web1 = &hosts[0];
        assert_eq!(web1.hostname, "web-1.example.com");
        assert_eq!(web1.user.as_deref(), Some("deploy"), "first value wins");
        assert_eq!(web1.port, Some(2222));
        assert_eq!(web1.keepalive_seconds, Some(60), "from Host *");
        assert_eq!(
            web1.identity_files,
            [PathBuf::from("/home/me/.ssh/id_default")]
        );
        let db = &hosts[2];
        assert_eq!(db.hostname, "10.0.0.20");
        assert_eq!(db.proxy_jump.as_deref(), Some("web-1"));
        assert_eq!(
            db.identity_files,
            [
                PathBuf::from("/home/me/.ssh/id_default"),
                PathBuf::from("/home/me/.ssh/db_key")
            ]
        );
        assert_eq!(
            db.user.as_deref(),
            Some("postgres"),
            "Match blocks are skipped"
        );
    }

    #[test]
    fn patterns_negate_and_glob() {
        assert!(pattern_matches("*.example.com", "a.example.com"));
        assert!(pattern_matches("web-?", "web-1"));
        assert!(!pattern_matches("web-?", "web-10"));
        assert!(pattern_matches("WEB-1", "web-1"));
        assert!(block_matches(&["*".into(), "!db".into()], "web"));
        assert!(!block_matches(&["*".into(), "!db".into()], "db"));
    }

    #[test]
    fn includes_are_spliced_in_order() {
        let dir = std::env::temp_dir().join(format!("promptly-sshconfig-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let ssh = dir.join(".ssh");
        std::fs::create_dir_all(ssh.join("conf.d")).unwrap();
        std::fs::write(
            ssh.join("conf.d/10-work.conf"),
            "Host work\n  HostName work.example\n  User me\n",
        )
        .unwrap();
        std::fs::write(
            ssh.join("conf.d/20-home.conf"),
            "Host nas\n  HostName nas.local\n",
        )
        .unwrap();
        let text = "Include conf.d/*.conf\nHost *\n  User fallback\n";
        let hosts = parse(text, &ssh, &dir);
        assert_eq!(hosts.len(), 2);
        assert_eq!(hosts[0].alias, "work");
        assert_eq!(hosts[0].user.as_deref(), Some("me"));
        assert_eq!(hosts[1].alias, "nas");
        assert_eq!(hosts[1].user.as_deref(), Some("fallback"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
