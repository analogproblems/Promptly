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
- Group defaults (user and key), SSH agent authentication, keyboard-interactive auth, OSC 52 clipboard writes behind a setting. **Done.** Agent forwarding, OSC 8 links, the desktop menus and the keyboard shortcuts landed with M3.

Done when: a host added on your Linux desktop appears on your Windows machine within a minute via a shared folder or SFTP, and the CLI can export the vault to JSON.

## M3 · Power

Goal: parity with the paid apps on the features people actually use.

- Snippets with variables, run on many hosts, the snippets drawer. **Done.** `{{name}}` in a command becomes a prompt with a default; a snippet runs in a live session from the drawer in the session bar, or on any set of hosts with their stored logins and a result card per host. The drawer on the mobile keyboard bar comes with the Android build.
- SFTP browser, share-sheet upload, dual pane on tablet and desktop. **Done** for the browser: Files opens from a session's bar over its own connection (no second login), lists folders first with sizes and dates, walks the breadcrumb, makes folders, renames, deletes (whole trees), sets permissions, and copies files with a transfers bar. On a desktop window this device's files sit beside the server's and files drag between the two. Share-sheet upload comes with the phone builds.
- Port forwarding (local, remote, dynamic) and jump hosts. **Done.** Forwards are saved per host, start on connect when marked so, and toggle from the session bar; jump hosts chain, each with its own login. Agent forwarding, a startup command and environment variables came with it, and `~/.ssh/config` import picks up `ProxyJump`, the forward lines and `ForwardAgent`.
- Persistent sessions via tmux. **Done.** A per-host switch attaches to `tmux new-session -A -s promptly`, falling back to a plain login shell where tmux is missing.
- Scrollback search. **Done.** Ctrl+Shift+F opens a bar in the session: every match is highlighted, the current one is selected (so Copy works on it) and scrolled into view, Enter walks up through history and Shift+Enter back down, with "3 of 12" alongside. Links came with it: OSC 8 hyperlinks and plain URLs are underlined, Ctrl+click opens them, and the right-click menu offers Open link and Copy link.
- Reachability dots, favourites and recents polish. **Done.** A setting turns on a once-a-minute knock on each host's port (nothing else is sent) and every row gets a dot: up with the time it took, or not reachable. Favourites and the hosts used in the last month sit in their own sections above the full list, and the star on each row toggles a favourite in one tap.
- Desktop: tabs, split panes, command palette, drag a host onto a pane. **Done.** On a window 900 px or wider the Sessions tab is a workspace: tabs across the top, panes split right or down, an empty pane that lists the hosts, a hosts panel to drag them from, a menu bar with the shortcuts beside each item, and Ctrl+Shift+P for everything. The shortcuts all carry Shift or Alt so Ctrl+D, Ctrl+W, Ctrl+T and Ctrl+B stay with the shell and tmux.

Done when: a sysadmin can do a full day of work without opening another SSH client.

Status: built on Linux. What the phone builds bring with them in M4: the snippet drawer on the keyboard bar, share-sheet upload, QR enrolment scanning.

## M4 · Ship

Goal: version 1.0 in people's hands, through the channels that cost nothing first.

The release plan, decided at the start of M4: free distribution first. Builds for Linux, Windows and Android go on GitHub Releases, which costs nothing. Google Play is the one low-cost exception, a one-time developer fee, and is where the Android build gets tested with other people. The stores that need a yearly developer programme and third-party code signing (the App Store for macOS and iOS, a signed Windows installer) wait until the free builds have been tried on real Linux, Windows and Android hardware. If those listings happen later, a flat one-time price of about $5 on those stores covers what they cost to be on; the code stays MIT and the GitHub builds stay free. Details in [DISTRIBUTION.md](DISTRIBUTION.md).

- Onboarding flow (three screens, skippable), empty states, in-app help.
- Accessibility pass: labels for screen readers, large text, reduced motion. TalkBack on a real phone comes with the Play test.
- Theme import (iTerm2, Windows Terminal, Alacritty, base16), PPK import, Termius and CSV import, in-place text editing in SFTP.
- App icon, privacy policy, a small docs site generated from this folder.
- Windows build in CI. Android build in CI, signed with our own upload key.
- GitHub Releases from a tag: Linux tar.gz and .deb, Windows zip, Android APK, checksums, notes from the changelog.
- Play internal testing with a dozen people; fix what they find.
- Deferred to M5 by the release plan: macOS and iOS builds, App Store and TestFlight, a signed Windows installer and the Microsoft Store.

Done when: version 1.0 is on GitHub Releases for Linux, Windows and Android, and on Play internal testing. The repository goes public with it.

## M5 · Beyond

In no particular order, each independently shippable:

- macOS and iOS builds, App Store and TestFlight; a signed Windows installer and the Microsoft Store. Paid listings at a flat one-time price, as the release plan in M4 says.
- Flathub, winget and the other free package channels.
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
