# Developing Promptly

How to build, run and change Promptly. Linux first, because that is the order
of the roadmap; other platforms are noted where they differ.

## Layout

```
promptly/
  app/        Flutter application (all platforms)
  engine/     Rust workspace: the engine crates and the CLI
  docs/       Design, vault spec, roadmap, this file
  tools/      setup.sh and other scripts
  Makefile    Shortcuts for the commands below
```

The app talks to the engine through `flutter_rust_bridge`. The Rust side of
that bridge is the crate `engine/crates/promptly-api` (package name
`promptly_api`); the Dart side is generated into `app/lib/src/rust/`. The build
glue in `app/rust_builder/` compiles `promptly_api` for each platform while
Flutter builds, so there is no separate step to build the engine for the app.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Rust | stable, 1.85 or newer | via rustup, with `rustfmt` and `clippy` |
| Flutter | stable, 3.35 or newer | `flutter config --enable-linux-desktop` |
| flutter_rust_bridge_codegen | exactly the version in `app/pubspec.yaml` | `cargo install flutter_rust_bridge_codegen --version <v> --locked` |
| Linux desktop deps | | `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev` |

On Ubuntu, `tools/setup.sh` installs all of this and is safe to re-run.

The codegen version, the `flutter_rust_bridge` Dart package and the
`flutter_rust_bridge` Rust crate must all be the same version. If they drift,
the generated code refuses to load with a clear message; fix by matching them
and running `make gen`.

## Everyday commands

```
make run           # the app on Linux desktop, debug, with hot reload
make check         # everything CI checks: Rust fmt, clippy, tests; Dart analyze, tests
make build-linux   # release bundle at app/build/linux/x64/release/bundle
make cli ARGS="parse deploy@10.0.0.11"
make gen           # after changing the engine's API (see below)
```

`make` on its own lists every target.

The command-line tool works on any vault folder and is its own device,
with a small store under `~/.local/share/promptly-cli/`:

```
promptly inspect ~/Promptly\ Vault                 # devices, files, sizes; records with a passphrase
promptly export ~/Promptly\ Vault > vault.json     # merged state as JSON (add --with-secrets, carefully)
promptly import ~/Promptly\ Vault hosts.json       # merge a JSON document in
promptly sync ~/Promptly\ Vault                    # pull and push from a script
promptly ssh-config ~/Promptly\ Vault --keys-dir ~/.ssh/promptly >> ~/.ssh/config
promptly change-passphrase ~/Promptly\ Vault
```

The passphrase comes from `--passphrase`, `PROMPTLY_PASSPHRASE`, or a prompt.

One cache to know about: a release build keeps only the Material icons the
Dart code uses, and Flutter does not notice when that set changes. If a new
`Icons.*` shows up as a small box, delete `app/build/flutter_assets` and
build again.

## The app icon

`tools/icons/icon.cjs` draws the icon as SVG from a few parameters; `make icons` (Node with the `playwright` package, plus ImageMagick) renders every platform's files from it: the in-app asset, the Linux icon theme sizes, the Windows `.ico`, the Android launcher, adaptive and monochrome layers, and the macOS and iOS sets. The rendered files are committed, so this only runs when the drawing changes.

## Changing the engine API

1. Add or change a function in `engine/crates/promptly-api/src/api/`. Plain
   Rust: functions, structs, enums, `Result`. Mark synchronous calls with
   `#[flutter_rust_bridge::frb(sync)]`; everything else becomes `async` in Dart.
2. Run `make gen`. This rewrites `app/lib/src/rust/` and
   `engine/crates/promptly-api/src/frb_generated.rs`. Both are committed, so a
   fresh clone builds without the generator installed.
3. Use the new function from Dart through `app/lib/core/engine/engine.dart`,
   never from the generated files directly. That file is the one place the UI
   touches the bridge, and it is what widget tests replace with a fake.

Keep `promptly-api` thin: it adapts types and calls into the other crates.
Logic belongs in `promptly-term`, `promptly-ssh`, `promptly-vault` and
`promptly-store`, where it can be unit tested without Flutter.

## Tests

- `cargo test` in `engine/` runs every Rust test. The vault's merge rules and
  the terminal emulation will carry most of the project's tests.
- `flutter test` in `app/` runs widget tests against a fake engine, so they
  need no native library and run anywhere Flutter runs.
- A full-stack smoke test (real engine loaded into the app) is the Linux build
  in CI.
- The SSH tests run only when a server is named: set
  `PROMPTLY_TEST_SSH=user:password@host:port` (and `PROMPTLY_TEST_SSH_KEY` to
  a private key that server accepts) and `cargo test` covers password, key,
  keyboard-interactive and agent logins, jump hosts (the server jumps through
  itself), each kind of port forward, `exec`, the SFTP backend and the file
  browser. The persistent-session test needs `tmux` on that server; the file
  browser test writes under the login's home and tidies up after itself. A
  throwaway `sshd` on a high port with one test user is all it takes.
