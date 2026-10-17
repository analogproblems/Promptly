# Changelog

Each release's section is what the GitHub Release says; keep it in plain words.

## Unreleased

- Pasting text with more than one line shows it first, with how many lines it has, and offers *Paste*, *Paste without final newline* and *Cancel*, since each line runs as a command. It can be turned off in Settings, Terminal. Pasted text also loses any control characters, so a copied snippet can no longer slip commands past a program's paste protection.
- A server whose host key has changed now gets a full-page warning where *Disconnect* is the main button, and trusting the new key takes two deliberate steps. Once trusted, the new key replaces the old one everywhere, so the warning no longer comes back on every connect when the old key is still in `~/.ssh/known_hosts`. A server offering a different kind of key than the one trusted counts as changed, not as a new server, and Promptly asks servers for the kind of key it already trusts first. Hashed and `@revoked` lines in `~/.ssh/known_hosts` are understood, and one odd line no longer hides the rest of the file. Running snippets on many hosts and SFTP sync say plainly when a key has changed instead of suggesting you trust it.
- Passwords, private keys, passphrases and the vault's keys are wiped from the engine's memory once they're no longer needed, and never show up in its logs. A host's startup command no longer gets typed again into a persistent tmux session every time it reconnects (it runs once, when the tmux session is made), and two sessions to the same host with *Persistent session* on each get their own tmux session instead of mirroring one screen. The command-line tool no longer takes the passphrase or recovery code as an argument, where other people on the computer could see it; it asks, or reads an environment variable.
- A new user guide covers installing Promptly and every feature, step by step, and **User guide** in Help now opens it.
- Saved passwords, private keys and the key to your sync vault are now encrypted on your device, with a key kept in the system's secure storage (Keychain, Android Keystore, Windows Credential Manager or the Linux keyring). On a Linux computer with no keyring they stay as owner-only files, and Settings says so. Linux builds now need libsecret. Passwords and keys saved by 1.0.0 or 1.0.1 aren't carried over: type the passwords again and re-import the keys.
- Everything else Promptly keeps on your device (hosts, groups, keys, snippets, settings) is now encrypted too, with the same key. On a Linux computer with no keyring it stays unencrypted, and Settings says so; installing a keyring encrypts it the next time Promptly starts. The `promptly` command-line tool's own copy is encrypted as well, so it opens only with the vault's passphrase or recovery code.
- The *Remove device* message and the privacy policy now say that removing a device or changing the passphrase does not lock out a device that has already joined. For a lost one, cut off its access to the vault's storage and change the passwords and keys it had.
- Windows has an installer. It installs for you alone, with no administrator prompt, and adds Promptly to the Start menu and to Settings, Apps for uninstalling. The zip is still there for anyone who prefers it.
- Promptly can tell you about new versions. Press *Check* on the About page, or turn on *Check for updates automatically* in Settings to have it look once a day (off by default). On Windows, when installed with the installer, *Update and restart* installs the new version and opens it again; elsewhere it opens the download page.
- Search highlights the match it is on in solid yellow, with the other matches in a softer yellow, so the current one is easy to spot. Searching for text that repeats inside itself, such as "22" in "222", no longer shows "0 of 1" or a half-highlighted match.
- Hosts have a *None* authentication option for servers that let you in without a password or key, such as Tailscale SSH. *Ask each time* now goes straight in on those servers too, instead of prompting.
- The mouse works in full-screen programs that ask for it, such as vim with `mouse=a`, tmux and htop: clicks, drags and the wheel go to the program. Hold Shift to select text or scroll as before.
- Sync no longer loses changes when a synced folder delivers files out of order, or when a device leaves the vault and joins again. Removing a device waits until all of its changes have arrived, and changing the vault passphrase can no longer leave the folder without its key file.
- Cancelling an SSH connection really stops it. Checking a new server's fingerprint has no time limit, a reconnect is no longer undone by the old connection closing late, and Stop on automatic reconnect stays stopped.
- The text editor keeps typing done while a save is in progress, and Android's Back button asks before throwing edits away.
- A host with "remember password" off saves properly, and a host in a group can leave User blank to use the group's.
- Imported PuTTY and PEM keys keep their passphrase. CSV passwords keep their spaces. Jump hosts from `~/.ssh/config` that Promptly cannot follow are reported instead of being skipped silently.
- On a phone keyboard, backspace erases a whole emoji and keeps working on a command recalled from history. A big paste no longer freezes the app while a program is busy.
- File permissions keep their special bits, Windows paths rename and navigate in the right folder, port forward rows stay in place after one is removed, and exported keys with the same name no longer overwrite each other.
- On desktop, the menu bar is slimmer and its menus open below it instead of over it, rows are more compact, and shortcuts no longer touch the menu's right edge. The nine Tab entries moved into a View, Go to tab submenu. The Help page's shortcut list no longer runs keys into their descriptions, and on a phone the host editor picks how to sign in from a list instead of buttons squeezed so tight their words broke. Session text has a small margin on the left instead of touching the edge.

## 1.0.1

- Promptly for Mac: a free `.dmg` for Apple silicon and Intel Macs. It is not signed by Apple yet, so the first launch needs one trip to System Settings, then Privacy & Security, then *Open Anyway*.

## 1.0.0

The first release: everything from the four milestones.

- A terminal that feels right: smooth scrolling, true colour, themes with live previews, selection and copy, scrollback search, links you can open.
- SSH with the lot: passwords, keys, the agent (on Windows, the OpenSSH agent or Pageant), keyboard-interactive logins, host key checks you cannot miss, automatic reconnect, jump hosts, port forwards (local, remote, SOCKS), tmux-backed persistent sessions, startup commands and environment variables, agent forwarding.
- Hosts, groups, keys and snippets, with favourites, recents, and a dot that says which hosts are up.
- Snippets with `{{variables}}`, run in a session or on many hosts at once.
- A file browser over the session's own connection, with uploads, downloads, permissions and editing text files in place; two panes on desktop.
- Free sync: an encrypted vault in a folder you already sync, or on a server over SFTP. No account, no servers.
- Imports from `~/.ssh/config`, from a CSV such as the one Termius exports, PuTTY `.ppk` keys, and themes from iTerm2, Windows Terminal, Alacritty and base16.
- Desktop: tabs, split panes, a hosts panel, a menu bar and a command palette. Phone: a keyboard bar with Esc, Tab, sticky Ctrl and Alt and arrows.
- A welcome tour, in-app help, and an accessibility pass: labels for screen readers, large text, reduced motion.
