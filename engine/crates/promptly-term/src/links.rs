//! Links written in the text of a row: web addresses, file paths and IPv4
//! addresses. OSC 8 hyperlinks live on the cells themselves and are not
//! found here.

use std::sync::LazyLock;

/// What kind of thing a found link is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkKind {
    /// A web address (or ssh://, git://, file://): opened.
    Url,
    /// An absolute or home-relative file path: copied.
    Path,
    /// An IPv4 address, perhaps with a port: copied.
    Address,
}

/// A link in a row's text, as a byte range of that text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Found {
    pub start: usize,
    pub end: usize,
    pub kind: LinkKind,
}

static URL: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r#"(?i)\b(?:https?|ftp|ssh|git|file)://[^\s<>"'`]+"#).expect("url regex")
});

/// `/usr/bin` or `~/src`, starting the text or after a space, quote,
/// bracket, `=` or `:` (as in `user@host:~/src$`). Characters a shell would
/// treat specially end it, and so does `:`, so `grep` output such as
/// `/etc/hosts:12:` gives the file. A lone `/` or `//` is not a path.
static PATH: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r#"(?:^|[\s'"(\[{<=:])(~?/[\p{L}\p{N}._\-+@%~#][\p{L}\p{N}._\-+@%~#/]*)"#)
        .expect("path regex")
});

/// Four numbers from 0 to 255 joined by dots, and an optional port. Whether
/// it stands on its own (not `v1.2.3.4` or `1.2.3.4.5`) is checked after.
static ADDRESS: LazyLock<regex::Regex> = LazyLock::new(|| {
    let octet = r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)";
    regex::Regex::new(&format!(r"(?:{octet}\.){{3}}{octet}(?::(\d{{1,5}}))?"))
        .expect("address regex")
});

/// Punctuation that ends a sentence more often than a link.
const TRAILING: &[char] = &['.', ',', ';', ':', ')', ']', '}', '\'', '"', '!', '?'];

/// Every link in `text`, in order, none overlapping. Web addresses win over
/// paths, and paths over addresses, where they would overlap.
pub fn find(text: &str) -> Vec<Found> {
    let mut out: Vec<Found> = Vec::new();
    for m in URL.find_iter(text) {
        let s = m.as_str().trim_end_matches(TRAILING);
        out.push(Found {
            start: m.start(),
            end: m.start() + s.len(),
            kind: LinkKind::Url,
        });
    }

    let free = |out: &[Found], start: usize, end: usize| {
        out.iter().all(|f| end <= f.start || start >= f.end)
    };

    // Every changed row is searched on every frame; most have neither.
    let paths: Vec<regex::Captures> = if text.contains('/') {
        PATH.captures_iter(text).collect()
    } else {
        Vec::new()
    };
    let addresses: Vec<regex::Captures> = if text.contains('.') {
        ADDRESS.captures_iter(text).collect()
    } else {
        Vec::new()
    };

    for c in paths {
        let m = c.get(1).expect("path group");
        let s = m.as_str().trim_end_matches(TRAILING);
        let body = s.trim_start_matches('~').trim_start_matches('/');
        if body.is_empty() {
            continue;
        }
        let (start, end) = (m.start(), m.start() + s.len());
        if free(&out, start, end) {
            out.push(Found {
                start,
                end,
                kind: LinkKind::Path,
            });
        }
    }

    for c in addresses {
        let m = c.get(0).expect("address match");
        let (start, mut end) = (m.start(), m.end());
        let before = text[..start].chars().next_back();
        if before.is_some_and(|ch| ch.is_alphanumeric() || ch == '.') {
            continue;
        }
        // A port past 65535 is not a port; keep the address alone.
        if let Some(port) = c.get(1) {
            if !port.as_str().parse::<u32>().is_ok_and(|p| p <= 65_535) {
                end = port.start() - 1;
            }
        }
        let mut after = text[end..].chars();
        match after.next() {
            Some(ch) if ch.is_alphanumeric() => continue,
            Some('.') if after.next().is_some_and(|ch| ch.is_alphanumeric()) => continue,
            _ => {}
        }
        if free(&out, start, end) {
            out.push(Found {
                start,
                end,
                kind: LinkKind::Address,
            });
        }
    }

    out.sort_by_key(|f| f.start);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The links in `text` as (text, kind).
    fn links(text: &str) -> Vec<(&str, LinkKind)> {
        find(text)
            .into_iter()
            .map(|f| (&text[f.start..f.end], f.kind))
            .collect()
    }

    #[test]
    fn web_addresses_lose_trailing_punctuation() {
        assert_eq!(
            links("see https://example.com/docs, then (ssh://box)."),
            vec![
                ("https://example.com/docs", LinkKind::Url),
                ("ssh://box", LinkKind::Url),
            ]
        );
    }

    #[test]
    fn absolute_and_home_paths_are_found() {
        assert_eq!(
            links("cat /etc/hosts and ~/src/promptly/README.md."),
            vec![
                ("/etc/hosts", LinkKind::Path),
                ("~/src/promptly/README.md", LinkKind::Path),
            ]
        );
        assert_eq!(
            links("me@box:~/src$ ls"),
            vec![("~/src", LinkKind::Path)],
            "the path in a prompt"
        );
        assert_eq!(
            links("/var/log/syslog:12: oops"),
            vec![("/var/log/syslog", LinkKind::Path)],
            "grep's line number is not part of it"
        );
        assert_eq!(
            links(r#"open("/tmp/x y") PATH=/usr/bin"#),
            vec![("/tmp/x", LinkKind::Path), ("/usr/bin", LinkKind::Path)]
        );
    }

    #[test]
    fn things_that_only_look_like_paths_are_not() {
        for text in [
            "and/or",
            "1/2 cup",
            "2024/01/02",
            "cd /",
            "cd ~",
            "a // comment",
            "w/o",
            "+/-",
        ] {
            assert_eq!(links(text), vec![], "{text}");
        }
        // The path inside a web address is part of the address.
        assert_eq!(
            links("https://example.com/a/b"),
            vec![("https://example.com/a/b", LinkKind::Url)]
        );
    }

    #[test]
    fn ipv4_addresses_with_and_without_ports() {
        assert_eq!(
            links("inet 192.168.1.20/24 from 10.0.0.1:2222, gw 8.8.8.8."),
            vec![
                ("192.168.1.20", LinkKind::Address),
                ("10.0.0.1:2222", LinkKind::Address),
                ("8.8.8.8", LinkKind::Address),
            ]
        );
        assert_eq!(
            links("listen 0.0.0.0:99999"),
            vec![("0.0.0.0", LinkKind::Address)],
            "not a port"
        );
    }

    #[test]
    fn version_numbers_are_not_addresses() {
        for text in [
            "version 1.2.3",
            "v1.2.3.4",
            "1.2.3.4.5",
            "1.2.3.4a",
            "256.1.1.1",
            "1.2.3.400",
            "01.02.03.04",
            "build 10.0.19045",
        ] {
            assert_eq!(links(text), vec![], "{text}");
        }
    }
}
