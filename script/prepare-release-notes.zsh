#!/bin/zsh

set -eu

[[ "$#" == 3 ]] || {
    print -u2 -r -- "usage: prepare-release-notes.zsh SOURCE DESTINATION VERSION"
    exit 64
}

readonly SOURCE="$1"
readonly DESTINATION="$2"
readonly VERSION="$3"

[[ -f "$SOURCE" && -r "$SOURCE" ]] || {
    print -u2 -r -- "Release notes are required for every release."
    print -u2 -r -- "Create release-notes/$VERSION.md, or set DOPPEL_RELEASE_NOTES to a readable Markdown file."
    exit 1
}

/usr/bin/grep -Eq '[^[:space:]]' "$SOURCE" || {
    print -u2 -r -- "Release notes for $VERSION are blank: $SOURCE"
    exit 1
}

[[ "$DESTINATION" == /dev/null ]] || /usr/bin/ditto "$SOURCE" "$DESTINATION"
