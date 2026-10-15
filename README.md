# Promptly

**Your terminal, everywhere. Your data, yours.**

Promptly is a terminal emulator and SSH client for phone, tablet and desktop. It aims to feel as polished as the best commercial apps, with one big difference: it will never ask you to rent a server to sync a few hundred kilobytes of hosts, keys and snippets.

Everything you set up in Promptly lives in an encrypted **vault**: a small folder of files that Promptly keeps wherever you already keep files. iCloud Drive, Google Drive, Dropbox, OneDrive, a WebDAV share, an S3 bucket, or an SSH server you already own. Promptly runs no servers, needs no account, and has nothing to charge you for every month.

## Status

**Milestone 2 under way: the vault.** Set up sync from Settings: pick a folder (one that Syncthing, Dropbox, iCloud Drive or any sync client mirrors), choose a passphrase, write down the recovery code. Every other device joins with the passphrase and gets the same hosts, keys and snippets, encrypted end to end, with nothing but files on storage you already own. A host added on one machine shows up on the other within half a minute. Or keep the vault on a server you already have: pick a saved host and a folder, and Promptly syncs over SFTP with that host's stored login. The `promptly` command-line tool reads the same vault: inspect, export to JSON, import, sync, and write an OpenSSH config. Going the other way, Settings imports the hosts in your `~/.ssh/config` along with the keys they name, and a host can log in with the keys in your SSH agent. A server trusted on one device is trusted on all of them.

**Milestone 1 built, now in daily use on Linux.** Save hosts, generate or import keys, and connect with one tap into a full terminal: colour, styles, scrollback, full-screen programs, host key checking and password, key or two-factor login. Pick from fifteen terminal themes with a live preview. Select text with the mouse and copy it with Ctrl+Shift+C or the right-click menu. The Sessions tab shows a live thumbnail of every open session. A dropped connection comes back by itself, with the screen intact. The milestone is done when it has replaced the old terminal for a week; the touch gestures wait for the Android build. Linux comes first, then Windows, Android, macOS and iOS.

<p>
  <img src="docs/screenshots/m2-sync-place.png" alt="Choosing where the vault lives" width="640">
  <img src="docs/screenshots/m2-sync-recovery.png" alt="The recovery code shown once after creating a vault" width="640">
</p>
<p>
  <img src="docs/screenshots/m2-sync-devices.png" alt="The sync status with two enrolled devices" width="640">
  <img src="docs/screenshots/m2-sync-hosts-arrived.png" alt="The second machine showing hosts added on the first" width="640">
</p>
<p>
  <img src="docs/screenshots/m2-sync-sftp-server.png" alt="Picking a saved host to keep the vault on over SFTP" width="640">
  <img src="docs/screenshots/m2-sync-sftp-status.png" alt="The sync status for a vault kept on a server" width="640">
</p>
<p>
  <img src="docs/screenshots/m2-import-ssh-config.png" alt="Importing hosts and keys from ~/.ssh/config" width="640">
  <img src="docs/screenshots/m2-import-key-login.png" alt="Logged in to an imported host with its imported key" width="640">
</p>
<p>
  <img src="docs/screenshots/m1-hosts-list.png" alt="The saved hosts list on Linux, dark theme" width="640">
  <img src="docs/screenshots/m1-host-editor.png" alt="The host editor with password auth and a remembered password" width="640">
</p>
<p>
  <img src="docs/screenshots/m1-ssh-shell.png" alt="An SSH session connected and running commands on Linux, dark theme" width="640">
  <img src="docs/screenshots/m1-ssh-host-key.png" alt="The first-time host key prompt with fingerprint and randomart" width="640">
</p>
<p>
  <img src="docs/screenshots/m1-sessions-thumbnails.png" alt="The Sessions tab with live thumbnails of an SSH session and a local shell" width="640">
</p>
<p>
  <img src="docs/screenshots/m1-reconnect-dropped.png" alt="An SSH session whose connection just dropped, reconnecting by itself" width="640">
  <img src="docs/screenshots/m1-reconnect-back.png" alt="The same session after reconnecting, with the earlier output still on screen" width="640">
</p>
<p>
  <img src="docs/screenshots/m1-themes-gallery.png" alt="The terminal theme gallery with Dracula selected" width="640">
  <img src="docs/screenshots/m1-theme-dracula.png" alt="A local shell recoloured to Dracula" width="640">
</p>
<p>
  <img src="docs/screenshots/m1-terminal-top.png" alt="Promptly running top in a local shell on Linux" width="640">
  <img src="docs/screenshots/m1-terminal-styles.png" alt="Text styles and colour modes in the terminal" width="640">
</p>

Read the design in this order:

| Document | What it covers |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Vision, principles, features, architecture, look and feel, security |
| [docs/VAULT.md](docs/VAULT.md) | The sync design: vault format, encryption, conflict handling, storage backends |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Milestones from empty repo to app store |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | How to build, run and change it |

## The pitch in one table

| | Termius | Promptly |
|---|---|---|
| Sync hosts and keys across devices | Pro plan, about $10 a month | Free, uses storage you already have |
| Where your data lives | Their servers | Your iCloud, Drive, Dropbox or server |
| Who can read it | Encrypted in their format | Encrypted on your device, open documented format |
| Export | Limited | Full export and a command-line tool, any time |
| Desktop app | Electron | Flutter UI on a Rust engine |

## Principles

1. **No servers, no accounts, no subscription.** Sync uses your storage. Nobody can read your data in transit or at rest because it never reaches anyone but you.
2. **Feel first.** Smooth scrolling at the display's refresh rate, instant connect, a keyboard that works on a phone, themes that look right.
3. **Open format.** The vault is documented; the CLI can decrypt and export everything. You can leave at any time.
4. **Secure by default.** Client-side encryption, hardware-backed keys where available, host key verification you cannot miss.

## Build it

On Ubuntu: `tools/setup.sh`, then `make run`. Everything else is in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Licence

MIT. Free, open source, no paid tier. See [LICENSE](LICENSE).

## Stack

Flutter for the user interface on iOS, Android, macOS, Windows and Linux. Rust for the engine: terminal emulation (`alacritty_terminal`), SSH (`russh`), the vault and its encryption. See [docs/DESIGN.md](docs/DESIGN.md) for the reasoning.
