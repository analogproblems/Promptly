# Promptly design

Promptly is a terminal emulator and SSH client for iOS, Android, macOS, Windows and Linux.

This document is the master design. It describes what Promptly is, what it does, how it is built, how it looks and how it keeps your data safe. The sync design has its own document, [VAULT.md](VAULT.md), because it is the part that makes Promptly different. The build order is in [ROADMAP.md](ROADMAP.md).

Decisions in this document are deliberate. Where a decision is still yours to make, it is listed in the last section.

## 1. Vision

### The problem

Commercial SSH clients are polished, but they tie the one feature everyone needs, syncing hosts and keys across devices, to a subscription. The data involved is tiny: a typical power user has a few dozen hosts, a handful of keys and some snippets, well under a megabyte. Paying over a hundred dollars a year to move that between a phone and a laptop makes no sense, and it means a third party holds your server inventory.

### The idea

Build the app people actually want: beautiful, fast and pleasant to use on a phone, with sync that costs nothing because it uses storage the user already has. Promptly stores your data in an encrypted vault folder on iCloud Drive, Google Drive, Dropbox, OneDrive, WebDAV, S3 or an SSH server you own. The encryption happens on your device. No Promptly server exists.

### Principles

1. **Your storage, your data.** Promptly never operates a server. Sync works against storage the user controls. There is no account to create.
2. **Feel first.** Scrolling is smooth, connecting is instant, the mobile keyboard is a joy rather than a compromise. We measure feel, not feature count.
3. **Open format.** The vault is a documented folder of files. A command-line tool can decrypt, inspect, export and import it. Leaving Promptly is always one command away.
4. **Secure by default, private by default.** Client-side encryption, biometric unlock, hardware-backed keys where the platform offers them, no telemetry unless asked.
5. **One codebase, native feel.** Five platforms from one UI codebase and one engine, with platform conventions respected: menus on desktop, gestures on mobile.
6. **Boring where it should be boring.** Terminal emulation, SSH and cryptography use battle-tested libraries. We innovate in the vault and the UI, not in protocol parsing.

### Who it is for

- Developers and sysadmins who manage a handful to a few hundred hosts and want the same list on every device.
- People who already pay for a Termius-like app and resent paying for sync.
- Privacy-conscious users who do not want a third party holding their server list.
- Small teams who want a shared host list without a vendor: a shared vault folder on a shared drive does it.

## 2. Landscape

Prices change; treat this table as a snapshot to verify before quoting publicly.

| App | Platforms | Sync | Price model | Notes |
|---|---|---|---|---|
| Termius | iOS, Android, macOS, Windows, Linux | Their cloud, Pro only | About $10 a month billed yearly | Beautiful mobile app, Electron on desktop |
| Blink Shell | iOS | iCloud, own format | Subscription | Mosh support, keyboard-centric |
| Prompt 3 (Panic) | iOS, macOS | Panic Sync, their server | Subscription or one-time | Apple only |
| Tabby | Desktop | Via a self-hosted Tabby Web | Free, open source | Desktop only |
| ShellFish | iOS, macOS | iCloud | Paid | Files-app integration focus |

Promptly's gap: cross-platform, open, polished on mobile, and sync that uses the user's own storage in an open format. Nobody occupies all four.

## 3. Platforms

Order is by how fast the author can test on real hardware, not by market size.

| Platform | Order | Notes |
|---|---|---|
| Linux | 1 | First build target and the daily driver for development. Local shell via pty. |
| Windows | 2 | Local shell via ConPTY. |
| Android | 3 | A foreground service keeps sessions alive. First mobile target, so the keyboard bar and gestures are proven here. |
| macOS | 4 | Native menu bar, Cmd shortcuts, local shell. |
| iOS and iPadOS | 5 | The "feel" benchmark once the rest is solid. iPad gets split panes and keyboard shortcuts. |

Because desktop comes first, the local shell moves from M5 to M1: it is the fastest way to exercise the terminal emulator without a server, and it is what makes the desktop app useful on day one.

Minimum versions: iOS 16, Android 9 (API 28), macOS 13, Windows 10, Ubuntu 22.04 or equivalent. These are chosen so the platform crypto and file APIs we need are available.

