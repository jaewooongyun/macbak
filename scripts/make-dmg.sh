#!/bin/bash
# Builds $MACBAK_DIST/Macbak.app (default dist/) and packs it with an Applications link into Macbak-<version>.dmg there.
# The app is not notarized: on another Mac, macOS asks once before opening it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="${MACBAK_DIST:-$ROOT/dist}"

MACBAK_DIST="$DIST" bash scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DIST/Macbak.app/Contents/Info.plist")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$DIST/Macbak.app" "$STAGE/Macbak.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Macbak-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Macbak" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "Built: $DMG"
