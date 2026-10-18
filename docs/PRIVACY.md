# Privacy policy

Effective 18 October 2026.

Promptly is a terminal emulator and SSH client made by its contributors and published under the MIT licence. This page says what the app does with information, in plain words. The short version: **Promptly collects nothing about you, and has no server to send anything to.**

## What Promptly does not do

- No account. There is nothing to sign up for.
- No analytics, no crash reporting, no advertising, no tracking of any kind. The app contains no third-party kit that reports home.
- No server of ours. Promptly never sends your hosts, keys, passwords, snippets, settings or anything you type to the people who make it.

## Where your data lives

Everything you put into Promptly (hosts, groups, keys, snippets, settings, saved passwords) is stored on your device, in the app's own data folder, and all of it is kept there encrypted, with a key that Promptly makes for each device and keeps in the operating system's own secure storage: the Keychain on Mac and iPhone, the Android Keystore, Windows Credential Manager, or the keyring on Linux. A copy of the data folder alone does not reveal any of it, including the list of servers you have trusted, which Promptly keeps in its own `known_hosts` file encrypted with the same key. On Android, the app's data is left out of phone backups and transfers to a new phone, since it could not be opened there without the key. A program running as you while you are signed in can still ask that secure storage for the key, so keep the device itself safe. On a Linux computer with no keyring, Promptly cannot encrypt your data; it keeps it in files only your user account can read and says so in Settings. The `promptly` command-line tool keeps its own copy of a vault's data, encrypted so that it opens only with the vault's passphrase or recovery code.

If you turn on sync, Promptly writes an encrypted copy of that data to a place **you** choose: a folder another app of yours already syncs (such as a cloud drive's folder), or a server of yours over SFTP. The copy is encrypted on your device with a key derived from your passphrase before it leaves it, and only devices that know the passphrase (or the recovery code), or have already joined, can read it. A device that has joined keeps the key, so removing it from the vault or changing the passphrase does not take away what it can already read. Re-keying the vault (offered when you remove a device) gives the vault a new key, so it cannot read anything written after that. For a lost device, also remove its access to the storage itself. The storage provider you chose holds ciphertext and opaque file names. Promptly's makers never see it. Sync is off until you set it up.

## What goes over the network

- SSH connections to the hosts you add, when you open them.
- Reads and writes to your chosen sync location, when sync is on.
- With the "Show which hosts are up" setting on, a brief TCP connection to each saved host's port once a minute, to show whether it answers. Nothing is sent over it. It is off by default.
- Opening a link from the terminal, help or about pages hands it to your browser.
- Checking for a new version: a request to GitHub (api.github.com) for the newest Promptly release, when you press *Check* on the About page, or once a day with the "Check for updates automatically" setting on. It carries nothing about you or your data beyond what any web request does (your IP address and the app's version). The setting is off by default. Updating from inside the app (Windows, when installed with the installer) then downloads the installer from GitHub.

That is all. Promptly makes no other connections.

## Permissions

- **Android.** Network access, for SSH and sync, and the fingerprint or face check, used only to unlock Promptly and your keys when you turn that on (the check happens in Android; Promptly learns only whether it passed). A foreground service and a notification, used only while sessions are open, so they keep running in the background. Nothing else. Files are read only when you pick one (a key, a theme, a CSV) or use the file browser.
- **Desktop.** Promptly reads `~/.ssh/config` and the key files it names only when you ask it to import them, and your SSH agent only when a host is set to use it. It reads `~/.ssh/known_hosts` when it connects, so servers you already trust with `ssh` are trusted in Promptly too, and it copies the servers named there (not hashed, wildcard or revoked entries, which stay in that file only) into its own encrypted data, so with sync on your other devices trust them as well.

## Children

Promptly is a tool for people who manage computers and is not directed at children.

## Changes

If this policy changes, the new text is published at the same address with a new effective date, and the change is noted in the release notes.

## Contact

Questions go to the project's issue tracker: https://github.com/analogproblems/Promptly/issues