## 4. Features

Grouped by area. Each line is tagged with the milestone from [ROADMAP.md](ROADMAP.md) where it lands (M1 to M5).

### 4.1 Terminal emulation

- Full xterm-compatible emulation: VT100 through xterm-256color, true 24-bit colour, bold, italic, underline styles (curly, dotted, coloured), strikethrough. (M1)
- Unicode: grapheme clusters, wide CJK characters, emoji, combining marks. Bidirectional text is left as-is, matching other terminals. (M1)
- Scrollback configurable up to 100k lines, searchable with highlight and jump. (M1 scrollback, M3 search)
- Mouse reporting in all modes, so vim, tmux and htop respond to taps and drags. (M1)
- Bracketed paste, with a warning and preview before pasting multi-line text. (M1)
- Alternate screen and synchronized output (DEC 2026) to avoid flicker in full-screen apps. (M1)
- Bell as a visual flash, a haptic, or a sound. (M1)
- OSC 8 clickable hyperlinks; automatic URL, path and IP detection with tap to open or copy. (M2)
- OSC 52 clipboard writes, so tmux and vim can copy to the device clipboard, gated by a setting. (M2)
- Sixel and iTerm2 inline images. (M5)

### 4.2 Connections

- SSH 2 with ed25519, ECDSA and RSA keys; password; keyboard-interactive for two-factor prompts; SSH agent forwarding. (M1 keys and password, M2 the rest)
- Keep-alive and automatic reconnect with exponential backoff; the terminal shows "Reconnecting…" instead of dying. (M1)
- Host key verification that cannot be ignored: fingerprint shown as SHA256 plus randomart on first connect; a changed key is a full-screen warning with an explanation. (M1)
- Connection progress shown as real steps inside the terminal area (Resolving, Connecting, Verifying host key, Authenticating, Opening shell), each fading once done. Errors are explained in plain language with a suggested fix. (M1)
- Jump hosts (ProxyJump), chained. (M3)
- Local, remote and dynamic (SOCKS) port forwarding, saved per host and toggled with one tap. (M3)
- Persistent sessions: a per-host toggle that attaches to a tmux session on the server, so a session survives the phone sleeping or switching networks. Promptly handles the `tmux new -A -s promptly` dance. (M3)
- Local shell on desktop: Linux and macOS via pty, Windows via ConPTY. (M1)
- Mosh: investigated in M5. There is no mature Mosh client library outside the original C++ codebase; persistent sessions via tmux cover most of the need.
- Telnet and serial: not planned.

### 4.3 Hosts

- Host records with label, hostname, port, username, auth method, group, tags, colour, icon, notes, startup command, environment variables, keep-alive, jump host, port forwards and the persistent-session toggle. (M1 core fields, M3 advanced)
- Instant search across label, hostname, tags and notes. The search field also accepts `user@host:port` and connects directly. (M1)
- Recent and favourites. (M1)
- Groups with inherited defaults: a group can set the username, identity or jump host for all its hosts. (M2)
- Import from `~/.ssh/config` and `known_hosts` on desktop, including keys referenced by IdentityFile. (M2)
- Reachability dot: an optional lightweight TCP check so the list shows which hosts are up. (M3)
- Import from a Termius export and from CSV. (M4)

### 4.4 Identities (keys)

- Generate ed25519 (default), ECDSA P-256 and RSA 4096 in one tap. (M1)
- Import by paste, file or QR, in OpenSSH and PEM formats. PuTTY PPK converted on import. (M1 paste and file, M4 PPK)
- Export the public key by copy, share sheet or QR. (M1)
- Private keys are unlocked by biometrics or the device passcode before use. (M1)
- "Install on host": the ssh-copy-id flow built in, using an existing password login. (M2)
- Hardware-backed keys: Secure Enclave on Apple, StrongBox or TEE Keystore on Android. These keys never leave the device and are therefore never synced. They show a chip icon so the user knows. (M5)

### 4.5 Snippets

- Saved commands with a label, tags and optional `{{variables}}` that prompt when run. (M3)
- Run in the current session, or on several hosts at once with a results view per host. (M3)
- A snippet drawer on the mobile keyboard bar. (M3)

### 4.6 SFTP

