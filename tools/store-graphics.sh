#!/usr/bin/env bash
# The Play Store feature graphic (1024 x 500): the icon, the name and the
# line under it, on the app's dark surface. Needs ImageMagick.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/docs/store/feature-graphic.png"
mkdir -p "$(dirname "$OUT")"
FONT="${FONT:-DejaVu-Sans-Bold}"
FONT_REGULAR="${FONT_REGULAR:-DejaVu-Sans}"
convert -size 1024x500 xc:"#0E1116" \
  \( "$ROOT/app/assets/icon/promptly.png" -resize 300x300 \) -geometry +92+100 -composite \
  -font "$FONT" -pointsize 96 -fill "#E6EDF3" -annotate +440+232 "Promptly" \
  -font "$FONT_REGULAR" -pointsize 30 -fill "#8B949E" -annotate +444+292 "Your terminal, everywhere." \
  -font "$FONT_REGULAR" -pointsize 30 -fill "#7CE38B" -annotate +444+336 "Your data, yours." \
  "$OUT"
echo "Wrote $OUT"
