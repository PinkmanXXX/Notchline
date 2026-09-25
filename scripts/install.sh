#!/usr/bin/env bash
# Notchline installer.
#   curl -fsSL https://raw.githubusercontent.com/PinkmanXXX/notchline/main/scripts/install.sh | bash
set -euo pipefail

REPO="PinkmanXXX/notchline"
APP="Notchline"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; hdiutil detach "/Volumes/$APP" -quiet 2>/dev/null || true' EXIT

echo "→ looking up the latest release of $REPO"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o 'https://[^"]*\.dmg' | head -n1)"
[ -n "$URL" ] || { echo "no .dmg in the latest release"; exit 1; }

echo "→ downloading $(basename "$URL")"
curl -fL# "$URL" -o "$TMP/$APP.dmg"

echo "→ mounting"
hdiutil attach "$TMP/$APP.dmg" -nobrowse -quiet

echo "→ installing to /Applications"
rm -rf "/Applications/$APP.app"
cp -R "/Volumes/$APP/$APP.app" /Applications/

# The build is not notarised unless the maintainer has a Developer ID, so clear
# the quarantine flag here instead of making you right-click → Open.
xattr -dr com.apple.quarantine "/Applications/$APP.app" 2>/dev/null || true

echo "→ done. launching"
open "/Applications/$APP.app"
