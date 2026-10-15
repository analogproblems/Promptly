# Google Play listing

What to paste into Play Console for the Android app, and what it asks for. Costs and the order of channels are in [../DISTRIBUTION.md](../DISTRIBUTION.md).

## Before the listing

- A Google Play developer account (one-time registration fee).
- The upload key: `tools/android-keystore.sh`, then the four `ANDROID_*` repository secrets so CI signs the bundle. Play App Signing keeps the final key.
- The app bundle: `promptly-<version>-android.aab` from a release, or the `promptly-android` CI artifact.
- A new personal developer account has to run a **closed test** with at least a dozen testers opted in for two weeks before it can apply for production. That is the "Play internal testing with a dozen people" step in the roadmap: create a closed testing track, add testers by email or a Google Group, share the opt-in link.

## Store listing

**App name:** Promptly

**Short description** (80 characters at most):

> SSH client and terminal with free, encrypted sync through your own storage.

**Full description** (4000 characters at most):

> Promptly is a terminal and SSH client that feels right on a phone, a tablet and a desktop, and never asks you to rent a server to keep your hosts in sync.
>
> **Your terminal, everywhere.** Smooth scrolling, true colour, themes with live previews, text selection, scrollback search, and links you can open. A keyboard bar gives your phone the keys it lacks: Esc, Tab, Ctrl, Alt and arrows.
>
> **SSH with the lot.** Passwords, keys, keyboard-interactive logins and host key checks you cannot miss. Jump hosts, port forwards (local, remote and SOCKS), persistent sessions through tmux, startup commands, automatic reconnect.
>
> **Hosts, keys and snippets.** Groups, tags, favourites and recents, with a dot that says which hosts are up. Generate ed25519 keys or import the ones you have, including PuTTY files. Snippets with variables run in a session or on many hosts at once.
>
> **Files.** Browse a server over the session's own connection: upload, download, rename, set permissions, and edit text files in place.
>
> **Your data, yours.** Everything is stored on your device. Turn on sync and an encrypted copy goes to storage you already own: a folder your cloud drive syncs, or a server of yours over SFTP. No account, no Promptly servers, nothing to pay every month. The vault format is documented and a command-line tool can export everything.
>
> **Imports.** From ~/.ssh/config, from a CSV such as the one Termius exports, PuTTY keys, and themes from iTerm2, Windows Terminal, Alacritty and base16.
>
> Promptly is free and open source under the MIT licence. The code is on GitHub.

**Category:** Tools. **Tags:** SSH, terminal, sysadmin, developer tools.

**Contact email:** the project's. **Website:** https://analogproblems.github.io/Promptly/ **Privacy policy:** https://analogproblems.github.io/Promptly/privacy/

## Graphics

- **Icon:** 512 × 512, `app/assets/icon/promptly.png`.
- **Feature graphic:** 1024 × 500, `docs/store/feature-graphic.png` (made by `tools/store-graphics.sh`).
- **Phone screenshots:** at least two, 16:9 to 9:16, each side 320 to 3840 px. `docs/store/screenshots/` holds a set taken at phone size.

## Questionnaires

**Content rating:** a utility app. No violence, sexual content, language, controlled substances, gambling, or user-generated content shared with others. No ads.

**Data safety:** Promptly does not collect or share any user data. It has no analytics, no crash reporting, no account. Data stays on the device, or in storage the user chooses with sync on; the developer never receives it. Data in transit to the user's own hosts and storage is encrypted (SSH; the vault's own encryption). Users can delete their data by clearing the app's storage or uninstalling.

**App access:** no login is needed to review the app. Reviewers can open a local shell? Not on Android; they can add any SSH host they have, or try the hosts list, snippets, keys and settings without one.

**Target audience:** 18 and over (a tool for people who manage computers; not designed for children).

**Permissions declared:** INTERNET only.
