#!/bin/bash
# Packages build/Minions.app into a distributable build/Minions.dmg with a
# drag-to-Applications layout. Run scripts/bundle.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Minions.app"
DMG="build/Minions.dmg"
STAGING="build/dmg-staging"

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/bundle.sh first" >&2; exit 1; }

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Minions.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Minions" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "built $DMG"
