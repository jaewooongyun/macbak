#!/bin/bash
# Prepares a release without publishing it: builds the signed DMG, checks the build number against the public feed,
# makes the Sparkle appcast with the notes embedded, and scans everything that will go public. It ends by printing the
# tag and GitHub release commands for a person to run.
#
#   MACBAK_RELEASE_SCANNER=<scanner> scripts/release.sh <notes.md> [--first-updater-release] [--binaries-checked]
#   scripts/release.sh --self-test
#
# The scanner lives outside this repository (its word list must not be published): it gets file paths as arguments and
# exits 0 only when they are clean. --first-updater-release accepts a missing public feed (HTTP 404), which happens once,
# for the first release after 0.1.0; any other failure to read the feed stops the release. --binaries-checked says a
# person has looked at the changed binary files (screenshots, icons), which no scan can read.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
# The release certificate, pinned in build-app.sh. macOS ties the app's permissions (such as Finder control) to it, so a
# release signed with a recreated certificate would make every user grant them again.
RELEASE_CERT="$(sed -n 's/^RELEASE_CERT=//p' "$ROOT/scripts/build-app.sh")"
SIGN_REQUIREMENT="identifier \"local.roomloop.native\" and certificate leaf = H\"$(printf '%s' "$RELEASE_CERT" | tr 'A-F' 'a-f')\""

die() { echo "release: $*" >&2; exit 1; }

# Home path, account name or private key header in any of the files. Patterns are built here so this file holds none.
scan_paths() {
    local key="BEGIN [A-Z ]*PRIVATE[ ]KEY" hits
    # Two searches: grep takes one pattern syntax per run, and -F given after -E would make the key pattern literal.
    hits="$({ grep -lE -e "$key" "$@"; grep -lF -e "$HOME" -e "$(id -un)" "$@"; } 2>/dev/null | sort -u || true)"
    [ -z "$hits" ] || { printf 'release: local path, account name or private key in:\n%s\n' "$hits" >&2; return 1; }
}

# Any mail address other than GitHub's no-reply form and the public example and co-author addresses.
scan_mail() {
    local found
    found="$(grep -hoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$@" 2>/dev/null \
        | grep -vE '@users\.noreply\.github\.com$|^noreply@anthropic\.com$|@example\.(com|org)$' || true)"
    [ -z "$found" ] || { echo "release: mail address outside the allowed forms ($(printf '%s\n' "$found" | wc -l | tr -d ' ') found)" >&2; return 1; }
}

# $1 the app's SUPublicEDKey · $2 the public key of the keychain's signing key · $3 the appcast's enclosure signature.
# generate_appcast only warns when the keychain key differs from the app's, and then leaves the update unsigned, which
# installed copies refuse. Keeping the two keys equal is also this project's rule, so each release is signed with the key
# the previous one shipped.
signature_gate() {
    [ -n "$1" ] && [ "$1" = "$2" ] || { echo "release: the keychain's EdDSA key is not the one in the app's SUPublicEDKey" >&2; return 1; }
    [ -n "$3" ] || { echo "release: the appcast's update carries no EdDSA signature" >&2; return 1; }
}

run_scanner() {
    [ -n "${MACBAK_RELEASE_SCANNER:-}" ] && [ -x "$MACBAK_RELEASE_SCANNER" ] || { echo "release: MACBAK_RELEASE_SCANNER is not set to a program" >&2; return 2; }
    "$MACBAK_RELEASE_SCANNER" "$@" >&2 || { echo "release: the scanner refused the release files" >&2; return 1; }
}

# $1 curl exit · $2 HTTP status · $3 feed file · $4 new build · $5 "first" when --first-updater-release
feed_gate() {
    [ "$1" -eq 0 ] || { echo "release: could not read the public feed (curl $1)" >&2; return 1; }
    if [ "$2" = 404 ]; then
        [ "$5" = first ] && { echo "release: no public feed yet; first updater release" >&2; return 0; }
        echo "release: the public feed is missing (404); pass --first-updater-release only for the first updater release" >&2
        return 1
    fi
    [ "$2" = 200 ] || { echo "release: the public feed answered HTTP $2" >&2; return 1; }
    local latest
    latest="$(xmllint --xpath '//*[local-name()="version"]/text()' "$3" 2>/dev/null | tr -s ' \n' '\n' | sort -n | tail -1)"
    [[ "$latest" =~ ^[0-9]+$ ]] || { echo "release: could not read a build number from the public feed" >&2; return 1; }
    [ "$4" -gt "$latest" ] || { echo "release: build $4 is not newer than the published build $latest" >&2; return 1; }
}

