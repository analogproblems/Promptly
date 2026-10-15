# Roadmap

Milestones are ordered by what unblocks what. Dates are deliberately absent; the order is the commitment. Each milestone ends with a "done when" that is observable, not a checklist.

## M0 · Foundations

Goal: an empty app that builds and runs on every first-wave target, with the engine wired in.

- Repository layout from DESIGN.md section 5.2.
- Rust workspace with the engine crates as stubs; `promptly-api` exposing a `ping`.
- Flutter app with the navigation shell, theme tokens, dark and light themes, the five tabs.
- flutter_rust_bridge codegen and build integration for iOS, Android and macOS. Windows and Linux follow in M4.
- CI: `cargo test`, `cargo clippy`, `cargo audit`, `flutter analyze`, `flutter test`, and a build of each platform on every push.
- A one-command dev setup script.

Done when: the app launches on an iPhone, an Android phone and a Mac, shows the tab bar, and a button round-trips a string through Rust.

## M1 · Connect

Goal: you can use it daily for SSH on your phone and prefer it to what you have.

- `promptly-term`: alacritty_terminal wrapped, frame stream, resize, scrollback.
- Terminal renderer: glyph atlas painter, selection with handles, cursor styles, links.
- Keyboard accessory bar with sticky modifiers, trackpad-style arrows, customisable layout.
- Gestures: two-finger session switch, pinch zoom, double tap to select a word.
- `promptly-ssh`: connect, password and key auth, shell channel, resize, keep-alive, reconnect.
- Host key verification flow and known-host storage.
- Hosts list, search and quick connect, host editor (basics and auth), flat groups.
- Identities: generate, import by paste or file, export the public key, biometric gate.
- Sessions tab with live thumbnails.
- Themes: Promptly Dark and Light plus eight popular themes, live preview, JetBrains Mono bundled.
- Connection progress inside the terminal and plain-language errors.

Done when: you have replaced your current app for a week.

## M2 · Vault

Goal: the same hosts on all your devices, for free.

- `promptly-vault`: data model, operation log, merge, snapshots, envelope encryption, manifest, enrolment.
- Backends: local folder, iCloud Drive, Google Drive, SFTP.
- Sync setup screen, status line, device list, QR enrolment, recovery key.
- `promptly-cli` with `inspect`, `export`, `import`, `sync`, `ssh-config`.
- Import from `~/.ssh/config` and `known_hosts` on desktop.
- Group defaults, agent forwarding, keyboard-interactive auth, OSC 8 and OSC 52, hardware keyboard polish, native desktop menus.

Done when: a host added on your phone appears on your Mac within a minute via iCloud, and the CLI can export the vault to JSON.

## M3 · Power

Goal: parity with the paid apps on the features people actually use.

- Snippets with variables, run on many hosts, the snippets drawer.
- SFTP browser, share-sheet upload, dual pane on tablet and desktop.
- Port forwarding (local, remote, dynamic) and jump hosts.
- Persistent sessions via tmux.
- Scrollback search, reachability dots, favourites and recents polish.
- Desktop: tabs, split panes, command palette, drag a host onto a pane.

Done when: a sysadmin can do a full day of work without opening another SSH client.

## M4 · Ship

Goal: on the stores.

- Onboarding flow (three screens, skippable), empty states, in-app help.
- Accessibility pass with VoiceOver and TalkBack. Large text, reduced motion.
- Theme import (iTerm2, Windows Terminal, Alacritty, base16), PPK import, Termius and CSV import, in-place text editing in SFTP.
- Windows and Linux builds.
- App icon, store listings, screenshots, privacy policy, a small docs site generated from this folder.
- TestFlight and Play internal testing with a dozen people; fix what they find.

Done when: version 1.0 is live on the App Store and Play Store, with desktop builds on GitHub releases.

## M5 · Beyond

In no particular order, each independently shippable:

- Remaining backends: Dropbox, OneDrive, WebDAV, S3, Git, device to device.
- Hardware-backed keys (Secure Enclave, StrongBox).
- Local shell on desktop.
- Shared team vaults with badges and per-vault defaults.
- Promptly as an SSH agent for other desktop apps.
- Sixel and inline images.
- A history view for records (who changed what, when) built from the operation log.
- An optional assistant that explains a command or an error, using an API key the user supplies, off by default.
- Mosh, if a viable library appears.
- Watch complications and home-screen widgets showing host reachability.

## What we measure

| Measure | Target |
|---|---|
| Cold start to hosts list | Under 400 ms on a three-year-old phone |
| Tap connect to shell prompt | Under 1.5 s to a host on the local network |
| Scrolling a full 200 by 60 grid | Steady 120 Hz on a current flagship, 60 Hz on a three-year-old phone |
| Sync round trip, change on A visible on B | Under 60 s via iCloud, under 10 s via SFTP |
| Crashes | Zero in a week of daily use before each release |
