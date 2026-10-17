#!/usr/bin/env bash
# One-command developer setup for Promptly on Ubuntu 22.04 or newer.
# Safe to re-run: every step checks before it installs.
#
# What it does:
#   1. apt packages for a Flutter Linux desktop build
#   2. Rust via rustup (stable, with rustfmt and clippy)
#   3. Flutter stable into ~/flutter if `flutter` is not on PATH
#   4. flutter_rust_bridge_codegen, pinned to the version the app uses
#   5. Dart packages and the generated bridge code
#
# macOS and Windows: follow docs/DEVELOPMENT.md by hand for now.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRB_VERSION="$(grep -E '^\s*flutter_rust_bridge:' "$ROOT/app/pubspec.yaml" | awk '{print $2}')"

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script targets Ubuntu. See docs/DEVELOPMENT.md for other platforms." >&2
  exit 1
fi

say "System packages"
if command -v apt-get >/dev/null; then
  SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
  $SUDO apt-get update -q
  $SUDO apt-get install -y -q curl git unzip xz-utils zip clang cmake ninja-build \
    pkg-config libgtk-3-dev libsecret-1-dev liblzma-dev libstdc++-12-dev
else
  echo "No apt-get found; install clang, cmake, ninja, pkg-config and GTK 3 dev headers yourself." >&2
fi

say "Rust"
if ! command -v cargo >/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
rustup component add rustfmt clippy >/dev/null
cargo --version

say "Flutter"
if ! command -v flutter >/dev/null; then
  if [[ ! -x "$HOME/flutter/bin/flutter" ]]; then
    echo "Downloading the current stable Flutter SDK to ~/flutter"
    JSON="$(curl -sS https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)"
    ARCHIVE="$(printf '%s' "$JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin); h=d["current_release"]["stable"]
r=[x for x in d["releases"] if x["hash"]==h and x["channel"]=="stable"][0]
print(d["base_url"]+"/"+r["archive"])')"
    curl -sS -L -o /tmp/flutter.tar.xz "$ARCHIVE"
    tar -xJf /tmp/flutter.tar.xz -C "$HOME"
    rm -f /tmp/flutter.tar.xz
  fi
  export PATH="$HOME/flutter/bin:$PATH"
  echo "Add this to your shell profile:  export PATH=\"\$HOME/flutter/bin:\$PATH\""
fi
flutter config --no-analytics --enable-linux-desktop >/dev/null
flutter --version | head -1

say "cargo-audit"
command -v cargo-audit >/dev/null || cargo install cargo-audit --locked

say "flutter_rust_bridge_codegen $FRB_VERSION"
if ! flutter_rust_bridge_codegen --version 2>/dev/null | grep -q " $FRB_VERSION\$"; then
  cargo install flutter_rust_bridge_codegen --version "$FRB_VERSION" --locked
fi

say "Dart packages and generated bridge code"
(cd "$ROOT/app" && flutter pub get && flutter_rust_bridge_codegen generate)

say "Engine builds and tests"
(cd "$ROOT/engine" && cargo test -q)

say "Done. Next: make run"
