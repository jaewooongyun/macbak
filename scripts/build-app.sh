#!/bin/bash
# Builds a release binary and wraps it in $MACBAK_DIST/Macbak.app (default dist/, Apple silicon, macOS 14 or later).
# Signs with the release certificate (the keychain identity whose SHA-1 is RELEASE_CERT) when this Mac has it, so every
# build is the same app to macOS permissions and to the updater. Only that certificate turns the update feed on: a build
# from source on another Mac, even with a certificate of the same name or one picked with MACBAK_SIGN_IDENTITY, carries
# no feed and never replaces itself with a build signed by someone else.
set -euo pipefail
VERSION=0.4.0
BUILD=6
RELEASE_CERT=34627E82A5ACE2A75F3906068089D4FAE3CECAF4
FEED_URL="https://github.com/jaewooongyun/macbak/releases/latest/download/appcast.xml"
PUBLIC_ED_KEY="aLuGd26ThurOLARwj0nkGsPfLG790uqfk+WnGg06y6Y="
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="${MACBAK_DIST:-$ROOT/dist}"
APP="$DIST/Macbak.app"
# Replacing the bundle under a running copy can crash it.
if pgrep -f "^$APP/Contents/MacOS/Macbak( |$)" >/dev/null; then
    echo "Macbak is running from $APP. Quit it, or build elsewhere with MACBAK_DIST=<folder>." >&2
    exit 1
fi

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Macbak" "$APP/Contents/MacOS/Macbak"
FW="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$FW"
# Only sandboxed apps need Sparkle's XPC services, and this app is not sandboxed.
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"

PLIST="$APP/Contents/Info.plist"
# The bundle identifier keeps the app's first name so saved settings and check history carry over.
cat > "$PLIST" <<'PLIST'
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
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>휴지통을 비울 때 Finder에 "휴지통 비우기"를 요청합니다. 다른 일에는 Finder를 제어하지 않습니다.</string>
</dict></plist>
PLIST
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
pb "Add :CFBundleShortVersionString string $VERSION"
pb "Add :CFBundleVersion string $BUILD"

SIGN_ID="${MACBAK_SIGN_IDENTITY:-$RELEASE_CERT}"
if security find-identity -p codesigning | grep -F -e "$SIGN_ID" >/dev/null; then
    if [ "$SIGN_ID" != "$RELEASE_CERT" ]; then
        echo "warning: signed with \"$SIGN_ID\", not the release certificate, so this build does not check for updates." >&2
    elif [ -n "$PUBLIC_ED_KEY" ]; then
        pb "Add :SUFeedURL string $FEED_URL"
        pb "Add :SUPublicEDKey string $PUBLIC_ED_KEY"
        pb "Add :SUEnableAutomaticChecks bool true"
        pb "Add :SUScheduledCheckInterval integer 86400"
        pb "Add :SUAutomaticallyUpdate bool false"
        pb "Add :SUAllowsAutomaticUpdates bool true"
        pb "Add :SUEnableSystemProfiling bool false"
    else
        echo "warning: PUBLIC_ED_KEY is empty, so this build does not check for updates." >&2
    fi
else
    echo "warning: no signing identity \"$SIGN_ID\", so this build is ad-hoc signed and does not check for updates." >&2
    SIGN_ID="-"
fi

# Debug symbols carry the build machine's source and object paths; the app does not need them.
strip -S -x "$APP/Contents/MacOS/Macbak"
# Inside out, so each seal covers code that is already signed; --deep would re-sign the nested code with defaults.
for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW" "$APP"; do
    codesign --force --sign "$SIGN_ID" "$code"
done
echo "Built: $APP"
