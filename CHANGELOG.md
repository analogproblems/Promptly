# Changelog

Each release's section is what the GitHub Release says; keep it in plain words.

## Unreleased

- The mouse works in full-screen programs that ask for it, such as vim with `mouse=a`, tmux and htop: clicks, drags and the wheel go to the program. Hold Shift to select text or scroll as before.
- Sync no longer loses changes when a synced folder delivers files out of order, or when a device leaves the vault and joins again. Removing a device waits until all of its changes have arrived, and changing the vault passphrase can no longer leave the folder without its key file.
- Cancelling an SSH connection really stops it. Checking a new server's fingerprint has no time limit, a reconnect is no longer undone by the old connection closing late, and Stop on automatic reconnect stays stopped.
- The text editor keeps typing done while a save is in progress, and Android's Back button asks before throwing edits away.
- A host with "remember password" off saves properly, and a host in a group can leave User blank to use the group's.
- Imported PuTTY and PEM keys keep their passphrase. CSV passwords keep their spaces. Jump hosts from `~/.ssh/config` that Promptly cannot follow are reported instead of being skipped silently.
- On a phone keyboard, backspace erases a whole emoji and keeps working on a command recalled from history. A big paste no longer freezes the app while a program is busy.
- File permissions keep their special bits, Windows paths rename and navigate in the right folder, port forward rows stay in place after one is removed, and exported keys with the same name no longer overwrite each other.
- On desktop, the menu bar is slimmer and its menus open below it instead of over it, rows are more compact, and shortcuts no longer touch the menu's right edge. The nine Tab entries moved into a View, Go to tab submenu. The Help page's shortcut list no longer runs keys into their descriptions, and the host editor's Password button no longer breaks onto two lines on a phone. Session text has a small margin on the left instead of touching the edge.

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
