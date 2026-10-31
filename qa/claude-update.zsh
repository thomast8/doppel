#!/bin/zsh
# The Claude update path. Claude's own updater replaces /Applications/Claude.app
# on its own schedule and never touches the instances, so for Claude there is
# nothing for Doppel to download: an update is the reconcile that rebuilds every
# instance left on an older version from the app that is installed.
#
# Same shape as qa/update-reconcile.zsh, for the same reasons: the home and the
# install root are throwaway, the instances are real clones of the installed
# Claude, and drift is produced by rewriting the version a clone records.
# Claude's versions are dotted (4.4212.0) where ChatGPT's builds are integers,
# so "behind" and "ahead" are written as versions that sort either side of any
# real one rather than by arithmetic.
#
# The last section opens one instance for real and checks the update closes it
# and opens it again. It runs only with DOPPEL_QA_OPEN=1, because a new clone's
# first launch raises a keychain prompt someone has to answer.
#
#   qa/claude-update.zsh [--cli /path/to/doppel]
#
# Set DOPPEL_PRIMARY_APP to run against a Claude bundle other than the installed
# one.

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
CLI="$REPO_ROOT/bin/doppel"
[[ "${1:-}" == "--cli" ]] && CLI="$2"

readonly PRIMARY="${DOPPEL_PRIMARY_APP:-/Applications/Claude.app}"
readonly SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-claude-update.XXXXXXXX")"
readonly BEHIND="Claude Behind $$"
readonly CURRENT="Claude Current $$"
readonly APPS="$SCRATCH/Applications"
readonly BEHIND_APP="$APPS/$BEHIND.app"
readonly CURRENT_APP="$APPS/$CURRENT.app"
readonly BEHIND_INFO="$BEHIND_APP/Contents/Info.plist"
readonly OLDER="0.0.1"
readonly NEWER="999.0.0"

export DOPPEL_DEV=1 DOPPEL_HOME="$SCRATCH/home" DOPPEL_STATE_ROOT="$SCRATCH/engine-state"
export DOPPEL_PIN_ROOT="$SCRATCH/pins" DOPPEL_NO_ALERT=1 DOPPEL_RELAUNCH=0
export DOPPEL_SIGN_IDENTITY_NAME="Doppel Claude QA No Identity" DOPPEL_SIGN_IDENTITY=-
unset DOPPEL_PROGRESS

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0 }
check() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

claude() { "$CLI" --app claude "$@" }

cleanup() {
    local name
    /usr/bin/pkill -f "$APPS/" >/dev/null 2>&1 || true
    for name in "$BEHIND" "$CURRENT"; do
        claude remove "$name" --purge-data >/dev/null 2>&1 || true
    done
    /bin/rm -rf "$SCRATCH" 2>/dev/null || true
    return 0
}
trap cleanup EXIT INT TERM

source_build() { /usr/bin/plutil -extract DoppelSourceBundleVersion raw "$1/Contents/Info.plist" 2>/dev/null || true }
app_stamp() { /usr/bin/stat -f '%m' "$1" 2>/dev/null || print -r -- "missing" }
field() { print -r -- "$1" | /usr/bin/awk -F'\t' -v c="$2" '{print $c}' }
leave_behind() { /usr/bin/plutil -replace DoppelSourceBundleVersion -string "$OLDER" "$BEHIND_INFO" }
running() { /usr/bin/pgrep -f "$1/Contents/MacOS/Claude.real" >/dev/null 2>&1 }

[[ -d "$PRIMARY" ]] || { print -u2 -r -- "the Claude app is required at $PRIMARY"; exit 1 }
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$PRIMARY/Contents/Info.plist")"
SHORT="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PRIMARY/Contents/Info.plist")"
PRIMARY_STAMP="$(app_stamp "$PRIMARY")"
/bin/mkdir -p "$APPS"

print -r -- "Doppel Claude update"
print -r -- "  cli:     $CLI"
print -r -- "  primary: $PRIMARY ($BUILD)"
print -r -- ""

print -r -- "instances built from the installed Claude need nothing"
for name in "$BEHIND" "$CURRENT"; do
    slug="${${name:l}// /-}"
    if ! claude create --name "$name" --tint 3B82F6 --install-to "$APPS" \
        --profile-root "$SCRATCH/profile-$slug" --claude-config-dir "$SCRATCH/config-$slug" >/dev/null 2>&1; then
        print -u2 -r -- "  ✗ create failed; the rest of this file needs real clones"
        exit 1
    fi
done
check "both clones record the installed version" \
    "$(source_build "$BEHIND_APP")/$(source_build "$CURRENT_APP")" "$BUILD/$BUILD"
ROW="$(claude update check --porcelain)"
check "the check reports nothing to do" "$(field "$ROW" 1)" "current"
check "and reads the installed Claude, not a feed" \
    "$(field "$ROW" 2)/$(field "$ROW" 3)/$(field "$ROW" 4)/$(field "$ROW" 5)" "$BUILD/$SHORT/$BUILD/$SHORT"
check "with no instance counted as behind" "$(field "$ROW" 7)" "0"
check "prepare has nothing to download" "$(claude update prepare)" "already current	$BUILD"
BEHIND_STAMP="$(app_stamp "$BEHIND_APP")"
CURRENT_STAMP="$(app_stamp "$CURRENT_APP")"
OUT="$(claude update apply "$BUILD" 2>&1)"
check "applying the installed version is a no-op" "$OUT" "current	$BUILD	$BUILD	2	0"
check "without rebuilding anything" \
    "$(app_stamp "$BEHIND_APP")/$(app_stamp "$CURRENT_APP")" "$BEHIND_STAMP/$CURRENT_STAMP"

