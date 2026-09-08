#!/usr/bin/env bash
# Rebuilds Resources/AppIcon.icns from Resources/AppIcon.svg (the source of
# truth: the availeth.io mark on a macOS tile). Needs rsvg-convert
# (brew install librsvg) and Apple's iconutil.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon.svg"
OUT="$ROOT/Resources/AppIcon.icns"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w "$s" -h "$s" "$SRC" -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w "$((s*2))" -h "$((s*2))" "$SRC" -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT") bytes) from $SRC"
