#!/bin/zsh
# Build and package an EdDSA-signed Doppel release, then generate its Sparkle
# appcast. Developer ID signing and notarisation are optional; publication
# remains a separate, reviewable step.

set -eu
setopt PIPE_FAIL

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
: "${DOPPEL_VERSION:?set DOPPEL_VERSION, for example 1.1.0}"
: "${DOPPEL_BUILD:?set DOPPEL_BUILD to an increasing integer}"

readonly SIGN_ID="${DOPPEL_SIGN_ID:--}"
readonly DIST_ROOT="${DOPPEL_RELEASE_DIR:-$REPO_ROOT/dist/releases}"
readonly RELEASE_NAME="Doppel-${DOPPEL_VERSION}-macOS"
readonly ARCHIVE="$DIST_ROOT/$RELEASE_NAME.zip"
readonly FEED="$DIST_ROOT/appcast.xml"
typeset download_prefix="${DOPPEL_RELEASE_DOWNLOAD_PREFIX:-https://github.com/thomast8/doppel/releases/download/v${DOPPEL_VERSION}}"
download_prefix="${download_prefix%/}/"
readonly DOWNLOAD_PREFIX="$download_prefix"
readonly SPARKLE_TOOLS="${DOPPEL_SPARKLE_TOOLS:-$REPO_ROOT/app/.build/artifacts/sparkle/Sparkle/bin}"
readonly GENERATE_APPCAST="$SPARKLE_TOOLS/generate_appcast"
readonly GENERATE_KEYS="$SPARKLE_TOOLS/generate_keys"
readonly SPARKLE_ACCOUNT="${DOPPEL_SPARKLE_ACCOUNT:-ai.doppel.menubar}"
readonly WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-release.XXXXXXXX")"
readonly APP="$WORK/install/Doppel.app"
readonly NOTARY_ARCHIVE="$WORK/Doppel-notary.zip"

cleanup() {
    /bin/rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[[ -x "$GENERATE_APPCAST" && -x "$GENERATE_KEYS" ]] || {
    print -u2 -r -- "Sparkle's release tools were not found under $SPARKLE_TOOLS"
    print -u2 -r -- "resolve app/Package.swift, or set DOPPEL_SPARKLE_TOOLS"
    exit 1
}

typeset sparkle_public_key="${DOPPEL_SPARKLE_PUBLIC_KEY:-}"
typeset -a appcast_signing_args
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
    [[ -f "$SPARKLE_ED_KEY_FILE" ]] || {
        print -u2 -r -- "SPARKLE_ED_KEY_FILE does not name a readable file"
        exit 1
    }
    [[ -n "$sparkle_public_key" ]] || {
        print -u2 -r -- "DOPPEL_SPARKLE_PUBLIC_KEY is required with SPARKLE_ED_KEY_FILE"
        exit 1
    }
    appcast_signing_args=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
else
    sparkle_public_key="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)" || {
        print -u2 -r -- "No Sparkle key exists for account $SPARKLE_ACCOUNT"
        print -u2 -r -- "run: just sparkle-key"
        exit 1
    }
    appcast_signing_args=(--account "$SPARKLE_ACCOUNT")
fi
[[ "${#sparkle_public_key}" == 44 ]] || {
    print -u2 -r -- "Sparkle public key must be a 44-character base64 Ed25519 key"
    exit 1
}

if [[ "$SIGN_ID" != "-" ]]; then
    : "${NOTARY_KEYCHAIN_PROFILE:?set NOTARY_KEYCHAIN_PROFILE for Developer ID releases}"
fi

/bin/mkdir -p "$DIST_ROOT" "$WORK/install"
DOPPEL_UNIVERSAL="${DOPPEL_UNIVERSAL:-1}" \
DOPPEL_VERSION="$DOPPEL_VERSION" \
DOPPEL_BUILD="$DOPPEL_BUILD" \
DOPPEL_SIGN_ID="$SIGN_ID" \
DOPPEL_SPARKLE_PUBLIC_KEY="$sparkle_public_key" \
    "$REPO_ROOT/app/build-app.zsh" "$WORK/install"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "$SIGN_ID" != "-" ]]; then
    /usr/bin/ditto -c -k --keepParent "$APP" "$NOTARY_ARCHIVE"
    /usr/bin/xcrun notarytool submit "$NOTARY_ARCHIVE" \
        --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$APP"
    /usr/bin/xcrun stapler validate "$APP"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP"
else
    print -r -- "Personal release: ad-hoc signed, EdDSA update verification enabled, not notarised."
fi

/bin/rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
[[ -f "$REPO_ROOT/appcast.xml" ]] && /usr/bin/ditto "$REPO_ROOT/appcast.xml" "$FEED"
"$GENERATE_APPCAST" \
    $appcast_signing_args \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --link "https://github.com/thomast8/doppel" \
    --maximum-deltas 0 \
    --maximum-versions 3 \
    -o "$FEED" \
    "$DIST_ROOT"

print -r -- "Release archive: $ARCHIVE"
print -r -- "Signed appcast:  $FEED"
[[ "$SIGN_ID" == "-" ]] && print -r -- "Gatekeeper: the first downloaded install requires Open Anyway approval."
print -r -- "Next: inspect both files, upload the archive to GitHub release v$DOPPEL_VERSION, then replace the repository appcast.xml with the generated feed."