- File browser per host: list, upload, download, rename, delete, permissions, open in another app. Single pane on phone, dual pane on tablet and desktop with drag and drop. (M3)
- Share-sheet upload on iOS and Android. (M3)
- Edit small text files in place with a simple editor. (M4)

### 4.7 Sync (the vault)

- Everything above, except hardware keys and anything marked "this device only", lives in the vault. (M2)
- Backends in order of arrival: local folder, iCloud Drive, Google Drive, SFTP; then Dropbox, OneDrive, WebDAV, S3, Git, device to device. (M2 first four, M5 the rest)
- Passphrase-based encryption with a recovery key. (M2)
- A new device joins by typing the passphrase or scanning a QR code from an existing device. (M2)
- Full design in [VAULT.md](VAULT.md).

### 4.8 Mobile keyboard and gestures

- Keyboard accessory bar with Esc, Tab, Ctrl, Alt, arrows and common symbols. Modifier keys are sticky: tap once for the next key, double tap to lock. The layout is fully customisable. (M1)
- Arrow keys by sliding a finger on the bar, like a trackpad, with haptic ticks. (M1)
- Two-finger horizontal swipe switches sessions. Pinch changes font size. Double tap selects a word; long press selects with handles and a magnifier. (M1)
- Hardware keyboard: full modifier support, Caps Lock as Esc option, Cmd-to-Ctrl mapping option on iPad. (M2)
- Swipe down from the top edge to search scrollback; swipe up from the keyboard bar to open the snippets drawer. (M3)

### 4.9 Themes and typography

- Ships with JetBrains Mono (with Nerd Font symbols) and uses system fonts for the UI. Users can add any monospace font file. Ligatures on by default, switchable. (M1)
- Built-in theme gallery: Promptly Dark, Promptly Light, Catppuccin (four flavours), Dracula, Nord, Gruvbox, Solarized, One Dark, Tokyo Night, Rosé Pine. Live preview while picking. (M1)
- Per-host colour accent so you always know which box you are typing into. Production hosts can get a red bar. (M1)
- Import any iTerm2, Windows Terminal, Alacritty or base16 theme file. (M4)

### 4.10 Desktop extras

- Native menus and standard shortcuts. (M2)
- Tabs and split panes with keyboard shortcuts. (M3)
- Command palette (Cmd or Ctrl+K): connect to a host, run a snippet, switch theme, open settings. (M3)
- Drag a host from the sidebar onto a pane to connect there. (M3)
- Acts as an SSH agent for other apps, optional. (M5)

### 4.11 Deliberately not included

- An account system, telemetry, analytics, or any Promptly-operated backend.
- Ads or upsells inside the app.
- A web version. The browser cannot give the feel we want and would require a relay server.

## 5. Architecture

### 5.1 Stack decision

**Flutter for the UI, Rust for the engine, joined by flutter_rust_bridge.**

Why this split:

- The parts that define feel and correctness, terminal emulation and SSH, have best-in-class Rust libraries: `alacritty_terminal` (the engine behind the Alacritty terminal) and `russh` (actively maintained, with SFTP via `russh-sftp`). The Dart equivalents are either abandoned (the original xterm.dart, which now lives on only as a fork) or thinly maintained.
- Flutter renders at the display refresh rate on all five platforms from one codebase, and gives full control of the terminal canvas, which we need for selection, links and themes.
- A Rust engine doubles as a headless library. The same crate that syncs in the app powers `promptly-cli`, which is how the "open format" promise is kept honest.
- flutter_rust_bridge v2 generates the glue, including Rust streams as Dart streams, which fits a terminal perfectly: bytes in, screen updates out.

The cost is a two-language build. That path is well trodden (several production apps use it, and there is already a Flutter terminal widget built on Alacritty for desktop that proves the combination) and is set up once in M0.

Insurance: if the Rust toolchain ever becomes a blocker on a platform, the UI layer does not change. A pure-Dart engine (xterm2 plus dartssh2) could be swapped in behind the same interface at reduced performance. This is not the plan; it is noted so the architecture keeps that door open.

### 5.2 Repository layout

