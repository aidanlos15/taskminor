#!/bin/bash
# Builds a distributable Availeth.dmg: the app, hardened and stripped, in a
# window with a drag-to-Applications target, the way a consumer app arrives.
#
# Usage:
#   scripts/package_release.sh                      # self-signed, for internal testing
#   IDENTITY="Developer ID Application: Availeth, LLC (TEAMID)" \
#   NOTARY_PROFILE=availeth scripts/package_release.sh   # signed + notarized for customers
#
# Without a Developer ID the DMG still builds, but macOS will warn on first
# open. Create the notary profile once with:
#   xcrun notarytool store-credentials availeth --apple-id you@availeth.io \
#     --team-id TEAMID --password <app-specific-password>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Availeth.app"
DMG="$ROOT/build/Availeth.dmg"
STAGE="$ROOT/build/dmg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"

rm -rf "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE"

echo "==> Building release"
swift build -c release --package-path "$ROOT" >/dev/null

echo "==> Assembling ${APP##*/} $VERSION"
cp "$ROOT/.build/release/Availeth" "$APP/Contents/MacOS/Availeth"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Remove the symbol table. Swift compiles to machine code, so the source is
# never readable, but an unstripped binary lists every type and function name.
echo "==> Stripping symbols"
strip -rSTx "$APP/Contents/MacOS/Availeth"

IDENTITY="${IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | awk '{print $2}' | head -1 || true)"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Availeth Self-Signed' | awk '{print $2}' | head -1 || true)"
  echo "warn: no Developer ID found — signing with the local identity."
  echo "      macOS will warn customers on first open until this is a Developer ID and notarized."
  HARDENED=""
else
  # The hardened runtime is required for notarization.
  HARDENED="--options runtime --timestamp"
fi
[ -n "$IDENTITY" ] || { echo "error: no code-signing identity at all. Run scripts/make_signing_identity.sh." >&2; exit 1; }

echo "==> Signing"
# shellcheck disable=SC2086
codesign --force $HARDENED --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature verifies"

# The window a customer sees: the app on the left, Applications on the right.
echo "==> Building the disk image"
cp -R "$APP" "$STAGE/Availeth.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Availeth" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
[ -n "${HARDENED:-}" ] && codesign --force --sign "$IDENTITY" "$DMG" || true

if [ -n "${NOTARY_PROFILE:-}" ] && [ -n "${HARDENED:-}" ]; then
  echo "==> Notarizing (a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "==> Gatekeeper check"
  spctl --assess --type open --context context:primary-signature -v "$DMG" || true
else
  echo "==> Skipping notarization (set NOTARY_PROFILE and use a Developer ID to enable)"
fi

echo
echo "Done: $DMG  ($(du -h "$DMG" | cut -f1))"
