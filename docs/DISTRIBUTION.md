# Distribution

How Promptly reaches people, what each channel costs, and the order we take them in. The code is MIT and free everywhere; this page is only about the cost of being listed.

## The plan

1. **Free first.** Every release goes on GitHub Releases as a Linux tarball and `.deb`, a Windows zip and an Android APK, built by CI from a tag. Nothing to pay, nothing to sign with a bought certificate.
2. **Android on Google Play** is the one exception taken early: the developer account is a one-time fee, the store signs the app for us, and the internal and closed testing tracks are the easiest way to get a dozen people trying the phone build.
3. **Everything that costs money every year waits** until the free builds have been tested on real Linux, Windows and Android hardware: the App Store for macOS and iOS, and a signed Windows installer.
4. **If the paid stores happen, they carry a flat one-time price**, about $5, to cover what those listings cost. Same code, same licence; the GitHub builds stay free and there is never a subscription or an in-app purchase.

## Channels

| Channel | Platforms | What it costs | What it needs | Status |
|---|---|---|---|---|
| GitHub Releases | Linux, Windows, Android | Nothing | A tag; CI does the rest | M4 |
| Google Play | Android | One-time developer registration | A Play developer account, our own upload key (the store does the signing), a privacy policy page, store text and screenshots | M4, internal testing |
| App Store, TestFlight | macOS, iOS | Yearly developer programme, a Mac to build on | Apple signing, notarisation, store review | Later; one-time price |
| Signed Windows installer, Microsoft Store | Windows | A code-signing certificate (yearly) or the store's registration | Signing, an installer | Later; one-time price |
| Flathub, winget, AUR | Linux, Windows | Nothing | A manifest pointing at a GitHub release | Later, free |

## What unsigned means for people installing

- **Windows:** the first run of an unsigned program shows SmartScreen's "Windows protected your PC". *More info* then *Run anyway* gets past it. The release notes say so. A certificate removes the warning and is the cost the plan defers.
- **Windows, the C++ runtime:** the app, its plugins and the Rust engine all need Microsoft's Visual C++ runtime (`vcruntime140.dll`, `msvcp140.dll` and friends), which a fresh Windows does not have. An installer would run Microsoft's `vc_redist.x64.exe`; a zip cannot, so `tools/windows-runtime.ps1` copies the runtime files from Visual Studio's redistributable folder into the bundle, next to `promptly.exe`. Microsoft allows this ("local deployment") for exactly those files. Windows looks in the program's own folder first, so the app uses the copies it came with whether or not the runtime is installed system-wide. The build's toolset decides which runtime version it needs (CI's Visual Studio 2026 means 14.50 or newer), and shipping the matching files sidesteps that: the one-line fix of installing Microsoft's package only works when the package is at least as new as the toolset.
- **Android:** an APK from GitHub installs after allowing "unknown apps" for the browser or file manager that opened it. The Play build has no such step.
- **Linux:** none; the tarball runs from anywhere and the `.deb` installs with the package manager.

## Versions and tags

`app/pubspec.yaml` holds the version (`1.0.0+1`): the name before the plus is what people see, the number after it is the build number Android and Windows count up. `make version V=1.0.1` sets both, and pushing the tag `v1.0.1` builds the release. The changelog entry for that version becomes the release notes.

## Signing keys

- **Android:** a keystore we generate once (`tools/android-keystore.sh`) and keep out of the repository. CI reads it from the `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` secrets; without them it signs with the debug key, so a build still comes out for testing. Play App Signing keeps the final key; ours is only the upload key.
- **Windows and Linux:** unsigned for now. Every release ships a `SHA256SUMS` file so anyone can check what they downloaded.
