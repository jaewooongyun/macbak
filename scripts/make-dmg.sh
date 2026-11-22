#!/bin/bash
# Builds dist/Macbak.app and packs it with an Applications link into dist/Macbak-<version>.dmg for sharing.
# The app is ad-hoc signed, not notarized: on another Mac, macOS asks once before opening it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Macbak.app/Contents/Info.plist)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto dist/Macbak.app "$STAGE/Macbak.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Macbak-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Macbak" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "Built: $ROOT/$DMG"
