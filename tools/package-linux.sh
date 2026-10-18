#!/usr/bin/env bash
# Package the Linux release bundle as a tarball and a .deb.
#
#   tools/package-linux.sh [bundle-dir] [version] [out-dir]
#
# Defaults: app/build/linux/x64/release/bundle, the version in pubspec,
# dist/. The tarball runs from anywhere (unpack, run ./promptly). The .deb
# installs to /opt/promptly with a launcher, the desktop file, the icon
# theme entries and the AppStream metadata.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-$ROOT/app/build/linux/x64/release/bundle}"
VERSION="${2:-$(sed -nE 's/^version: ([0-9.]+)\+.*$/\1/p' "$ROOT/app/pubspec.yaml")}"
OUT="${3:-$ROOT/dist}"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
ID="dev.promptly.promptly"

[[ -x "$BUNDLE/promptly" ]] || { echo "no bundle at $BUNDLE; run flutter build linux --release first" >&2; exit 1; }
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- Tarball ---------------------------------------------------------------
NAME="promptly-$VERSION-linux-x64"
mkdir -p "$WORK/$NAME"
cp -a "$BUNDLE"/. "$WORK/$NAME/"
cp "$ROOT/app/linux/$ID.desktop" "$WORK/$NAME/"
cp "$ROOT/app/assets/icon/promptly.png" "$WORK/$NAME/promptly.png"
cp "$ROOT/LICENSE" "$WORK/$NAME/LICENSE"
cat > "$WORK/$NAME/README.txt" <<TXT
Promptly $VERSION for Linux (x86_64)

Run ./promptly from this folder. Nothing else needs installing beyond
GTK 3 and libsecret, which nearly every desktop has (on Debian and
Ubuntu, the packages libgtk-3-0 and libsecret-1-0).

To add it to your app menu, copy $ID.desktop to
~/.local/share/applications/ and set its Exec line to the full path of
this folder's promptly, and promptly.png to
~/.local/share/icons/hicolor/512x512/apps/$ID.png.

The .deb next to this tarball does that for the whole machine.
TXT
tar -C "$WORK" -czf "$OUT/$NAME.tar.gz" "$NAME"

# ---- .deb ------------------------------------------------------------------
DEB="$WORK/deb"
mkdir -p "$DEB/DEBIAN" "$DEB/opt/promptly" "$DEB/usr/bin" "$DEB/usr/share/applications" "$DEB/usr/share/metainfo"
cp -a "$BUNDLE"/. "$DEB/opt/promptly/"
ln -s /opt/promptly/promptly "$DEB/usr/bin/promptly"
cp "$ROOT/app/linux/$ID.desktop" "$DEB/usr/share/applications/"
cp "$ROOT/app/linux/$ID.metainfo.xml" "$DEB/usr/share/metainfo/"
for size in 16 24 32 48 64 128 256 512; do
  mkdir -p "$DEB/usr/share/icons/hicolor/${size}x${size}/apps"
  cp "$ROOT/app/linux/icons/hicolor/${size}x${size}/apps/$ID.png" "$DEB/usr/share/icons/hicolor/${size}x${size}/apps/"
done
mkdir -p "$DEB/usr/share/icons/hicolor/scalable/apps"
cp "$ROOT/app/linux/icons/hicolor/scalable/apps/$ID.svg" "$DEB/usr/share/icons/hicolor/scalable/apps/"
SIZE_KB="$(du -sk "$DEB/opt" "$DEB/usr" | awk '{s+=$1} END {print s}')"
cat > "$DEB/DEBIAN/control" <<CTL
Package: promptly
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $SIZE_KB
Depends: libgtk-3-0, libsecret-1-0, libstdc++6, libc6
Maintainer: Promptly <https://github.com/analogproblems/Promptly/issues>
Homepage: https://github.com/analogproblems/Promptly
Description: Terminal and SSH client with free, zero-knowledge sync
 Promptly is a terminal emulator and SSH client. Hosts, keys and snippets
 sync between devices through an encrypted vault kept on storage you
 already own. No account, no servers, no subscription.
CTL
cat > "$DEB/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
exit 0
POST
cp "$DEB/DEBIAN/postinst" "$DEB/DEBIAN/postrm"
chmod 755 "$DEB/DEBIAN/postinst" "$DEB/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$DEB" "$OUT/promptly_${VERSION}_$ARCH.deb" >/dev/null

echo "Wrote:"
ls -1 "$OUT/$NAME.tar.gz" "$OUT/promptly_${VERSION}_$ARCH.deb"
