#!/bin/zsh

set -eu

readonly REPO_ROOT="${0:A:h:h}"
readonly PREPARE="$REPO_ROOT/script/prepare-release-notes.zsh"
readonly WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-release-notes-qa.XXXXXXXX")"

cleanup() {
    /bin/rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

expect_failure() {
    if "$@" >"$WORK/stdout" 2>"$WORK/stderr"; then
        print -u2 -r -- "expected command to fail: $*"
        exit 1
    fi
}

expect_failure "$PREPARE" "$WORK/missing.md" "$WORK/output.md" 9.9.9
/usr/bin/grep -Fq "Release notes are required for every release." "$WORK/stderr"

expect_failure /usr/bin/env DOPPEL_VERSION=9.9.9 DOPPEL_BUILD=999 \
    "$REPO_ROOT/script/package-release.zsh"
/usr/bin/grep -Fq "Release notes are required for every release." "$WORK/stderr"

print -n -r -- "   " >"$WORK/blank.md"
expect_failure "$PREPARE" "$WORK/blank.md" "$WORK/output.md" 9.9.9
/usr/bin/grep -Fq "Release notes for 9.9.9 are blank" "$WORK/stderr"

print -r -- $'# Doppel 9.9.9\n\n- A visible improvement.' >"$WORK/valid.md"
"$PREPARE" "$WORK/valid.md" "$WORK/output.md" 9.9.9
/usr/bin/cmp "$WORK/valid.md" "$WORK/output.md"

readonly APPCAST="$REPO_ROOT/appcast.xml"
latest_version="$(/usr/bin/xmllint --xpath \
    "string(/rss/channel/item[1]/*[local-name()='shortVersionString'])" "$APPCAST")"
latest_notes="$(/usr/bin/xmllint --xpath \
    "string(/rss/channel/item[1]/description)" "$APPCAST")"
source_notes="$(<"$REPO_ROOT/release-notes/$latest_version.md")"
[[ -n "$latest_notes" && "$latest_notes" == "$source_notes" ]] || {
    print -u2 -r -- "appcast release notes do not match release-notes/$latest_version.md"
    exit 1
}

print -r -- "Release-notes QA passed."