```
promptly/
  app/                      Flutter application, all platforms
    lib/
      core/                 theme tokens, routing, dependency injection, platform channels
      features/
        hosts/              list, editor, groups, import
        sessions/           session manager, switcher, thumbnails
        terminal/           renderer, selection, links, keyboard bar
        identities/         keys UI, biometrics gate
        snippets/
        sftp/
        vault/              sync setup, status, device enrolment
        settings/
      rust/                 generated bridge code, never edited by hand
    ios/ android/ macos/ windows/ linux/
  engine/                   Rust workspace
    crates/
      promptly-term/        terminal emulation wrapper, damage tracking, frame stream
      promptly-ssh/         connections, auth, channels, forwards, SFTP, host keys
      promptly-vault/       data model, op log, merge, crypto, backends, sync engine
      promptly-store/       local SQLite state, secret storage adapters
      promptly-api/         the flutter_rust_bridge surface
      promptly-cli/         command-line tool built on promptly-vault
  docs/
  tools/                    scripts for codegen, release, icons
```

### 5.3 Engine crates

**promptly-term.** Wraps `alacritty_terminal::Term`. Owns the grid, scrollback, cursor and modes. Exposes `feed(bytes)` from the SSH channel, `resize(cols, rows)`, and a frame stream: after each batch of input it emits the dirty rows as cells (grapheme, foreground, background, flags) plus cursor state. The UI mirrors the grid and repaints only what changed. Selection and search run on the grid in Rust so results are identical on every platform.

**promptly-ssh.** Built on `russh`. One `Connection` per host, multiplexing channels for the shell, SFTP and forwards. Auth is a state machine so the UI can show a prompt for keyboard-interactive or a key passphrase without blocking. Host key verification is a callback into the UI. Jump hosts open a direct-tcpip channel on the jump connection and run a second SSH handshake over it. Keep-alives and reconnect live here.

**promptly-vault.** The heart of sync: data model types, the operation log, merge rules, encryption, the `Backend` trait and its implementations, and the sync scheduler. Pure Rust with no platform dependencies beyond what each backend needs (an HTTP client for cloud APIs, the filesystem for local, `russh-sftp` for SFTP). Fully specified in [VAULT.md](VAULT.md).

**promptly-store.** The materialised local state in SQLite (`rusqlite`, bundled, with SQLCipher for encryption at rest). Secrets such as the vault key are never in SQLite; they go through a `SecretStore` trait implemented by the platform (Keychain, Android Keystore, Windows Credential Manager, libsecret).

**promptly-api.** A flat set of async functions and streams for the bridge: `connect(host_id)`, `write(session, bytes)`, `frames(session)`, `hosts()`, `sync_now()` and so on. No business logic here; it only adapts.

**promptly-cli.** `promptly vault inspect`, `export`, `import`, `sync`, `devices`, `rotate-passphrase`, `ssh-config`. Installs with `cargo install` or as a release binary. Its existence is a feature.

### 5.4 Flutter app

- State management with Riverpod; navigation with go_router; immutable models generated from the bridge types.
- The terminal widget is a `CustomPainter` over a mirrored grid. Glyphs are rasterised once per grapheme-and-style into an atlas and drawn as quads. A full 200 by 60 grid repaints in well under a frame on a mid-range phone, and rows marked clean are skipped entirely.
- Input: a hidden text field captures IME input so autocorrect and dictation work when wanted, and a raw key listener handles hardware keyboards. The accessory bar sends escape sequences directly.
- Session thumbnails in the Sessions tab are tiny live renders of the same grid at a smaller scale, so you can watch a build finish from the list.

### 5.5 Data flow for one keystroke

1. A key is tapped on the accessory bar or typed.
2. Dart converts it to bytes, respecting sticky modifiers and the application cursor mode reported by the engine.
3. `write(session, bytes)` crosses the bridge.
4. `promptly-ssh` writes to the channel; the server echoes.
5. Channel data is fed to `promptly-term`, which updates the grid and emits a frame with dirty rows.
6. Dart applies the frame to its mirror and schedules a repaint of those rows.

The round trip inside the device is well under a millisecond. What the user feels is network latency, which the status bar shows.

### 5.6 Background behaviour

