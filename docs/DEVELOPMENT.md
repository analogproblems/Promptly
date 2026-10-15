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
  in CI; milestone 1 adds an integration test that drives a real local shell.

## Platform notes

**Linux.** The reference platform. The app bundle is self-contained under
`app/build/linux/x64/release/bundle/`; run `bundle/promptly` directly.

**Windows.** Needs Visual Studio with the C++ desktop workload and Rust's
`x86_64-pc-windows-msvc` target. The path in
`app/rust_builder/windows/CMakeLists.txt` climbs seven directories because
Flutter builds plugins through a symlink under `windows/flutter/ephemeral`;
do not "fix" it to match the Linux one.

**Android.** Needs Android Studio's SDK and NDK, plus the Rust targets
`aarch64-linux-android`, `armv7-linux-androideabi` and `x86_64-linux-android`.
The build glue installs them with `cargo-ndk` on first build.

**macOS and iOS.** Need Xcode and the Rust targets `aarch64-apple-darwin`,
`aarch64-apple-ios` and `aarch64-apple-ios-sim`. The podspecs in
`app/rust_builder/{ios,macos}` link the static library `libpromptly_api.a`.

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
