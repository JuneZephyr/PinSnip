#!/bin/bash
# Build PinSnip.app and pack it into a compressed disk image.
# The image contains the app and an Applications alias, so it can be
# installed by dragging. It is signed with the same local identity as the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# make-app.sh deletes dist/. Quit first so the running bundle is not replaced
# out from under itself.
if pgrep -x PinSnip >/dev/null 2>&1; then
  echo "[make-dmg] quitting PinSnip so the bundle can be replaced"
  killall PinSnip
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x PinSnip >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

bash "scripts/make-app.sh"

APP="dist/PinSnip.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT_DIR="release"
DMG="$OUT_DIR/PinSnip-${VERSION}.dmg"

STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

ditto "$APP" "$STAGE/PinSnip.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$OUT_DIR"
rm -f "$DMG"

hdiutil create \
  -volname "PinSnip" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

bash "scripts/ensure-signing-identity.sh"
codesign --force --sign "PinSnip Local" \
  --keychain "$HOME/Library/Keychains/login.keychain-db" \
  "$DMG"
codesign --verify --verbose=2 "$DMG"

echo "[make-dmg] built $DMG"