# Not strict UTF-8, so no text scan can read it. macOS iconv lets some invalid sequences through, so Python decodes it.
is_binary() { ! python3 -I -c 'import sys; open(sys.argv[1], encoding="utf-8").read()' "$1" 2>/dev/null; }

# The GitHub Releases address whose prefix the enclosure URLs are cut from.
feed_url_ok() {
    [[ "$1" =~ ^https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/releases/latest/download/appcast\.xml$ ]] \
        && [ "${BASH_REMATCH[2]}" != . ] && [ "${BASH_REMATCH[2]}" != .. ]
}

check_signature() {
    codesign --verify --deep --strict "$1" 2>/dev/null && codesign --verify -R="$SIGN_REQUIREMENT" "$1" 2>/dev/null \
        || { echo "release: $1 is not signed with the release certificate" >&2; return 1; }
}

self_test() {
    local t fails=0
    t="$(mktemp -d)"
    trap 'rm -rf "$t"' RETURN
    expect() { if "${@:2}" 2>/dev/null; then r=pass; else r=fail; fi; [ "$r" = "$1" ] || { echo "FAIL: expected $1: ${*:2}"; fails=$((fails + 1)); }; }

    echo "Macbak release notes" > "$t/clean.txt"
    printf 'built in %s/macbak\n' "$HOME" > "$t/home.txt"
    printf 'user %s\n' "$(id -un)" > "$t/user.txt"
    printf '%s%s\n' "-----BEGIN OPENSSH PRIVATE" " KEY-----" > "$t/key.txt"
    expect pass scan_paths "$t/clean.txt"
    expect fail scan_paths "$t/home.txt"
    expect fail scan_paths "$t/user.txt"
    expect fail scan_paths "$t/key.txt"
    expect fail scan_paths "$t/clean.txt" "$t/key.txt"

    printf 'Author <1+someone@users.noreply.github.com>\nCo-Authored-By: Claude <noreply@anthropic.com>\nLibrary/CloudStorage/me@example.com\n' > "$t/ok-mail.txt"
    printf 'Author <someone@%s.test>\n' corp > "$t/bad-mail.txt"
    expect pass scan_mail "$t/ok-mail.txt"
    expect fail scan_mail "$t/bad-mail.txt"
    expect fail scan_mail "$t/ok-mail.txt" "$t/bad-mail.txt"

    printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>3</sparkle:version></item><item><sparkle:version>4</sparkle:version></item></channel></rss>\n' > "$t/feed.xml"
    echo '<rss><channel><item>' > "$t/broken.xml"
    expect pass feed_gate 0 404 "$t/none" 5 first
    expect fail feed_gate 0 404 "$t/none" 5 ""
    expect fail feed_gate 6 000 "$t/none" 5 first
    expect fail feed_gate 0 500 "$t/feed.xml" 5 first
    expect fail feed_gate 0 200 "$t/broken.xml" 5 ""
    expect fail feed_gate 0 200 "$t/feed.xml" 4 ""
    expect pass feed_gate 0 200 "$t/feed.xml" 5 ""

    printf '#!/bin/bash\ntouch "%s/called"\nexit 0\n' "$t" > "$t/scanner-ok"
    printf '#!/bin/bash\nexit 1\n' > "$t/scanner-bad"
    chmod +x "$t/scanner-ok" "$t/scanner-bad"
    MACBAK_RELEASE_SCANNER="" expect fail run_scanner "$t/clean.txt"
    MACBAK_RELEASE_SCANNER="$t/scanner-bad" expect fail run_scanner "$t/clean.txt"
    MACBAK_RELEASE_SCANNER="$t/scanner-ok" expect pass run_scanner "$t/clean.txt"
    [ -e "$t/called" ] || { echo "FAIL: the scanner was not run"; fails=$((fails + 1)); }

    expect fail signature_gate "key-a" "key-b" "sig"
    expect fail signature_gate "" "" "sig"
    expect fail signature_gate "key-a" "key-a" ""
    expect pass signature_gate "key-a" "key-a" "sig"

    printf '\x89PNG\r\n\x1a\n\0\0' > "$t/image.bin"
    { for _ in $(seq 2000); do echo "text line"; done; printf '\x89\n'; } > "$t/text-then-binary.bin"
    : > "$t/empty.txt"
    printf '\n\n\n' > "$t/blank.txt"
    printf 'text\n\xf4\x90\x80\x80\n' > "$t/out-of-range.bin"
    expect pass is_binary "$t/image.bin"
    expect pass is_binary "$t/text-then-binary.bin"
    expect pass is_binary "$t/out-of-range.bin"
    expect fail is_binary "$t/clean.txt"
    expect fail is_binary "$t/empty.txt"
    expect fail is_binary "$t/blank.txt"

    expect pass feed_url_ok "https://github.com/owner/repo/releases/latest/download/appcast.xml"
    expect fail feed_url_ok "http://github.com/owner/repo/releases/latest/download/appcast.xml"
    expect fail feed_url_ok "https://github.com/owner/r?x/releases/latest/download/appcast.xml"
    expect fail feed_url_ok "https://github.com/owner/repo/releases/latest/download/appcast.xml#x"
    expect fail feed_url_ok "https://github.com/owner/../releases/latest/download/appcast.xml"
    expect pass feed_url_ok "https://github.com/owner/repo.name/releases/latest/download/appcast.xml"

    cp /usr/bin/true "$t/probe"
    codesign --force --sign - "$t/probe" 2>/dev/null
    expect fail check_signature "$t/probe"
    [[ "$SIGN_REQUIREMENT" =~ certificate\ leaf\ =\ H\"[0-9a-f]{40}\"$ ]] \
        || { echo "FAIL: the signing requirement did not pick up RELEASE_CERT from build-app.sh"; fails=$((fails + 1)); }

    [ "$fails" -eq 0 ] || { echo "SELF-TEST FAILED ($fails)"; return 1; }
    echo "SELF-TEST OK"
}

if [ "${1:-}" = --self-test ]; then
    self_test
    exit
fi

USAGE="usage: MACBAK_RELEASE_SCANNER=<scanner> scripts/release.sh <notes.md> [--first-updater-release] [--binaries-checked]"
NOTES=""
FIRST=""
BINARIES_CHECKED=""
for arg in "$@"; do
    case "$arg" in
        --first-updater-release) FIRST=first ;;
        --binaries-checked) BINARIES_CHECKED=yes ;;
        -*) die "unknown option $arg; $USAGE" ;;
        *) [ -z "$NOTES" ] || die "$USAGE"; NOTES="$arg" ;;
    esac
