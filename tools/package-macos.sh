#!/usr/bin/env bash
# Package the macOS release build as a .dmg.
#
#   tools/package-macos.sh [app-bundle] [version] [out-dir]
#
# Defaults: app/build/macos/Build/Products/Release/promptly.app, the version
# in pubspec, dist/. The disk image holds the app and a shortcut to
# Applications, so installing is a drag. The app carries only the build
# tools' ad-hoc signature until we join Apple's developer programme; see
# docs/DISTRIBUTION.md for the Open Anyway step that means.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/app/build/macos/Build/Products/Release/promptly.app}"
VERSION="${2:-$(sed -nE 's/^version: ([0-9.]+)\+.*$/\1/p' "$ROOT/app/pubspec.yaml")}"
OUT="${3:-$ROOT/dist}"

[[ -d "$APP" ]] || { echo "no app at $APP; run flutter build macos --release first" >&2; exit 1; }
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Promptly"
ditto "$APP" "$WORK/Promptly/Promptly.app"
ln -s /Applications "$WORK/Promptly/Applications"
cp "$ROOT/LICENSE" "$WORK/Promptly/LICENSE.txt"

hdiutil create -volname "Promptly $VERSION" -srcfolder "$WORK/Promptly" \
  -fs HFS+ -format UDZO -ov "$OUT/promptly-$VERSION-macos.dmg"
