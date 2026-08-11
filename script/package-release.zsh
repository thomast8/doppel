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
readonly RELEASE_NOTES_SOURCE="${DOPPEL_RELEASE_NOTES:-$REPO_ROOT/release-notes/$DOPPEL_VERSION.md}"
readonly RELEASE_NOTES="$DIST_ROOT/$RELEASE_NAME.md"
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
readonly APPCAST_WORK="$WORK/appcast"

cleanup() {
    /bin/rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

"$REPO_ROOT/script/prepare-release-notes.zsh" \
    "$RELEASE_NOTES_SOURCE" /dev/null "$DOPPEL_VERSION"

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

/bin/mkdir -p "$DIST_ROOT" "$WORK/install" "$APPCAST_WORK"
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
"$REPO_ROOT/script/prepare-release-notes.zsh" \
    "$RELEASE_NOTES_SOURCE" "$RELEASE_NOTES" "$DOPPEL_VERSION"
# Only the current archive belongs in generate_appcast's scan directory.
# Feeding it older ZIPs makes Sparkle rewrite their historical enclosure URLs
# with the newest tag prefix, even though those assets live under older tags.
/usr/bin/ditto "$ARCHIVE" "$APPCAST_WORK/$RELEASE_NAME.zip"
/usr/bin/ditto "$RELEASE_NOTES" "$APPCAST_WORK/$RELEASE_NAME.md"
if [[ -f "$REPO_ROOT/appcast.xml" ]]; then
    /usr/bin/ditto "$REPO_ROOT/appcast.xml" "$FEED"
else
    /bin/rm -f "$FEED"
fi
"$GENERATE_APPCAST" \
    $appcast_signing_args \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --embed-release-notes \
    --link "https://github.com/thomast8/doppel" \
    --maximum-deltas 0 \
    --maximum-versions 3 \
    -o "$FEED" \
    "$APPCAST_WORK"

typeset embedded_release_notes
embedded_release_notes="$(/usr/bin/xmllint --xpath \
    "boolean(/rss/channel/item[*[local-name()='shortVersionString' and text()='$DOPPEL_VERSION']]/description[normalize-space(.) != ''])" \
    "$FEED")"
[[ "$embedded_release_notes" == true ]] || {
    print -u2 -r -- "Generated appcast does not contain release notes for $DOPPEL_VERSION"
    exit 1
}

print -r -- "Release archive: $ARCHIVE"
print -r -- "Release notes:   $RELEASE_NOTES"
print -r -- "Signed appcast:  $FEED"
[[ "$SIGN_ID" == "-" ]] && print -r -- "Gatekeeper: the first downloaded install requires Open Anyway approval."
print -r -- "Next: inspect all three files, use the notes in GitHub release v$DOPPEL_VERSION, upload the archive, then replace the repository appcast.xml with the generated feed."