- iOS suspends apps shortly after backgrounding. Promptly keeps the socket open as long as iOS allows, then on return reconnects automatically. With persistent sessions on, the user lands back in the same tmux session with nothing lost. This is the honest approach; location or audio tricks to stay alive are not used.
- Android runs a foreground service with a notification while sessions are open, so they genuinely stay alive.
- Desktop has no constraint.

## 6. Data model

All records carry `id` (UUID v7), `created_at`, `updated_at` and a `sync` policy (`vault` or `local_only`). Field-level timestamps for merging are handled by the vault layer and not shown here.

```
Host
  label, hostname, port, username
  auth: { kind: identity | password | agent | interactive, identity_id?, password_secret_id? }
  group_id?, tags[], color, icon, notes
  jump_host_id?, keepalive_seconds, startup_command?, env{}
  persistent_session: bool
  port_forwards[]: { kind: local | remote | dynamic, bind_host, bind_port, target_host, target_port, auto }
  last_connected_at?, favourite: bool

Group
  label, parent_id?, color
  defaults: { username?, identity_id?, jump_host_id?, port? }

Identity
  label, key_type: ed25519 | ecdsa | rsa
  public_key                        OpenSSH one-line format
  private_key_secret_id?            absent for hardware keys
  hardware: { platform, handle }?   never synced
  passphrase_secret_id?

Secret
  kind: password | private_key | key_passphrase | backend_credential
  ciphertext                        encrypted with the vault key; see VAULT.md

Snippet
  label, command, tags[], variables[]: { name, default?, prompt }

KnownHost
  host, port, key_type, fingerprint_sha256, public_key, first_seen_at, first_seen_device

Theme
  name, colors: { fg, bg, cursor, selection, ansi[16] }, builtin: bool

Settings                            one record
  theme_id, font_family, font_size, ligatures, keyboard_bar_layout[], bell, scrollback_lines,
  copy_on_select, paste_warning, haptics, app_lock, ...

Device                              one per enrolled device
  name, platform, enrolled_at, last_seen_at, app_version
```

## 7. Look and feel

### 7.1 Design language

Three words: **quiet, quick, monospace**.

- **Quiet.** The terminal is the content; chrome is thin and recedes. No gradients, no glass, no cards inside cards. Dark first, with a true light theme that is not an inverted afterthought.
- **Quick.** Every transition is 150 to 200 ms, ease-out. Lists appear instantly from local state; sync happens behind them. Connecting opens the terminal view immediately and shows progress inside it.
- **Monospace.** The terminal font is the hero. Host labels and snippets use the terminal font too, so the app reads as one thing. UI copy uses the system font.

### 7.2 Tokens

```
Background        #0E1116   light: #FAFAF7
Surface           #161B22   light: #FFFFFF
Border            #262D37   light: #E6E4DD
Text              #E6EDF3   light: #1F2328
Muted text        #8B949E   light: #656D76
Accent            #7CE38B   "prompt green"; light: #1A7F37
Danger            #FF7B72   light: #CF222E
Warning           #E3B341   light: #9A6700
Radius            10 px panels, 6 px controls
Type              UI: system font; code: JetBrains Mono, 14 pt phone, 13 pt desktop
Motion            150 ms controls, 200 ms screens, ease-out; reduced motion honoured
```

The accent is a phosphor green nod to terminal heritage, desaturated enough not to glare on dark backgrounds. The terminal's own colours always come from the active terminal theme, never from UI tokens.

### 7.3 Screens on the phone

**Hosts (home).** A search field at the top doubles as quick-connect. Groups appear as collapsible sections. Each row shows a colour chip with an icon or initial, the label, `user@hostname`, an optional reachability dot and the last-connected time. Swipe right connects; swipe left reveals edit and more. Long press enters multi-select for move-to-group and delete. A floating button adds a host, a group or an import. Bottom tabs: Hosts, Sessions, Snippets, Keys, Settings.

**Sessions.** Live sessions as cards with a small live render of each terminal and the host's colour bar. Tap to open, swipe to close. A badge on the tab shows the count.

**Terminal.** A full-bleed terminal with a slim top bar: host label, a connection pulse (green steady, amber reconnecting) and a chevron that drops a session switcher. Below the terminal sits the keyboard accessory bar, then the system keyboard. The bar hides with a tap and returns with a swipe. Everything else is terminal.