- Before a milestone commit the Linux release build is driven on a virtual
  display (`xvfb-run`, `xdotool`, ImageMagick's `import`) through the real
  screens, and the screenshots in `docs/screenshots/` come from those runs.

## Platform notes

**Linux.** The reference platform. The app bundle is self-contained under
`app/build/linux/x64/release/bundle/`; run `bundle/promptly` directly. Data
lives in `~/.local/share/dev.promptly.promptly/`: `promptly.db` (hosts,
groups, keys' public halves, settings), `known_hosts`, and `secrets/` (one
owner-only file per password or private key, named by id).

Two environment variables help when testing sync: `PROMPTLY_DATA_DIR`
points a copy of the app at its own data folder, so two copies can run
side by side as two "devices" sharing one vault folder, and
`PROMPTLY_FAST_KDF=1` makes vault creation use weak key stretching so a
walkthrough does not wait on Argon2id. Never set the second one for real use.

**Windows.** Needs Visual Studio with the C++ desktop workload and Rust's
`x86_64-pc-windows-msvc` target; then `flutter build windows --release`
puts a self-contained folder at `app\build\windows\x64\runner\Release\`.
CI builds it on every push and keeps the folder as the
`promptly-windows-x64` artifact. The local shell is PowerShell when it is
installed, else `cmd`. Data lives under `%APPDATA%` unless
`PROMPTLY_DATA_DIR` says otherwise. Agent forwarding is not wired up on
Windows yet. The path in `app/rust_builder/windows/CMakeLists.txt` climbs
seven directories because Flutter builds plugins through a symlink under
`windows/flutter/ephemeral`; do not "fix" it to match the Linux one.

**Android.** Needs the Android SDK with NDK 28.2.13676358 (the version
Flutter's Gradle plugin asks for), a JDK 17 or newer, and the Rust targets
`aarch64-linux-android`, `armv7-linux-androideabi` and `x86_64-linux-android`
(the build glue installs a missing target itself). `flutter build apk
--release` puts a universal APK at `app/build/app/outputs/flutter-apk/`;
`flutter build appbundle --release` makes the bundle Play wants. Android 9
(API 28) is the minimum. A release build signs with the upload key named
by `app/android/key.properties` when that file exists (make the key once
with `tools/android-keystore.sh`), else with the debug key, so a build for
testing always comes out. CI builds both on every push and keeps them as
the `promptly-android` artifact; the four `ANDROID_*` repository secrets,
when set, make CI sign with the upload key. On a phone the terminal takes
text from the system keyboard and shows a bar of the keys phones lack
(Esc, Tab, sticky Ctrl and Alt, arrows, and the shell's punctuation).

**macOS and iOS.** Need Xcode and the Rust targets `aarch64-apple-darwin`,
`aarch64-apple-ios` and `aarch64-apple-ios-sim`. The podspecs in
`app/rust_builder/{ios,macos}` link the static library `libpromptly_api.a`.

## The docs site

`python3 tools/site/build.py site` turns the README, the files in `docs/`
and the changelog into a small static site in `site/` (one stylesheet, no
scripts; needs `pip install markdown`). The Docs site workflow publishes
it with GitHub Pages on every push to `main` that touches the docs, once
Pages is switched on in the repository settings (Source: GitHub Actions).
The privacy policy lives at `/privacy/`, the address the app's About page
and the Play listing point at.

## Releasing

1. Write the release's section in `CHANGELOG.md` (`## 1.0.1`, plain words).
2. `make version V=1.0.1` sets the version in the app, the engine and the
   Linux metadata, and bumps the build number.
3. Commit, tag and push the tag: `git commit -am "Release 1.0.1" && git tag v1.0.1 && git push origin main v1.0.1`.
4. The Release workflow builds the Linux tarball and `.deb`, the Windows
   zip, and the Android APK and app bundle (signed with the upload key
   when the `ANDROID_*` secrets are set), writes `SHA256SUMS`, and opens a
   **draft** release with the changelog section as its notes. Try the
   builds, then publish the draft.

`make package-linux` makes the tarball and `.deb` locally from the release
bundle, into `dist/`.

## Conventions

- Rust: `cargo fmt` and `cargo clippy --all-targets -- -D warnings` must pass.
  Errors are typed (`thiserror`) in library crates and `anyhow` only in the CLI.
- `cargo audit` runs in `make check` and in CI. An advisory that cannot be
  fixed is ignored in `engine/.cargo/audit.toml` with a comment saying why and
  when to revisit; never ignore one silently.
- Dart: `flutter analyze` must be clean. Riverpod for state, go_router for
  navigation. Colours come from `PromptlyTokens`; the terminal font is
  `PromptlyTokens.monoFamily`.
- Secrets never appear in logs. Wrap them in types whose `Debug` is redacted.
- Commit the generated bridge files together with the API change that caused them.
- Write everything as if the repository were already public.
