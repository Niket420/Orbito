#!/usr/bin/env bash
# Builds build/Whisper.app: a release build of the SwiftUI app, with the Python
# backend source copied into Contents/Resources/backend.
#
# Current limitation: the bundle uses the Python environment it finds at runtime
# (Resources/backend/.venv if present, otherwise `python3` on PATH). Embedding a
# relocatable Python runtime is the remaining Stage 8 work (see README).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Whisper.app"

cd "$ROOT/macos"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Whisper"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Whisper"
cp "$ROOT/macos/Resources/Info.plist" "$APP/Contents/Info.plist"

# Backend source only: no virtualenv, caches, tests or local .env secrets.
rsync -a --exclude '.venv' --exclude '__pycache__' --exclude '.pytest_cache' \
      --exclude 'tests' --exclude '.env' --exclude '*.egg-info' \
      "$ROOT/backend/" "$APP/Contents/Resources/backend/"

# Ad-hoc signature so macOS can track permissions (Microphone, Accessibility) for the bundle.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