**Host editor.** A grouped form: Basics, Authentication, Advanced, Port forwards, Notes. Values inherited from the group appear as placeholders. A "Test connection" button runs the real connect flow and reports each step.

**Keys.** A list with key type and fingerprint. Generate is one tap with ed25519 preselected. A key's page offers copy public key, share, show QR, install on host, and, behind biometrics, reveal or export the private key.

**Snippets.** A searchable list. Running a snippet with variables shows a small sheet to fill them. "Run on…" picks hosts and shows a per-host result list.

**SFTP.** Breadcrumb path, file list with sizes and dates, pull to refresh, a plus button for upload, swipe for rename and delete. Tablets show local and remote side by side.

**Settings, then Sync.** The one screen that carries the pitch. Headline: "Where should Promptly keep your vault?" Large options with a one-line explanation each: iCloud Drive (recommended on Apple devices), Google Drive, Your own server (SFTP, WebDAV, S3), Dropbox, OneDrive, This device only. Next, choose a passphrase (a strength meter, no arbitrary rules) and save the recovery key. After setup the screen shows a plain status line, "Up to date · synced 2 minutes ago · 3 devices", and a list of devices with a remove option.

### 7.4 Desktop

A hosts panel on the left (toggled with Ctrl+Shift+B), tabs across the top, panes split by Ctrl+Shift+D (right) and Ctrl+Shift+E (down). Command palette on Ctrl+Shift+P. Dragging a host onto a pane connects it there. Standard menus with the shortcuts shown beside each item; nothing custom to learn. The shortcuts carry Shift or Alt on purpose: plain Ctrl+D, Ctrl+W, Ctrl+T, Ctrl+B and Ctrl+K mean something to a shell or to tmux and stay theirs. (Decided in M3; the original draft said Ctrl+D and Ctrl+K.)

### 7.5 Micro-interactions

- A subtle haptic tick when a sticky modifier engages, a firmer one when it locks.
- On connect, the pulse settles from amber to green with a short ease.
- Pasting multi-line text shows a sheet with the text and line count, with "Paste" and "Paste without final newline".
- The host key prompt shows the fingerprint in large monospace with randomart alongside. "Trust this key" is the primary action and nothing is dismissable by accident.
- Pull-to-sync on lists shows a small progress arc, never a spinner that blocks the list.
- Reduced motion and larger text are honoured everywhere. The terminal font scales independently of the UI font.

### 7.6 Accessibility

VoiceOver and TalkBack read the terminal line by line with a "read from cursor" action. All bar keys have labels. Colour is never the only signal: the production-host red bar also carries a label. Contrast meets WCAG AA in both built-in themes.

Done in M4 (the desktop pass; phones get checked with TalkBack on the Play test): every icon-only control has a tooltip, which is also its spoken label; status dots say "Connected", "Connecting" or "Not connected"; decorative marks such as the host colour chip are hidden from screen readers; the terminal exposes its visible text as the value of one "Terminal" node, built only while a screen reader is running. Large text: the main screens lay out at double size without clipping (page headers and settings rows wrap instead of overflowing), and a widget test keeps it that way. Reduced motion: the system setting removes page transitions and the welcome tour's slides. "Read from cursor" and line-by-line navigation inside the terminal are still to do.

## 8. Security and privacy

### 8.1 Threat model

| Threat | Defence |
|---|---|
| Storage provider is breached or curious | Vault files are encrypted on the device with a key derived from your passphrase. The provider holds ciphertext and opaque file names only. |
| Device lost or stolen | The vault key lives in the OS keychain behind biometrics or the passcode. Optional app lock on open and after a timeout. The local database is encrypted at rest. |
| Malicious server you connect to | Host key verification on first connect; a loud warning on change. Agent forwarding is off by default and per-host. |
| Network attacker | SSH as designed. Backend traffic uses TLS or SSH. The vault adds authenticated encryption, so tampering with a file is detected. |
| Malicious app on the same device | Platform sandboxing, keychain access control, and hardware-backed keys that cannot be extracted at all. |
| Us | There is no "us" in the data path. No server, no telemetry, no account. The code is open for inspection. |

### 8.2 Key material