done
[ -f "$NOTES" ] || die "$USAGE"
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"
[ -n "${MACBAK_RELEASE_SCANNER:-}" ] && [ -x "$MACBAK_RELEASE_SCANNER" ] || die "set MACBAK_RELEASE_SCANNER to the outside scanner first"
cd "$ROOT"
[ -z "$(git status --porcelain)" ] || die "commit or stash local changes first; the release must match a commit"

DIST="${MACBAK_DIST:-$ROOT/dist}"
MACBAK_DIST="$DIST" bash scripts/make-dmg.sh
APP="$DIST/Macbak.app"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION="$(pb CFBundleShortVersionString)"
BUILD="$(pb CFBundleVersion)"
FEED="$(pb SUFeedURL 2>/dev/null || true)"
[ -n "$FEED" ] || die "this build has no update feed; it was not signed with the release certificate"
feed_url_ok "$FEED" || die "SUFeedURL is not a GitHub Releases latest-asset HTTPS address: $FEED"
check_signature "$APP"
DMG="$DIST/Macbak-$VERSION.dmg"

WORK="$(mktemp -d)"
trap 'hdiutil detach "$WORK/mnt" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

set +e
STATUS="$(curl -sS -L --proto =https --max-time 60 -o "$WORK/public.xml" -w '%{http_code}' "$FEED")"
CURL=$?
set -e
feed_gate "$CURL" "$STATUS" "$WORK/public.xml" "$BUILD" "$FIRST"

