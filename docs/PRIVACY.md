# Privacy policy

Effective 17 October 2026.

Promptly is a terminal emulator and SSH client made by its contributors and published under the MIT licence. This page says what the app does with information, in plain words. The short version: **Promptly collects nothing about you, and has no server to send anything to.**

## What Promptly does not do

- No account. There is nothing to sign up for.
- No analytics, no crash reporting, no advertising, no tracking of any kind. The app contains no third-party kit that reports home.
- No server of ours. Promptly never sends your hosts, keys, passwords, snippets, settings or anything you type to the people who make it.

## Where your data lives

Everything you put into Promptly (hosts, groups, keys, snippets, settings, saved passwords) is stored on your device, in the app's own data folder. Saved passwords and private keys are kept there as files that your system's permissions keep other users and apps from reading. They are not encrypted on the device itself, so protect the device and its backups as you would your `~/.ssh` folder.

If you turn on sync, Promptly writes an encrypted copy of that data to a place **you** choose: a folder another app of yours already syncs (such as a cloud drive's folder), or a server of yours over SFTP. The copy is encrypted on your device with a key derived from your passphrase before it leaves it, and only devices that know the passphrase (or the recovery code), or have already joined, can read it. A device that has joined keeps the key, so removing it from the vault or changing the passphrase does not lock it out; to cut off a lost device, remove its access to the storage itself. The storage provider you chose holds ciphertext and opaque file names. Promptly's makers never see it. Sync is off until you set it up.

## What goes over the network

- SSH connections to the hosts you add, when you open them.
- Reads and writes to your chosen sync location, when sync is on.
- With the "Show which hosts are up" setting on, a brief TCP connection to each saved host's port once a minute, to show whether it answers. Nothing is sent over it. It is off by default.
- Opening a link from the terminal, help or about pages hands it to your browser.
- Checking for a new version: a request to GitHub (api.github.com) for the newest Promptly release, when you press *Check* on the About page, or once a day with the "Check for updates automatically" setting on. It carries nothing about you or your data beyond what any web request does (your IP address and the app's version). The setting is off by default. Updating from inside the app (Windows, when installed with the installer) then downloads the installer from GitHub.

That is all. Promptly makes no other connections.

## Permissions

- **Android.** Network access, for SSH and sync. Nothing else. Files are read only when you pick one (a key, a theme, a CSV) or use the file browser.
- **Desktop.** Promptly reads `~/.ssh/config` and the key files it names only when you ask it to import them, and your SSH agent only when a host is set to use it.

## Children

Promptly is a tool for people who manage computers and is not directed at children.

## Changes

If this policy changes, the new text is published at the same address with a new effective date, and the change is noted in the release notes.

## Contact

Questions go to the project's issue tracker: https://github.com/analogproblems/Promptly/issues