print -r -- ""
print -r -- "only the instance left behind is rebuilt"
leave_behind
ROW="$(claude update check --porcelain)"
check "the check now reports drift" "$(field "$ROW" 1)" "stale-instances"
check "and counts only the instance that is behind" "$(field "$ROW" 7)" "1"
HUMAN="$(claude update check)"
[[ "$HUMAN" == "Claude $SHORT"*"1 managed instance(s) were built from an older version"*"doppel --app claude update apply"* ]] \
    && pass "and says so in the readable form" \
    || fail "and says so in the readable form" "got: $HUMAN"
claude update verify >/dev/null 2>&1 \
    && fail "verification fails while an instance is behind" "verify passed" \
    || pass "verification fails while an instance is behind"
OUT="$(claude update apply 0.0.2 2>&1)"
[[ $? -ne 0 && "$OUT" == *"Claude updates itself"* ]] \
    && pass "a version other than the installed one is refused" \
    || fail "a version other than the installed one is refused" "got: $OUT"

BEHIND_STAMP="$(app_stamp "$BEHIND_APP")"
CURRENT_STAMP="$(app_stamp "$CURRENT_APP")"
ERR="$SCRATCH/progress.err"
OUT="$(DOPPEL_PROGRESS=1 claude update apply "$BUILD" 2>"$ERR")"
STATUS=$?
check "the reconcile reports the one instance it rebuilt" "$OUT" "reconciled	$BUILD	$BUILD	1	0"
check "and succeeds" "$STATUS" "0"
/usr/bin/grep -q $'^doppel-progress\t3\tChecking that this Claude version can be patched$' "$ERR" \
    && pass "progress names Claude" \
    || fail "progress names Claude" "got: $(/usr/bin/head -3 "$ERR")"
/usr/bin/grep -q $'^doppel-progress\t88\tRebuilt 1 of 1 instances$' "$ERR" \
    && pass "and counts the rebuilds for the app's bar" \
    || fail "and counts the rebuilds for the app's bar" "got: $(/bin/cat "$ERR")"
[[ "$(app_stamp "$BEHIND_APP")" != "$BEHIND_STAMP" ]] \
    && pass "the instance that was behind was actually replaced" \
    || fail "the instance that was behind was actually replaced" "the app was not touched"
check "and the one already current was left alone" "$(app_stamp "$CURRENT_APP")" "$CURRENT_STAMP"
check "the rebuilt instance carries the installed version" "$(source_build "$BEHIND_APP")" "$BUILD"
claude update verify >/dev/null 2>&1 \
    && pass "and passes the same verification an update ends with" \
    || fail "and passes the same verification an update ends with" "verify failed"
/usr/bin/codesign --verify --deep --strict "$BEHIND_APP" >/dev/null 2>&1 \
    && pass "and is still sealed" \
    || fail "and is still sealed" "codesign rejected the rebuilt bundle"

print -r -- ""
print -r -- "an instance ahead of the installed Claude is never rebuilt backwards"
/usr/bin/plutil -replace DoppelSourceBundleVersion -string "$NEWER" "$BEHIND_INFO"
ROW="$(claude update check --porcelain)"
check "the check does not call it drift" "$(field "$ROW" 1)" "current"
check "but counts it in its own column" "$(field "$ROW" 7)/$(field "$ROW" 8)" "0/1"
BEHIND_STAMP="$(app_stamp "$BEHIND_APP")"
OUT="$(claude update apply 2>&1)"
check "and a bare apply leaves it alone" "$OUT" "current	$BUILD	$BUILD	2	0"
check "or the version it records" "$(source_build "$BEHIND_APP")" "$NEWER"

print -r -- ""
print -r -- "an instance that was open is closed, rebuilt and opened again"
if [[ "${DOPPEL_QA_OPEN:-0}" != 1 ]]; then
    # A clone that has never run asks for the "Claude Safe Storage" keychain
    # item on its first launch, and until someone answers it cannot answer the
    # quit event either. So this part needs a person at the Mac.
    print -r -- "  - skipped; set DOPPEL_QA_OPEN=1 and answer the keychain prompt (Deny is fine)"
else
# Opened while its seal is still whole, as a real one would be, and only then
# marked as behind: the launcher refuses a bundle whose Info.plist was edited.
/usr/bin/plutil -replace DoppelSourceBundleVersion -string "$BUILD" "$BEHIND_INFO"
claude rebuild "$BEHIND" >/dev/null 2>&1
"$BEHIND_APP/Contents/MacOS/Claude" > "$SCRATCH/launch.log" 2>&1 &
for _ in {1..80}; do running "$BEHIND_APP" && break; /bin/sleep 0.25; done
leave_behind
if running "$BEHIND_APP"; then
    BEHIND_STAMP="$(app_stamp "$BEHIND_APP")"
    OUT="$(claude update apply 2>&1)"
    check "a bare apply rebuilds it and reports one reopened" "$OUT" "reconciled	$BUILD	$BUILD	1	1"
    [[ "$(app_stamp "$BEHIND_APP")" != "$BEHIND_STAMP" ]] \
        && pass "the open instance was rebuilt" \
        || fail "the open instance was rebuilt" "the app was not touched"
    running "$BEHIND_APP" \
        && pass "and is running again" \
        || fail "and is running again" "no Claude.real process for $BEHIND_APP"
else
    fail "the instance opened for the reopen check" "see $SCRATCH/launch.log"
fi
fi

print -r -- ""
print -r -- "nothing outside the instances was touched"
check "the installed Claude was left exactly as it was" "$(app_stamp "$PRIMARY")" "$PRIMARY_STAMP"

print -r -- ""
print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
