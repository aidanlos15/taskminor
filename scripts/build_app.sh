#!/bin/bash
# Builds Availeth.app from the Swift package.
# Usage: scripts/build_app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Availeth.app"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$ROOT/.build/$CONFIG/Availeth"

# Prefer the stable self-signed identity so TCC permission grants (Accessibility,
# Screen Recording, Input Monitoring) persist across rebuilds. Its designated
# requirement is fixed to the cert leaf + bundle id, unlike ad-hoc (whose cdhash
# changes every build and invalidates grants). Falls back to ad-hoc if absent.
# Create it once with scripts/make_signing_identity.sh.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Availeth Self-Signed' | awk '{print $2}' | head -1)"
if [ -z "$IDENTITY" ]; then
  echo "warn: 'Availeth Self-Signed' identity not found — using ad-hoc (grants won't persist across rebuilds). Run scripts/make_signing_identity.sh."
  IDENTITY="-"
fi

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Availeth"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign "$IDENTITY" "$APP"

# Install to /Applications so the app is findable in permission pickers and its
# location (and thus TCC identity) stays stable. Register it as canonical.
INSTALLED="/Applications/Availeth.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
osascript -e 'quit app "Availeth"' 2>/dev/null || true
sleep 1
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"
codesign --force --sign "$IDENTITY" "$INSTALLED"
"$LSREG" -f "$INSTALLED" 2>/dev/null || true

echo "Done. Installed to: $INSTALLED"
echo "Run with: open -a \"$INSTALLED\""
