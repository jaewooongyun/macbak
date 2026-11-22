#!/bin/bash
# Builds a release binary and wraps it in dist/Macbak.app (ad-hoc signed, Apple silicon, macOS 14 or later).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Macbak"

APP="$ROOT/dist/Macbak.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Macbak"
# The bundle identifier keeps the app's first name so saved settings and check history carry over.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Macbak</string>
<key>CFBundleIdentifier</key><string>local.roomloop.native</string>
<key>CFBundleName</key><string>Macbak</string>
<key>CFBundleDisplayName</key><string>Macbak</string>
<key>CFBundleDevelopmentRegion</key><string>ko</string>
<key>CFBundleLocalizations</key><array><string>ko</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>휴지통을 비울 때 Finder에 "휴지통 비우기"를 요청합니다. 다른 일에는 Finder를 제어하지 않습니다.</string>
</dict></plist>
PLIST
# Debug symbols carry the build machine's source and object paths; the app does not need them.
strip -S -x "$APP/Contents/MacOS/Macbak"
codesign --force --sign - "$APP"
echo "Built: $APP"
