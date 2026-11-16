#!/bin/bash
# Build PinSnip and open it. Safe to run repeatedly: `open` reuses the running
# copy instead of starting a second one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

npm run build

if [ ! -d "dist/PinSnip.app" ]; then
  echo "[run] dist/PinSnip.app was not produced" >&2
  exit 1
fi

open "dist/PinSnip.app"
echo "[run] PinSnip 已打开；图标在屏幕右上角的菜单栏里（不在 Dock 中）。"
