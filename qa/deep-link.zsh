#!/bin/zsh
# Focused regression check for per-instance OAuth/deep-link routing. This uses
# an APFS clone of the current vendor ASAR and never launches or edits an app.

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
readonly PATCHER="$REPO_ROOT/engine/patch-deep-link.py"
readonly PRIMARY_ASAR="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}/Contents/Resources/app.asar"
readonly SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-deep-link.XXXXXXXX")"
readonly TEST_ASAR="$SCRATCH/app.asar"

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0 }
cleanup() { /bin/rm -rf "$SCRATCH" 2>/dev/null || true }
trap cleanup EXIT

print -r -- "Doppel deep-link patch QA"

if /usr/bin/python3 "$PATCHER" verify "$PRIMARY_ASAR" >/dev/null 2>&1; then
    fail "the unmodified primary is recognized as shared-scheme" \
        "verify incorrectly accepted the vendor codex:// behavior"
else
    pass "the unmodified primary is recognized as shared-scheme"
fi

if ! /bin/cp -c "$PRIMARY_ASAR" "$TEST_ASAR" 2>/dev/null; then
    /bin/cp "$PRIMARY_ASAR" "$TEST_ASAR" || exit 1
fi

PATCH_HASH="$(/usr/bin/python3 "$PATCHER" patch "$TEST_ASAR")" || {
    fail "the current vendor ASAR can be patched" "patch command failed"
    print -r -- "$PASSED passed, $FAILED failed"
    exit 1
}
pass "the current vendor ASAR can be patched"

VERIFY_HASH="$(/usr/bin/python3 "$PATCHER" verify "$TEST_ASAR")" || VERIFY_HASH=""
if [[ "$VERIFY_HASH" == "$PATCH_HASH" && ${#VERIFY_HASH} -eq 64 ]]; then
    pass "the patched archive and Electron header hash verify"
else
    fail "the patched archive and Electron header hash verify" \
        "patch '$PATCH_HASH', verify '$VERIFY_HASH'"
fi

SECOND_HASH="$(/usr/bin/python3 "$PATCHER" patch "$TEST_ASAR")" || SECOND_HASH=""
if [[ "$SECOND_HASH" == "$PATCH_HASH" ]]; then
    pass "patching is idempotent"
else
    fail "patching is idempotent" "second patch returned '$SECOND_HASH'"
fi

MARKERS="$(LC_ALL=C /usr/bin/grep -a -o 'DOPPEL_URL_SCHEME' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$MARKERS" == "1" ]]; then
    pass "the runtime now reads the per-instance scheme"
else
    fail "the runtime now reads the per-instance scheme" "found $MARKERS patch markers"
fi

OAUTH_MARKERS="$(LC_ALL=C /usr/bin/grep -a -o 'Doppel could not claim codex:// OAuth callback' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
CALLBACKS="$(LC_ALL=C /usr/bin/grep -a -o 'callbackUrl:`codex://connector/oauth_callback`' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$OAUTH_MARKERS" == "1" && "$CALLBACKS" == "1" ]]; then
    pass "OAuth claims the shared registered callback only when requested"
else
    fail "OAuth claims the shared registered callback only when requested" \
        "found $OAUTH_MARKERS ownership markers and $CALLBACKS callback URLs"
fi

RESTORE_MARKERS="$(LC_ALL=C /usr/bin/grep -a -o 'DOPPEL_URL_HANDLER_HELPER' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
RESTORE_SPAWNS="$(LC_ALL=C /usr/bin/grep -a -o 'require("node:child_process").spawn(process.env.DOPPEL_URL_HANDLER_HELPER' "$TEST_ASAR" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "$RESTORE_MARKERS" == "2" && "$RESTORE_SPAWNS" == "1" ]]; then
    pass "a completed callback restores primary codex ownership"
else
    fail "a completed callback restores primary codex ownership" \
        "found $RESTORE_MARKERS restoration markers and $RESTORE_SPAWNS direct spawn calls"
fi

print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
