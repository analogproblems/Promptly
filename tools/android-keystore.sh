#!/usr/bin/env bash
# Make the upload keystore for Google Play, once, and say what to put where.
#
#   tools/android-keystore.sh [path/to/upload.jks]
#
# Play App Signing keeps the real signing key; this one only signs what we
# upload. Keep the file and its password somewhere safe and out of git
# (the repository ignores *.jks and key.properties).
set -euo pipefail

OUT="${1:-$HOME/promptly-upload.jks}"
ALIAS="upload"
if [[ -e "$OUT" ]]; then
  echo "$OUT exists already; not touching it." >&2
  exit 1
fi
read -rsp "Choose a keystore password: " PASS; echo
read -rsp "Type it again: " AGAIN; echo
[[ "$PASS" == "$AGAIN" ]] || { echo "The passwords differ." >&2; exit 1; }

keytool -genkeypair -v \
  -keystore "$OUT" -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$PASS" -keypass "$PASS" \
  -dname "CN=Promptly, O=Promptly, C=US"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat > "$ROOT/app/android/key.properties" <<PROPS
storeFile=$OUT
storePassword=$PASS
keyAlias=$ALIAS
keyPassword=$PASS
PROPS
chmod 600 "$ROOT/app/android/key.properties"

cat <<MSG

Keystore: $OUT
app/android/key.properties now points at it, so a local
\`flutter build apk --release\` signs with the upload key.

For CI, add these repository secrets (Settings, Secrets and variables, Actions):
  ANDROID_KEYSTORE_BASE64   the file, base64 encoded:  base64 -w0 $OUT
  ANDROID_KEYSTORE_PASSWORD the password you just chose
  ANDROID_KEY_ALIAS         $ALIAS
  ANDROID_KEY_PASSWORD      the same password
MSG
