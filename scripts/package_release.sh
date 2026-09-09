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

# The local model service, bundled so a customer installs nothing. MIT licensed
# (~31 MB thinned to this Mac's architecture). Set BUNDLE_OLLAMA=0 to ship
# without it and fall back to asking the customer to install Ollama themselves.
if [ "${BUNDLE_OLLAMA:-1}" = "1" ]; then
  SRC=""
  for candidate in "$ROOT/vendor/ollama" "/Applications/Ollama.app/Contents/Resources/ollama"; do
    [ -x "$candidate" ] && { SRC="$candidate"; break; }
  done
  if [ -n "$SRC" ]; then
    ARCH="$(uname -m)"
    echo "==> Bundling the model service ($ARCH)"
    if lipo -info "$SRC" 2>/dev/null | grep -q "Architectures in the fat file"; then
      lipo -thin "$ARCH" "$SRC" -output "$APP/Contents/Resources/ollama"
    else
      cp "$SRC" "$APP/Contents/Resources/ollama"
    fi
    chmod +x "$APP/Contents/Resources/ollama"
    # Intel Macs load their CPU backends from separate libraries; arm64 has them
    # compiled in, so this copies nothing on Apple Silicon.
    if [ "$ARCH" = "x86_64" ]; then
      cp "$(dirname "$SRC")"/libggml*.dylib "$(dirname "$SRC")"/libggml*.so "$APP/Contents/Resources/" 2>/dev/null || true
    fi
    # MIT requires the licence text to travel with the binary, along with the
    # notices for what it links. Both live in vendor/ and are checked in.
    mkdir -p "$APP/Contents/Resources/Licenses"
    [ -f "$ROOT/vendor/OLLAMA_LICENSE" ] && cp "$ROOT/vendor/OLLAMA_LICENSE" "$APP/Contents/Resources/Licenses/"
    [ -d "$ROOT/vendor/notices" ] && cp "$ROOT/vendor"/notices/* "$APP/Contents/Resources/Licenses/" 2>/dev/null || true
    if [ ! -f "$APP/Contents/Resources/Licenses/OLLAMA_LICENSE" ]; then
      echo "error: bundling the service requires vendor/OLLAMA_LICENSE. Fetch it from" >&2
      echo "       https://raw.githubusercontent.com/ollama/ollama/main/LICENSE" >&2
      exit 1
    fi
    echo "    service: $(du -h "$APP/Contents/Resources/ollama" | cut -f1)"
  else
    echo "warn: no ollama binary found — shipping without the bundled service."
    echo "      Put one at vendor/ollama, or install Ollama.app, or set BUNDLE_OLLAMA=0."
  fi
fi

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
# Nested executables are signed first, then the app seals over them.
if [ -f "$APP/Contents/Resources/ollama" ]; then
  # shellcheck disable=SC2086
  codesign --force $HARDENED --sign "$IDENTITY" "$APP/Contents/Resources/ollama"
fi
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