- The vault data key is random; the passphrase only wraps it (details in VAULT.md). Changing the passphrase re-wraps one small value, not the whole vault.
- A recovery key, a second wrap, is generated at setup and the user is told clearly: lose both and the data is gone, nobody can help.
- SSH private keys are stored as secrets encrypted with the vault key. Hardware-backed keys never exist as bytes the app can read.
- All secrets are zeroised in memory after use (`zeroize` crate). Logs never contain key material or passwords, enforced by typed wrappers whose debug output is redacted.

### 8.3 Platform storage

- iOS: Keychain with the "when unlocked, this device only" accessibility class; files under Data Protection.
- Android: Keystore (StrongBox when present) wraps the vault key; EncryptedFile for the database.
- macOS: Keychain. Windows: Credential Manager plus DPAPI. Linux: libsecret with a file fallback that warns.

### 8.4 Supply chain

- Rust dependencies pinned with `Cargo.lock` and audited in CI with `cargo audit` and `cargo deny`. Dart dependencies likewise with `pubspec.lock`.
- Reproducible release builds where the platform allows; signed binaries on all platforms.
- Cryptography comes from the RustCrypto project (`argon2`, `chacha20poly1305`), never hand-rolled.

### 8.5 Privacy

No analytics. No crash reporting unless the user opts in, and then only to a service the user can see in settings. The app makes network connections only to hosts the user configured and to the sync backend the user chose. This is stated in the privacy policy and is verifiable by anyone with a packet capture.

## 9. Licence and price (decided)

Promptly is **free and open source under the MIT licence**. There is no paid tier, no subscription and no in-app purchase. Sync is free because it uses storage the user already has; the app is free because that is the point of the project.

The repository stays private while the author tests early builds. It goes public when the first release is ready. Nothing in the code or the docs should assume privacy: write everything as if it were already public.

If the project ever needs funding, the options that stay true to the promise are a tip jar, sponsorship, or a one-time "support the author" store listing of the same free code.

Decided in M4: the free channels come first (GitHub Releases for Linux, Windows and Android, then Google Play for its one-time fee). The stores that charge every year and need bought signing certificates come later, and a listing there carries a flat one-time price of about $5 to cover that cost, with the same code free on GitHub. See [DISTRIBUTION.md](DISTRIBUTION.md).

## 10. Key decisions log

| Decision | Choice | Why |
|---|---|---|
| UI framework | Flutter | One codebase, five platforms, full canvas control, refresh-rate rendering |
| Engine language | Rust | Best terminal and SSH libraries, memory safety, reusable for the CLI |
| Terminal emulation | `alacritty_terminal` | Proven in a widely used terminal, fast, maintained |
| SSH | `russh` plus `russh-sftp` | Pure Rust, actively maintained, supports everything needed |
| Sync model | Per-device append-only encrypted logs in a folder | No write conflicts on dumb storage, trivial backends, open format |
| Merge strategy | Per-field last-writer-wins with logical clocks | Correct for this data; simple enough to document and verify |
| Cryptography | Argon2id, XChaCha20-Poly1305 | Standard, audited, available in RustCrypto |
| Local database | SQLite with SQLCipher | Boring and reliable; encrypted at rest |
| Background on iOS | Honest reconnect plus tmux persistence | Reliable and App Store safe |
| Mosh | Deferred | No usable library; tmux covers the common case |
| Platform order | Linux, Windows, Android, macOS, iOS | Fastest path to real testing on the author's devices |
| Licence | MIT | Simple, permissive, friendly to contributors |
| Price | Free, no tiers | The project exists to remove a subscription, not to replace it |

## 11. Decisions made and decisions open

Decided on 2026-10-15:

1. **Platform order:** Linux, Windows, Android, macOS, iOS.
2. **Licence:** MIT. **Price:** free. **Visibility:** private until the first release feels ready, then public.
3. **Name:** Promptly. **Accent:** prompt green on near-black, as in the mockups.

Still open, none blocking:

1. **Hardware-backed keys in M5 or earlier.** They are a strong security story but add platform code; the plan keeps them after shipping.
2. **Icon.** Direction: a block cursor in prompt green on near-black. Needs an actual mark before the stores.
