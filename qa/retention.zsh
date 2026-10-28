#!/bin/zsh
# Update-storage retention: what `doppel prune` (and an update, which runs the
# same pass) keeps under updates/ and each instance's Staging.
#
# Everything lives in a throwaway DOPPEL_HOME and a stub primary app; nothing
# under the real Application Support directory is read or written.
#
#   qa/retention.zsh [--cli /path/to/doppel]

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
CLI="$REPO_ROOT/bin/doppel"
[[ "${1:-}" == "--cli" ]] && CLI="$2"

readonly SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-retention.XXXXXXXX")"
trap '/bin/rm -rf "$SCRATCH"' EXIT
readonly HOME_DIR="$SCRATCH/home"
readonly PRIMARY="$SCRATCH/primary/ChatGPT.app"
readonly UPDATES="$HOME_DIR/updates"
readonly STATE="$HOME_DIR/state"

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0 }
check() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

prune() { DOPPEL_HOME="$HOME_DIR" DOPPEL_PRIMARY_APP="$PRIMARY" "$CLI" prune "$@" 2>&1 }
names() { print -r -- ${(j: :)${(f)"$(/bin/ls -A "$1" 2>/dev/null)"}} }
seed_backups() {
    local backup
    /bin/rm -rf "$UPDATES/.Backups"; /bin/mkdir -p "$UPDATES/.Backups"
    for backup in "$@"; do /bin/mkdir -p "$UPDATES/.Backups/$backup.app/Contents"; done
}

/bin/mkdir -p "$PRIMARY/Contents" "$UPDATES/Downloads" "$UPDATES/Prepared"
/usr/bin/plutil -create xml1 "$PRIMARY/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 22391 "$PRIMARY/Contents/Info.plist"

print -r -- "downloads and prepared builds"
for build in 21000 21421 22000 22391; do : > "$UPDATES/Downloads/ChatGPT-$build.zip"; done
: > "$UPDATES/Downloads/ChatGPT-22500.zip.partial"
for build in 21421 22391 22500 22600; do /bin/mkdir -p "$UPDATES/Prepared/$build/ChatGPT.app"; done
seed_backups ChatGPT.20000.20260101-000000
prune >/dev/null
check "only the newest download stays; a partial is left for its retry" \
    "$(names "$UPDATES/Downloads")" "ChatGPT-22391.zip ChatGPT-22500.zip.partial"
check "only the newest pending prepared build stays" "$(names "$UPDATES/Prepared")" "22600"

print -r -- ""
print -r -- "primary rollbacks"
seed_backups ChatGPT.22391.20250101-000000 ChatGPT.20000.20260101-000000 \
    ChatGPT.21421.20260301-000000 ChatGPT.22000.20260401-000000
prune >/dev/null
check "the installed build's rollback survives despite the oldest stamp" \
    "$(names "$UPDATES/.Backups")" "ChatGPT.22000.20260401-000000.app ChatGPT.22391.20250101-000000.app"
seed_backups ChatGPT.20000.20260101-000000 ChatGPT.21421.20260301-000000 ChatGPT.22000.20260401-000000
prune >/dev/null
check "with none for the installed build the newest two stay" \
    "$(names "$UPDATES/.Backups")" "ChatGPT.21421.20260301-000000.app ChatGPT.22000.20260401-000000.app"
prune >/dev/null
check "a second pass changes nothing" \
    "$(names "$UPDATES/.Backups")" "ChatGPT.21421.20260301-000000.app ChatGPT.22000.20260401-000000.app"
DOPPEL_KEEP_UPDATE_BACKUPS=1 prune >/dev/null
check "the limit is configurable" "$(names "$UPDATES/.Backups")" "ChatGPT.22000.20260401-000000.app"

print -r -- ""
print -r -- "instance staging"
/bin/mkdir -p "$STATE/com.example.done/Staging/a.app" "$STATE/com.example.dead/Staging/b.app" \
    "$STATE/com.example.dead/Rebuild.lock" "$STATE/com.example.live/Staging/c.app" \
    "$STATE/com.example.live/Rebuild.lock"
print -r -- "99999999" > "$STATE/com.example.dead/Rebuild.lock/owner-pid"
print -r -- "$$" > "$STATE/com.example.live/Rebuild.lock/owner-pid"
prune >/dev/null
check "staging from a finished build is swept" "$(names "$STATE/com.example.done/Staging")" ""
check "staging behind a dead lock is swept" "$(names "$STATE/com.example.dead/Staging")" ""
check "staging behind a live rebuild lock is left alone" "$(names "$STATE/com.example.live/Staging")" "c.app"

print -r -- ""
print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
