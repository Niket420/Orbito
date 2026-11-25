#!/bin/bash
# Installs the latest Orbito into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/Niket420/Orbito/main/website/install.sh | bash
#
# What it does: checks this Mac, downloads the newest release from GitHub, verifies
# its SHA-256 checksum when the release has one, replaces /Applications/Orbito.app
# and opens it. It never asks for your password and touches nothing else.
set -euo pipefail

REPO="Niket420/Orbito"
APP_NAME="Orbito"
DEST="/Applications/${APP_NAME}.app"

bold=$'\033[1m'; dim=$'\033[2m'; orange=$'\033[38;5;208m'; red=$'\033[31m'; reset=$'\033[0m'
say()  { printf "%s→%s %s\n" "$orange" "$reset" "$*"; }
fail() { printf "%s✗ %s%s\n" "$red" "$*" "$reset" >&2; exit 1; }

printf "\n%sOrbito installer%s\n\n" "$bold" "$reset"

# 1. This Mac
[[ "$(uname -s)" == "Darwin" ]] || fail "Orbito runs on macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Orbito needs a Mac with Apple Silicon (M1 or newer)."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || fail "Orbito needs macOS 14 Sonoma or later (this Mac has $(sw_vers -productVersion))."

# 2. The newest release
say "Finding the latest version…"
release="$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null)" \
  || fail "There's no published release yet. Watch https://github.com/${REPO}/releases for the first one."
tag="$(printf '%s' "$release" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
zip_url="$(printf '%s' "$release" | grep -Eo '"browser_download_url": *"[^"]+\.zip"' | grep -i "$APP_NAME" | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')"
[[ -n "$zip_url" ]] || fail "Release ${tag:-latest} has no ${APP_NAME} .zip to install."
sum_url="$(printf '%s' "$release" | grep -Eo '"browser_download_url": *"[^"]+\.sha256"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/' || true)"

# 3. Download (files fetched by curl aren't quarantined, so there's no Gatekeeper prompt)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
say "Downloading Orbito ${tag}…"
curl -fL --progress-bar "$zip_url" -o "$work/orbito.zip" || fail "The download failed. Check your connection and try again."

# 4. Verify
if [[ -n "$sum_url" ]]; then
  expected="$(curl -fsSL "$sum_url" | awk '{print $1}')"
  actual="$(shasum -a 256 "$work/orbito.zip" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || fail "The download doesn't match its checksum. Nothing was installed."
  say "Checksum verified."
else
  printf "%s  (this release has no checksum file; skipping verification)%s\n" "$dim" "$reset"
fi

# 5. Install
ditto -x -k "$work/orbito.zip" "$work/unzipped"
app="$(find "$work/unzipped" -maxdepth 2 -name "${APP_NAME}.app" -type d | head -1)"
[[ -n "$app" ]] || fail "The download didn't contain ${APP_NAME}.app."
codesign --verify --deep --strict "$app" 2>/dev/null || fail "The app's signature is broken. Nothing was installed."

if pgrep -xq "$APP_NAME"; then
  say "Quitting the running Orbito…"
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
  sleep 2
fi
[[ -w "/Applications" ]] || fail "Can't write to /Applications. Install from an administrator account."
rm -rf "$DEST"
ditto "$app" "$DEST"
say "Installed to ${DEST}"

# 6. Open
open "$DEST"
printf "\n%s✓ Orbito %s is ready.%s Tap ⌃⌥ (Control + Option) and say what you want.\n" "$bold" "$tag" "$reset"
printf "%s  On first use, macOS will ask for Microphone and Accessibility access.%s\n\n" "$dim" "$reset"