mkdir "$WORK/feed"
cp "$DMG" "$WORK/feed/"
cp "$NOTES" "$WORK/feed/Macbak-$VERSION.md"
"$BIN/generate_appcast" --account macbak --download-url-prefix "${FEED%/latest/download/*}/download/v$VERSION/" \
    --embed-release-notes --maximum-deltas 0 "$WORK/feed" >&2
APPCAST="$WORK/feed/appcast.xml"
FIRST_LINE="$(grep -m1 -vE '^[[:space:]]*(#|$)' "$NOTES" || true)"
# -e: a Markdown bullet ("- Fixed …") would otherwise be read as an option.
[ -n "$FIRST_LINE" ] && grep -qF -e "$FIRST_LINE" "$APPCAST" || die "the appcast does not carry the release notes"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST" || die "the appcast does not name build $BUILD"
APP_KEY="$(pb SUPublicEDKey)"
KEYCHAIN_KEY="$("$BIN/generate_keys" --account macbak -p 2>/dev/null | tail -1 || true)"
SIGNATURE="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$APPCAST" 2>/dev/null || true)"
signature_gate "$APP_KEY" "$KEYCHAIN_KEY" "$SIGNATURE" \
    || die "the update is not signed for installed copies; restore the EdDSA key from its backup (generate_keys --account macbak -f)"
"$BIN/sign_update" --account macbak --verify "$DMG" "$SIGNATURE" >/dev/null 2>&1 || die "the update's EdDSA signature does not verify"

# What goes public: changed sources and commit records since the last tag, the notes, the appcast and the DMG's app.
PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$ROOT/$f"); done \
    < <(if [ -n "$PREV" ]; then git diff -z --name-only --diff-filter=d "$PREV" HEAD; else git ls-files -z; fi)
git log --format='%an <%ae>%n%cn <%ce>%n%B' ${PREV:+"$PREV..HEAD"} > "$WORK/commits.txt"
mkdir "$WORK/mnt"
hdiutil attach -readonly -nobrowse -mountpoint "$WORK/mnt" "$DMG" >/dev/null
cp "$WORK/mnt/Macbak.app/Contents/Info.plist" "$WORK/Info.plist"
strings -a "$WORK/mnt/Macbak.app/Contents/MacOS/Macbak" > "$WORK/macbak-strings.txt"
find "$WORK/mnt/Macbak.app" -type f -perm -u+x -exec strings -a {} + > "$WORK/bundle-strings.txt"
hdiutil detach "$WORK/mnt" >/dev/null

OURS=("$WORK/commits.txt" "$NOTES" "$APPCAST" "$WORK/Info.plist" "$WORK/macbak-strings.txt")
BINARIES=()
for f in ${SOURCES[@]+"${SOURCES[@]}"}; do
    if is_binary "$f"; then BINARIES+=("$f"); else OURS+=("$f"); fi
done
if [ "${#BINARIES[@]}" -gt 0 ] && [ -z "$BINARIES_CHECKED" ]; then
    printf 'release: no scan reads these changed binary files; look at each, then run again with --binaries-checked:\n' >&2
    printf '  %s\n' "${BINARIES[@]#"$ROOT/"}" >&2
    exit 1
fi
# Sparkle's own binaries carry their authors' contact strings, so the mail rule reads only what this project wrote.
scan_mail "${OURS[@]}" || die "release files hold a mail address"
scan_paths "${OURS[@]}" "$WORK/bundle-strings.txt" || die "release files hold local details"
run_scanner "${OURS[@]}" "$WORK/bundle-strings.txt" || die "the outside scan failed"

OUT="$DIST/release/v$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$DMG" "$APPCAST" "$OUT/"
cp "$NOTES" "$OUT/notes.md"
printf '\nReady: %s\nPublish by hand, in this order:\n' "$OUT"
printf '  %s\n' "git tag -a v$VERSION -m \"Macbak $VERSION\"" "git push origin v$VERSION" \
    "gh release create v$VERSION --draft --title \"Macbak $VERSION\" --notes-file \"$OUT/notes.md\" \"$OUT/Macbak-$VERSION.dmg\" \"$OUT/appcast.xml\"" \
    "gh release edit v$VERSION --draft=false"
