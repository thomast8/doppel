#!/bin/zsh
# `doppel-signing` when the signing identity does not exist, which is every
# fresh install: `status` has to report it as absent instead of dying on the
# keychain lookup, since `setup` starts with the same lookup.
#
# Read-only: it looks up an identity name that is never created, so nothing is
# added to or removed from any keychain.
#
#   qa/signing.zsh [--cli /path/to/doppel-signing]

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
CLI="$REPO_ROOT/bin/doppel-signing"
[[ "${1:-}" == "--cli" ]] && CLI="$2"

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0 }
check() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

export DOPPEL_SIGN_IDENTITY_NAME="Doppel QA No Identity $$"

output="$("$CLI" status 2>&1)"
check "status succeeds without an identity" "$?" "0"
check "status reports the identity as absent" "$output" "identity: absent"

output="$("$CLI" remove 2>&1)"
check "remove succeeds without an identity" "$?" "0"
check "remove has nothing to do" "$output" "nothing to remove"

print -r -- ""
print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
