# Promptly

**Your terminal, everywhere. Your data, yours.**

Promptly is a terminal emulator and SSH client for phone, tablet and desktop. It aims to feel as polished as the best commercial apps, with one big difference: it will never ask you to rent a server to sync a few hundred kilobytes of hosts, keys and snippets.

Everything you set up in Promptly lives in an encrypted **vault**: a small folder of files that Promptly keeps wherever you already keep files. iCloud Drive, Google Drive, Dropbox, OneDrive, a WebDAV share, an S3 bucket, or an SSH server you already own. Promptly runs no servers, needs no account, and has nothing to charge you for every month.

## Status

**Design phase.** Nothing runs yet. This repository currently holds the design, best read in this order:

| Document | What it covers |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Vision, principles, features, architecture, look and feel, security |
| [docs/VAULT.md](docs/VAULT.md) | The sync design: vault format, encryption, conflict handling, storage backends |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Milestones from empty repo to app store |

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

## Stack

Flutter for the user interface on iOS, Android, macOS, Windows and Linux. Rust for the engine: terminal emulation (`alacritty_terminal`), SSH (`russh`), the vault and its encryption. See [docs/DESIGN.md](docs/DESIGN.md) for the reasoning.
