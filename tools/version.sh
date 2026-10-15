#!/usr/bin/env bash
# Set the app's version everywhere it lives, in one go:
#
#   tools/version.sh 1.0.1          # build number goes up by one
#   tools/version.sh 1.0.1 7        # build number set to 7
#
# Touches app/pubspec.yaml (version: X.Y.Z+N), app/lib/core/version.dart,
# the engine's workspace version, and the Linux AppStream release entry.
# Then commit, tag vX.Y.Z and push the tag: the release workflow does the
# rest. The build number is what Android and Windows count up, so it must
# never go down.
set -euo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 X.Y.Z [build]" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CURRENT_BUILD="$(sed -nE 's/^version: [0-9.]+\+([0-9]+)$/\1/p' "$ROOT/app/pubspec.yaml")"
BUILD="${2:-$((CURRENT_BUILD + 1))}"

sed -i -E "s/^version: .*$/version: $VERSION+$BUILD/" "$ROOT/app/pubspec.yaml"
sed -i -E "s/^const appVersion = '.*';$/const appVersion = '$VERSION';/" "$ROOT/app/lib/core/version.dart"
sed -i -E "0,/^version = \".*\"$/s//version = \"$VERSION\"/" "$ROOT/engine/Cargo.toml"

TODAY="$(date -u +%Y-%m-%d)"
META="$ROOT/app/linux/dev.promptly.promptly.metainfo.xml"
if ! grep -q "release version=\"$VERSION\"" "$META"; then
  sed -i -E "s|  <releases>|  <releases>\n    <release version=\"$VERSION\" date=\"$TODAY\"/>|" "$META"
fi

if ! grep -q "^## $VERSION" "$ROOT/CHANGELOG.md"; then
  echo "Reminder: CHANGELOG.md has no '## $VERSION' section yet; the release notes come from it." >&2
fi

# The lock file carries the crate versions.
( cd "$ROOT/engine" && cargo update -w -q 2>/dev/null || true )

echo "Version $VERSION, build $BUILD. Now: git commit -am 'Release $VERSION' && git tag v$VERSION && git push --tags"
