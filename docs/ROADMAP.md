# Roadmap

Milestones are ordered by what unblocks what. Dates are deliberately absent; the order is the commitment. Each milestone ends with a "done when" that is observable, not a checklist.

## M0 · Foundations

Goal: an empty app that builds and runs on Linux, with the engine wired in and the other platforms scaffolded.

- Repository layout from DESIGN.md section 5.2.
- Rust workspace with the engine crates as stubs; `promptly-api` exposing a `ping`.
- Flutter app with the navigation shell, theme tokens, dark and light themes, the five tabs.
- flutter_rust_bridge codegen and build integration, proven on Linux first. Windows, Android, macOS and iOS build setups follow in that order as each device becomes available for testing.
- CI: `cargo test`, `cargo clippy`, `cargo audit`, `flutter analyze`, `flutter test`, and a Linux build on every push. Other platform builds are added to CI as they come online.
- A one-command dev setup script.

Done when: the app launches on a Linux desktop, shows the tab bar, and a button round-trips a string through Rust.

## M1 · Connect

Goal: you can use it daily on your Linux desktop, for local shells and SSH, and prefer it to what you have.

- `promptly-term`: alacritty_terminal wrapped, frame stream, resize, scrollback. **Done.**
- Local shell on desktop (pty on Linux and macOS, ConPTY on Windows), so the terminal is usable before SSH lands. **Done on Linux.**
- Terminal renderer: glyph cache painter, cursor styles, styles and colours, mouse selection with copy and paste. **Done** (touch handles and links still to come).
- Hardware keyboard mapping (Ctrl, Alt, arrows, function keys, app-cursor mode). **Done.** The mobile accessory bar comes with the Android build.
- Gestures: two-finger session switch, pinch zoom, double tap to select a word. Comes with the Android build.
- `promptly-ssh`: connect, password, key and keyboard-interactive auth, shell channel, resize, keep-alive, automatic reconnect with backoff that keeps the screen. **Done.**
- Host key verification flow and known-host storage. **Done** (OpenSSH files; moves into the vault in M2).
- Hosts list, search and quick connect, host editor (basics and auth), flat groups. **Done.**
- Identities: generate, import by paste, copy the public key. **Done** (import from file and the biometric gate come with the mobile builds).
- Sessions tab with live thumbnails, and the host's colour on its session. **Done.**
- Themes: Promptly Dark and Light plus Catppuccin (four flavours), Dracula, Nord, Gruvbox, Solarized, One Dark, Tokyo Night and Rosé Pine; live preview; JetBrains Mono bundled. **Done.**
- Connection progress inside the terminal and plain-language errors. **Done.**

Done when: you have replaced your current terminal and SSH client on Linux for a week.

## M2 · Vault

Goal: the same hosts on all your devices, for free.

- `promptly-vault`: data model, operation log, merge, snapshots, envelope encryption, manifest, enrolment. **Done.** The local store keeps the merged state with a timestamp per field, so it works the same with or without a backend.
- Backends: local folder (**done**; also how Syncthing, Dropbox and the desktop sync clients work), SFTP to a saved host (**done**), Google Drive, iCloud Drive (the last one lands when macOS does).
- Sync setup screen, status line, device list, QR enrolment, recovery key. **Done** (the QR is shown on desktop; scanning comes with the phone builds).
- `promptly-cli` with `inspect`, `export`, `import`, `sync`, `ssh-config`, `change-passphrase`. **Done.**
- Import from `~/.ssh/config` on desktop, with the keys it names. **Done.** Keys trusted on one device are trusted on all: `known_hosts` entries travel in the vault.
- Group defaults (user and key), SSH agent authentication, keyboard-interactive auth, OSC 52 clipboard writes behind a setting. **Done.** Agent forwarding, OSC 8 links, hardware keyboard polish and native desktop menus move to M3.

Done when: a host added on your Linux desktop appears on your Windows machine within a minute via a shared folder or SFTP, and the CLI can export the vault to JSON.

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
- macOS and iOS builds and store setup.
- App icon, store listings, screenshots, privacy policy, a small docs site generated from this folder.
- TestFlight and Play internal testing with a dozen people; fix what they find.

Done when: version 1.0 is on GitHub releases for Linux and Windows, on the Play Store, and on the App Store for macOS and iOS. The repository goes public with it.

## M5 · Beyond

In no particular order, each independently shippable:

- Remaining backends: Dropbox, OneDrive, WebDAV, S3, Git, device to device.
- Hardware-backed keys (Secure Enclave, StrongBox).
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
