#!/bin/zsh
# Regression check for plist_value, the shared "read a plist key that may
# legitimately be absent" helper in engine/vendor.zsh.
#
# Some macOS builds print plutil's extraction error on stdout when a key path
# is missing, so a captured `$(plutil ... 2>/dev/null)` held the error sentence
# rather than empty output. That made the engine health check treat a missing
# third URL scheme as present, and every `doppel create` failed its staged
# health check, leaving a partly created instance behind.
#
# The checks here run against real plutil on the running macOS, so the suite
# fails wherever the stdout-error behaviour would bite.

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
readonly SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-plist-value.XXXXXXXX")"

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0 }
cleanup() { /bin/rm -rf "$SCRATCH" 2>/dev/null || true }
trap cleanup EXIT

source "$REPO_ROOT/engine/vendor.zsh"

readonly INFO="$SCRATCH/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string ChatGPT' "$INFO"
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$INFO"
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment:CODEX_HOME string /tmp/codex' "$INFO"

print -r -- "Doppel plist_value QA"

value="$(plist_value "$INFO" CFBundleName)"
[[ "$value" == "ChatGPT" ]] && \
    pass "a present key is returned verbatim" || \
    fail "a present key is returned verbatim" "got: ${value:-<empty>}"

[[ "$(plist_value "$INFO" LSEnvironment.CODEX_HOME)" == "/tmp/codex" ]] && \
    pass "a nested key is returned verbatim" || \
    fail "a nested key is returned verbatim" "nested extraction changed"

value="$(plist_value "$INFO" CFBundleURLTypes.0.CFBundleURLSchemes.2)"
[[ -z "$value" ]] && \
    pass "a missing key path yields empty output" || \
    fail "a missing key path yields empty output" \
        "error text leaked into the capture: $value"

plist_value "$INFO" CFBundleURLTypes.0.CFBundleURLSchemes.2
[[ $? -ne 0 ]] && \
    pass "a missing key path reports failure through the status" || \
    fail "a missing key path reports failure through the status" \
        "missing key reported success"

value="$(plist_value "$SCRATCH/not-a-plist" CFBundleName)"
[[ -z "$value" ]] && \
    pass "a missing file yields empty output" || \
    fail "a missing file yields empty output" "got: $value"

# A default (chatgpt) engine identity is enough for sourcing vendor.zsh; these
# checks never touch a real app.
print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
