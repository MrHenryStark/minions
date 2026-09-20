#!/bin/bash
# Builds Minions and assembles build/Minions.app. Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Minions
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Minions.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Minions" "$APP/Contents/MacOS/Minions"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# SwiftPM resource bundles (the bundled pricing snapshot, test fixtures, etc.)
# land next to the executable in .build/; Bundle.module looks for them inside
# the app's own Resources at runtime, so they must be copied in.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    name="$(basename "$bundle")"
    [[ "$name" == *Tests* ]] && continue
    rm -rf "$APP/Contents/Resources/$name"
    cp -R "$bundle" "$APP/Contents/Resources/$name"
done
shopt -u nullglob

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so macOS keeps TCC grants (Finder/Accessibility prompts) stable
# between rebuilds. This is NOT a Developer ID signature — see README for
# what that means for people who download the app.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
