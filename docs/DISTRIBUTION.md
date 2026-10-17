# Distribution

How Promptly reaches people, what each channel costs, and the order we take them in. The code is MIT and free everywhere; this page is only about the cost of being listed.

## The plan

1. **Free first.** Every release goes on GitHub Releases as a Linux tarball and `.deb`, a Windows installer and zip, and an Android APK, built by CI from a tag. Nothing to pay, nothing to sign with a bought certificate.
2. **Android on Google Play** is the one exception taken early: the developer account is a one-time fee, the store signs the app for us, and the internal and closed testing tracks are the easiest way to get a dozen people trying the phone build.
3. **Everything that costs money every year waits** until the free builds have been tested on real Linux, Windows and Android hardware: Apple's developer programme (which Mac notarisation, the Mac App Store and anything on an iPhone all need) and a signed Windows installer. A Mac build itself is free to ship; see below.
4. **If the paid stores happen, they carry a flat one-time price**, about $5, to cover what those listings cost. Same code, same licence; the GitHub builds stay free and there is never a subscription or an in-app purchase.

## Channels

| Channel | Platforms | What it costs | What it needs | Status |
|---|---|---|---|---|
| GitHub Releases | Linux, Windows, Android, macOS | Nothing | A tag; CI does the rest. The Mac job builds the `.dmg` on GitHub's Mac runners, free now the repository is public | M4; macOS in M5 |
| Google Play | Android | One-time developer registration | A Play developer account, our own upload key (the store does the signing), a privacy policy page, store text and screenshots | M4, internal testing |
| Developer ID and notarisation | macOS | Apple's yearly developer programme | A signing certificate in CI's secrets and Apple's automated scan; no store, no review, no sandbox | Later; the first thing the one-time price pays for |
| Mac App Store | macOS | The same programme | Store review and the App Sandbox, which confines the local shell and blocks forwarding to the SSH agent | Optional, last |
| App Store, TestFlight | iOS | The same programme | Apple signing and store review; the only way onto an iPhone | Later; one-time price |
| Signed Windows installer, Microsoft Store | Windows | A code-signing certificate (yearly) or the store's registration | Signing, an installer | Later; one-time price |
| Flathub, winget, AUR, Homebrew | Linux, Windows, macOS | Nothing | A manifest or cask pointing at a GitHub release | Later, free |

## What unsigned means for people installing

- **Windows:** the first run of an unsigned program shows SmartScreen's "Windows protected your PC". *More info* then *Run anyway* gets past it. The release notes say so. A certificate removes the warning and is the cost the plan defers.
- **Windows, the C++ runtime:** the app, its plugins and the Rust engine all need Microsoft's Visual C++ runtime (`vcruntime140.dll`, `msvcp140.dll` and friends), which a fresh Windows does not have. Rather than run Microsoft's `vc_redist.x64.exe` (which needs an administrator), `tools/windows-runtime.ps1` copies the runtime files from Visual Studio's redistributable folder into the bundle, next to `promptly.exe`. Microsoft allows this ("local deployment") for exactly those files. Windows looks in the program's own folder first, so the app uses the copies it came with whether or not the runtime is installed system-wide. The build's toolset decides which runtime version it needs (CI's Visual Studio 2026 means 14.50 or newer), and shipping the matching files sidesteps that: the one-line fix of installing Microsoft's package only works when the package is at least as new as the toolset.
- **Windows, the installer:** `tools/windows-installer.ps1` wraps the same bundle (runtime included) in an Inno Setup installer, `promptly-X.Y.Z-windows-x64-setup.exe`. It installs per user into `%LOCALAPPDATA%\Programs\Promptly`, so it needs no administrator, and that is also what lets the app update itself: About, *Update and restart* downloads the newer installer and runs it silently, and the installer opens Promptly again when it is done. A copy unpacked from the zip cannot do that and gets a link to the download page instead. The installer is unsigned too, so SmartScreen shows its warning for it the same way.
- **Updates elsewhere:** the Mac, Linux and Android builds check for new versions the same way (GitHub's latest release) but open the release page rather than installing: replacing an unsigned Mac app, a `.deb` or an APK from inside the app needs either an administrator, the user's say-so in a system dialog, or a signature these builds do not have yet. iPhone builds come from the App Store, which updates them.
- **macOS:** a Mac installs apps from anywhere; only the iPhone is store-only. An unsigned `.dmg` from GitHub is blocked on first open with "Apple could not verify this is free of malware", and since macOS 15 the old Control-click, *Open* trick no longer works: the person opens System Settings, then Privacy & Security, finds the line about the blocked app, clicks *Open Anyway* (the line shows for about an hour after the failed launch) and confirms with their password. Once per app. The release notes will say so, and the Homebrew cask will carry the same note. Signing with a Developer ID and notarising (Apple's automated scan, part of the developer programme) removes the step entirely, with no store and no review, which makes it the better first use of Apple's fee for a terminal app. The Mac App Store adds review and the App Sandbox, which confines the local shell and blocks forwarding to the SSH agent; that is why iTerm2 stays out of it, and why it is optional here.
- **Android:** an APK from GitHub installs after allowing "unknown apps" for the browser or file manager that opened it. The Play build has no such step.
- **Linux:** none; the tarball runs from anywhere and the `.deb` installs with the package manager.

## Versions and tags

`app/pubspec.yaml` holds the version (`1.0.0+1`): the name before the plus is what people see, the number after it is the build number Android and Windows count up. `make version V=1.0.1` sets both, and pushing the tag `v1.0.1` builds the release. The changelog entry for that version becomes the release notes.

## Signing keys

- **Android:** a keystore we generate once (`tools/android-keystore.sh`) and keep out of the repository. CI reads it from the `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` secrets; without them it signs with the debug key, so a build still comes out for testing. Play App Signing keeps the final key; ours is only the upload key.
- **macOS:** unsigned (the build tools' own ad-hoc signature) until the developer programme; then a Developer ID certificate kept in CI's secrets, and notarisation in the release workflow.
- **Windows and Linux:** unsigned for now. Every release ships a `SHA256SUMS` file so anyone can check what they downloaded.

## Building for the Mac

CI builds the Mac app on GitHub's own Mac runners, so nobody needs a Mac on their desk. Those runners cost ten times a Linux minute on a private repository and nothing on a public one, which is why the Mac build waited for the repository to go public; CI now builds it on every push and keeps the disk image as the `promptly-macos` artifact. `tools/package-macos.sh` wraps the built app in the `.dmg`, with a shortcut to Applications. The first Mac release is the free, unsigned `.dmg`; it ships in the release after 1.0.0 so that its first runs through CI do not hold up the first tag.
