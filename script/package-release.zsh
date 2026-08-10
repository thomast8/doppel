#!/bin/zsh
# Build, notarise and package a signed Doppel release, then generate its signed
# Sparkle appcast. Publication remains a separate, reviewable step.

set -eu
setopt PIPE_FAIL

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
: "${DOPPEL_VERSION:?set DOPPEL_VERSION, for example 1.1.0}"
: "${DOPPEL_BUILD:?set DOPPEL_BUILD to an increasing integer}"
: "${DOPPEL_SIGN_ID:?set DOPPEL_SIGN_ID to a Developer ID Application identity}"
: "${DOPPEL_SPARKLE_PUBLIC_KEY:?set DOPPEL_SPARKLE_PUBLIC_KEY to the EdDSA public key}"
: "${SPARKLE_ED_KEY_FILE:?set SPARKLE_ED_KEY_FILE to the matching private-key file}"
: "${NOTARY_KEYCHAIN_PROFILE:?set NOTARY_KEYCHAIN_PROFILE to a notarytool profile}"

readonly DIST_ROOT="${DOPPEL_RELEASE_DIR:-$REPO_ROOT/dist/releases}"
readonly RELEASE_NAME="Doppel-${DOPPEL_VERSION}-macOS"
readonly ARCHIVE="$DIST_ROOT/$RELEASE_NAME.zip"
readonly FEED="$DIST_ROOT/appcast.xml"
readonly DOWNLOAD_PREFIX="${DOPPEL_RELEASE_DOWNLOAD_PREFIX:-https://github.com/thomast8/doppel/releases/download/v${DOPPEL_VERSION}}"
readonly SPARKLE_TOOLS="${DOPPEL_SPARKLE_TOOLS:-$REPO_ROOT/app/.build/artifacts/sparkle/Sparkle/bin}"
readonly GENERATE_APPCAST="$SPARKLE_TOOLS/generate_appcast"
readonly WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-release.XXXXXXXX")"
readonly APP="$WORK/install/Doppel.app"
readonly NOTARY_ARCHIVE="$WORK/Doppel-notary.zip"

cleanup() {
    /bin/rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[[ -x "$GENERATE_APPCAST" ]] || {
    print -u2 -r -- "Sparkle's generate_appcast was not found at $GENERATE_APPCAST"
    print -u2 -r -- "resolve app/Package.swift, or set DOPPEL_SPARKLE_TOOLS"
    exit 1
}
[[ -f "$SPARKLE_ED_KEY_FILE" ]] || {
    print -u2 -r -- "SPARKLE_ED_KEY_FILE does not name a readable file"
    exit 1
}

/bin/mkdir -p "$DIST_ROOT" "$WORK/install"
DOPPEL_UNIVERSAL=1 \
DOPPEL_VERSION="$DOPPEL_VERSION" \
DOPPEL_BUILD="$DOPPEL_BUILD" \
DOPPEL_SIGN_ID="$DOPPEL_SIGN_ID" \
DOPPEL_SPARKLE_PUBLIC_KEY="$DOPPEL_SPARKLE_PUBLIC_KEY" \
    "$REPO_ROOT/app/build-app.zsh" "$WORK/install"

/usr/bin/ditto -c -k --keepParent "$APP" "$NOTARY_ARCHIVE"
/usr/bin/xcrun notarytool submit "$NOTARY_ARCHIVE" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

/bin/rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
[[ -f "$REPO_ROOT/appcast.xml" ]] && /usr/bin/ditto "$REPO_ROOT/appcast.xml" "$FEED"
"$GENERATE_APPCAST" \
    --ed-key-file "$SPARKLE_ED_KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --link "https://github.com/thomast8/doppel" \
    --maximum-deltas 0 \
    --maximum-versions 3 \
    -o "$FEED" \
    "$DIST_ROOT"

print -r -- "Release archive: $ARCHIVE"
print -r -- "Signed appcast:  $FEED"
print -r -- "Next: inspect both files, upload the archive to GitHub release v$DOPPEL_VERSION, then replace the repository appcast.xml with the generated feed."
