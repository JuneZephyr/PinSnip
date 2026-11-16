#!/bin/bash
# Create a stable local code-signing identity named "PinSnip Local".
# Ad-hoc signatures (-s -) get a new hash on every build, so macOS treats
# each build as a different app and drops Screen Recording permission.
set -euo pipefail

NAME="PinSnip Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# Legacy PBE: the macOS Security framework rejects OpenSSL 3's default MAC.
openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:pinsnip >/dev/null 2>&1

# -A lets codesign use the key without a click-through prompt. A denied
# prompt from a non-interactive build shows up as errSecInternalComponent.
security import "$TMP/cert.p12" \
  -k "$KEYCHAIN" -P pinsnip -A >/dev/null

# User-keychain trust is enough for a local identity. Ignore failure here:
# codesign still accepts the cert, and the first use may ask for key access.
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1 || true

if ! security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "[sign] created \"$NAME\", but it is not yet a trusted code-signing identity." >&2
  echo "[sign] Open Keychain Access, find \"$NAME\", and set Code Signing to Always Trust." >&2
  exit 1
fi

echo "[sign] identity ready: $NAME"
