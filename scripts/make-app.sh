#!/bin/bash
# Build the PinSnip menu bar app and assemble it into dist/PinSnip.app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[make-app] swift build (release)"
swift build -c release

BIN=".build/release/PinSnip"
if [ ! -f "$BIN" ]; then
  echo "[make-app] build product not found at $BIN" >&2
  exit 1
fi

APP="dist/PinSnip.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PinSnip"
chmod +x "$APP/Contents/MacOS/PinSnip"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/PinSnip.icns" "$APP/Contents/Resources/PinSnip.icns"

# Stable local identity. An ad-hoc signature changes on every build, and
# macOS then forgets the Screen Recording grant.
bash "scripts/ensure-signing-identity.sh"
codesign --force --sign "PinSnip Local" --identifier "com.personal.pinsnip" \
  --keychain "$HOME/Library/Keychains/login.keychain-db" "$APP"
codesign --verify --verbose=2 "$APP"

echo "[make-app] built $APP"
